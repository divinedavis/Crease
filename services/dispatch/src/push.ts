import { createPrivateKey, createSign, type KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http2 from 'node:http2';
import type { SupabaseClient } from '@supabase/supabase-js';
import { config } from './config.js';

export type PushEnvironment = 'sandbox' | 'production';

const APNS_HOST: Record<PushEnvironment, string> = {
  sandbox: 'api.sandbox.push.apple.com',
  production: 'api.push.apple.com',
};

/**
 * Apple expires a provider token after an hour and rejects one that is
 * refreshed more than once every twenty minutes, so a token is minted on a
 * timer and shared by every send. One per notification is how an account gets
 * 429 TooManyProviderTokenUpdates and stops delivering anything at all.
 */
const TOKEN_TTL_MS = 45 * 60 * 1000;

/** A push must never hold up the transition that triggered it. */
const APNS_TIMEOUT_MS = 10_000;

/**
 * The provider token APNs authenticates every request with.
 *
 * ES256 signatures come out of OpenSSL in DER; JOSE — and therefore Apple —
 * only accepts the raw r||s pair. The difference shows up as 403
 * InvalidProviderToken with nothing else to go on, so the encoding is pinned
 * here rather than left to a default.
 */
export function apnsJwt(
  key: KeyObject,
  keyId: string,
  teamId: string,
  issuedAt: number = Date.now(),
): string {
  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId })).toString('base64url');
  const payload = Buffer.from(
    JSON.stringify({ iss: teamId, iat: Math.floor(issuedAt / 1000) }),
  ).toString('base64url');
  const signature = createSign('sha256')
    .update(`${header}.${payload}`)
    .sign({ key, dsaEncoding: 'ieee-p1363' })
    .toString('base64url');
  return `${header}.${payload}.${signature}`;
}

/**
 * Push, for the one event the customer cannot see coming.
 *
 * Every entry point is safe to call with no credentials configured: the APNs
 * auth key is made by hand in the developer portal and may not exist yet, and
 * the alternative — a dispatch or money path that throws because a phone could
 * not be told something — is far worse than a silent notification. Absent, this
 * says so once and no-ops. It starts working the moment the key is set, with no
 * other change.
 */
/**
 * Wording for the 'received' push, kept pure so the branches are testable.
 *
 * The count is the shop's number, not the customer's estimate — quoting it back
 * is what makes the message reassuring rather than generic. An intake that
 * settled above the hold reads differently: the customer has to act, and a
 * notification that buries that under "good news" wording gets swiped away.
 */
export function receivedAlert(order: {
  shop: string;
  shortCode: string;
  status: string;
  itemCount: number | null;
}): { title: string; body: string } {
  if (order.status === 'awaiting_approval') {
    return {
      title: 'Action needed on your order',
      body:
        `${order.shop} counted order ${order.shortCode} and the total came in ` +
        'above your estimate. Review and approve it in the app.',
    };
  }
  const counted = order.itemCount
    ? `${order.itemCount} piece${order.itemCount === 1 ? '' : 's'} counted. `
    : '';
  return {
    title: 'Your cleaner has your order',
    body: `${order.shop} has received order ${order.shortCode}. ${counted}We'll tell you the moment it's ready.`,
  };
}

export class PushService {
  private key?: KeyObject;
  private keyUnusable = false;
  private announcedUnconfigured = false;
  private jwt?: { token: string; mintedAt: number };

  constructor(
    private readonly db: SupabaseClient,
    private readonly log: { info: Function; warn: Function; error: Function },
  ) {}

  /** Remember a device, so a 'ready' hours from now has somewhere to land. */
  async registerToken(userId: string, token: string, environment: PushEnvironment) {
    const { error } = await this.db.from('device_tokens').upsert(
      {
        user_id: userId,
        token,
        platform: 'ios',
        environment,
        last_seen_at: new Date().toISOString(),
      },
      // On the token, not on the user: the same device re-registering under a
      // different account has to move, not accumulate a second row that keeps
      // notifying whoever was signed in last.
      { onConflict: 'token' },
    );
    if (error) throw new Error(`could not register device token: ${error.message}`);
  }

  /**
   * "Your laundry is ready", to every device the customer has.
   *
   * The ledger row is claimed before anything is sent, which is what makes this
   * safe to call from more than one place and safe to retry. A claimed send
   * that then fails at Apple is not retried: a push that never arrives is a
   * disappointment, and a duplicate one at eleven at night is a complaint.
   */
  async notifyOrderReady(orderId: string): Promise<{ sent: number; skipped?: string }> {
    return this.notifyOrder(orderId, 'ready', (order) => {
      const shop = order.cleaner?.name ?? 'Your cleaner';
      const tier = order.service_tier ?? 'round_trip';
      return {
        title: 'Your laundry is ready',
        // pickup_only has no second leg, so there is nothing for them to
        // schedule and nobody coming — saying otherwise sends someone home to
        // wait for a courier that was never paid for.
        body:
          tier === 'pickup_only'
            ? `${shop} has finished order ${order.short_code}. It's ready to collect.`
            : `${shop} has finished order ${order.short_code}. Choose a delivery time in the app.`,
      };
    });
  }

