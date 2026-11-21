/**
 * What a GET to a courier's webhook address answers.
 *
 * Couriers POST status updates there. A GET is either a person pasting the
 * address into a browser or a courier dashboard checking the address exists
 * before saving it; a 404 tells both of them it is broken when it is not.
 * The answer says only that the address is ready: no configuration, no
 * whether a secret is set.
 */
export function webhookProbe(provider: { name: string } | undefined): {
  code: number;
  body: Record<string, unknown>;
} {
  if (!provider) return { code: 404, body: { error: 'unknown provider' } };
  return {
    code: 200,
    body: { ok: true, provider: provider.name, note: 'Webhook address is ready. Couriers send updates here by POST.' },
  };
}