  /**
   * "Your cleaner has your order", sent when the bag is opened and counted.
   *
   * Fired from settle rather than from the courier leg landing: a bag sitting
   * unopened behind the counter has not really been received, and for a
   * return_only order there is no courier leg at all — the count is the first
   * moment the shop has confirmably taken custody on every tier. The ledger
   * makes a recount silent: (order, kind) is claimed once, so re-counting a bag
   * does not re-announce it.
   */
  async notifyOrderReceived(orderId: string): Promise<{ sent: number; skipped?: string }> {
    return this.notifyOrder(orderId, 'received', (order) =>
      receivedAlert({
        shop: order.cleaner?.name ?? 'Your cleaner',
        shortCode: order.short_code,
        status: order.status,
        itemCount: order.cleaner_item_count ?? null,
      }),
    );
  }

  private async notifyOrder(
    orderId: string,
    kind: 'ready' | 'received',
    alertFor: (order: any) => { title: string; body: string },
  ): Promise<{ sent: number; skipped?: string }> {
    const creds = this.credentials();
    if (!creds) return { sent: 0, skipped: 'apns_not_configured' };

    const { data: order } = await this.db
      .from('orders')
      .select(
        'id, short_code, customer_id, service_tier, status, cleaner_item_count, cleaner:cleaners(name)',
      )
      .eq('id', orderId)
      .maybeSingle();
    if (!order) return { sent: 0, skipped: 'order_not_found' };

    // Before the claim, not after: a customer who has not granted permission
    // yet would otherwise spend the one claim this order gets on a send to
    // nobody, and never hear about it if a device appears later.
    const { data: devices } = await this.db
      .from('device_tokens')
      .select('token, environment')
      .eq('user_id', (order as any).customer_id);
    if (!devices?.length) return { sent: 0, skipped: 'no_devices' };

    const { data: claim, error: claimError } = await this.db
      .from('notifications_sent')
      .insert({ order_id: orderId, user_id: (order as any).customer_id, kind })
      .select('id')
      .maybeSingle();
    if (claimError) {
      // 23505 is the unique index doing its job — somebody already told them.
      // Anything else means the ledger could not answer, and sending without a
      // ledger is how the same person gets notified on every retry.
      if (claimError.code !== '23505') {
        this.log.error({ err: claimError, orderId, kind }, 'could not claim the notification');
        return { sent: 0, skipped: 'ledger_unavailable' };
      }
      return { sent: 0, skipped: 'already_sent' };
    }

    const payload = JSON.stringify({
      aps: {
        alert: alertFor(order),
        sound: 'default',
      },
      // So a tap opens the order rather than the app's front page.
      orderId,
      kind,
    });

    const byEnvironment = new Map<PushEnvironment, string[]>();
    for (const device of devices as any[]) {
      const env: PushEnvironment = device.environment === 'sandbox' ? 'sandbox' : 'production';
      byEnvironment.set(env, [...(byEnvironment.get(env) ?? []), device.token]);
    }

    let sent = 0;
    const stale: string[] = [];
    const errors: string[] = [];
    const misfiled = new Map<PushEnvironment, string[]>();
    for (const [environment, tokens] of byEnvironment) {
      const result = await this.deliver(environment, tokens, payload, `${kind}-${orderId}`, creds);
      sent += result.delivered.length;
      stale.push(...result.stale);
      errors.push(...result.errors);
      if (result.wrongEnvironment.length) {
        const other: PushEnvironment = environment === 'sandbox' ? 'production' : 'sandbox';
        misfiled.set(other, [...(misfiled.get(other) ?? []), ...result.wrongEnvironment]);
      }
    }

    // Only the device knows which APNs it registered against, and it can be
    // wrong: a TestFlight build that could not read its own provisioning
    // profile registered as sandbox, so every send was rejected at Apple and
    // the customer was simply never told their clothes were ready. Nothing
    // downstream notices, because a push that fails is indistinguishable from
    // a push nobody looked at. So retry the other host and correct the row —
    // one wasted request once, instead of silence forever.
    for (const [environment, tokens] of misfiled) {
      const retry = await this.deliver(environment, tokens, payload, `${kind}-${orderId}`, creds);
      sent += retry.delivered.length;
      stale.push(...retry.stale);
      errors.push(...retry.errors);
      // Rejected by both hosts. Record it: an empty error against zero devices
      // is what made this failure invisible in the first place.
      if (retry.wrongEnvironment.length) {
        errors.push(`400 BadDeviceToken on both environments (${retry.wrongEnvironment.length})`);
      }
      if (retry.delivered.length) {
        await this.db
          .from('device_tokens')
          .update({ environment })
          .in('token', retry.delivered);
        this.log.info(
          { orderId, environment, count: retry.delivered.length },
          'device tokens refiled under the environment APNs actually accepts',
        );
      }
    }

    if (stale.length) {
      // 410 is Apple saying the app is gone. Keeping the token means every
      // future send to this customer fails forever, and the failure is silent.
      await this.db.from('device_tokens').delete().in('token', stale);
      this.log.info({ orderId, count: stale.length }, 'pruned device tokens APNs no longer knows');
    }

    if (claim) {
      await this.db
        .from('notifications_sent')
        .update({
          device_count: sent,
          last_error: errors.length ? errors.join('; ').slice(0, 500) : null,
        })
        .eq('id', (claim as any).id);
    }

    this.log.info({ orderId, kind, sent, pruned: stale.length, failed: errors.length }, 'push sent');
    return { sent };
  }

  private async deliver(
    environment: PushEnvironment,
    tokens: string[],
    payload: string,
    collapseId: string,
    creds: { key: KeyObject; keyId: string; teamId: string },
  ): Promise<{
    delivered: string[];
    stale: string[];
    wrongEnvironment: string[];
    errors: string[];
  }> {
    const jwt = this.providerToken(creds);
    const delivered: string[] = [];
    const stale: string[] = [];
    const wrongEnvironment: string[] = [];
    const errors: string[] = [];

    const client = http2.connect(`https://${APNS_HOST[environment]}`);
    // An unhandled 'error' on an http2 session is thrown at the process, which
    // would take the dispatcher down over a push. Per-request handlers below
    // still see it and turn it into a recorded failure.
    client.on('error', (err) => this.log.warn({ err, environment }, 'APNs session error'));
    client.setTimeout(APNS_TIMEOUT_MS, () => client.destroy(new Error('APNs did not answer')));

    try {
      for (const token of tokens) {
        try {
          const res = await request(client, {
            ':method': 'POST',
            ':path': `/3/device/${token}`,
            authorization: `bearer ${jwt}`,
            'apns-topic': config.apns.bundleId,
            'apns-push-type': 'alert',
            'apns-priority': '10',
            // Two sends for the same order collapse into one on the lock
            // screen rather than stacking.
            'apns-collapse-id': collapseId,
          }, payload);

          if (res.status === 200) {
            delivered.push(token);
          } else if (res.status === 410) {
            stale.push(token);
          } else if (res.status === 400 && res.reason === 'BadDeviceToken') {
            // The token is well-formed but belongs to the other APNs. The
            // caller retries it there rather than recording a dead end.
            wrongEnvironment.push(token);
          } else {
            this.log.warn(
              { environment, status: res.status, reason: res.reason },
              'APNs refused a notification',
            );
            errors.push(`${res.status} ${res.reason ?? ''}`.trim());
          }
        } catch (err) {
          errors.push((err as Error).message);
        }
      }
    } finally {
      client.close();
    }

    // A token rejected by both hosts stays put: it is recorded as an error and
    // the next launch re-registers it. Only 410 (Apple: the app is gone) is
    // grounds for deleting somebody's device.
    return { delivered, stale, wrongEnvironment, errors };
  }

  private providerToken(creds: { key: KeyObject; keyId: string; teamId: string }): string {
    const now = Date.now();
    if (!this.jwt || now - this.jwt.mintedAt > TOKEN_TTL_MS) {
      this.jwt = { token: apnsJwt(creds.key, creds.keyId, creds.teamId, now), mintedAt: now };
    }
    return this.jwt.token;
  }

  /** Null until the key exists, and said out loud exactly once. */
  private credentials(): { key: KeyObject; keyId: string; teamId: string } | null {
    const { keyId, teamId, key, keyPath } = config.apns;
    if (!keyId || !teamId || (!key && !keyPath) || this.keyUnusable) {
      if (!this.announcedUnconfigured) {
        this.announcedUnconfigured = true;
        this.log.info('APNs is not configured — push notifications are disabled');
      }
      return null;
    }

    if (!this.key) {
      try {
        // An env file cannot hold the newlines a PEM needs, so an escaped \n is
        // the shape the key actually arrives in.
        const pem = keyPath ? readFileSync(keyPath, 'utf8') : key.replace(/\\n/g, '\n');
        this.key = createPrivateKey(pem);
      } catch (err) {
        // A key that is present and unreadable is a deployment mistake, not a
        // runtime condition. Say so once, then behave exactly as if it were
        // absent — this is called from paths that must not fail.
        this.keyUnusable = true;
        this.log.error({ err }, 'APNs key could not be read — push notifications are disabled');
        return null;
      }
    }

    return { key: this.key, keyId, teamId };
  }
}

function request(
  client: http2.ClientHttp2Session,
  headers: http2.OutgoingHttpHeaders,
  body: string,
): Promise<{ status: number; reason?: string }> {
  return new Promise((resolve, reject) => {
    const req = client.request(headers);
    let status = 0;
    let raw = '';
    req.setEncoding('utf8');
    req.on('response', (h) => {
      status = Number(h[':status'] ?? 0);
    });
    req.on('data', (chunk) => {
      raw += chunk;
    });
    req.on('error', reject);
    req.on('end', () => {
      let reason: string | undefined;
      try {
        reason = raw ? JSON.parse(raw).reason : undefined;
      } catch {
        reason = raw || undefined;
      }
      resolve({ status, reason });
    });
    req.end(body);
  });
}
