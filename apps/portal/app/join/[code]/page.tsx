import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase';
import { normalizeInviteCode, splitProspectAddress } from '@/lib/join';
import { GoogleJoinButton, JoinForm } from './join-client';

export const dynamic = 'force-dynamic';

/**
 * Where a shop lands from the link or QR the founder handed them.
 *
 * Public (middleware lets /join/ through), because the person holding the
 * link has no account yet. What it reveals before sign-in is only what
 * peek_shop_invite() returns for a live code: the shop's own name and street,
 * which is on its awning anyway. Unknown, used and expired codes all get the
 * same answer, so the page cannot be used to tell them apart.
 */
export default async function JoinPage({ params }: { params: Promise<{ code: string }> }) {
  const code = normalizeInviteCode((await params).code);
  const db = await supabaseServer();
  const {
    data: { user },
  } = await db.auth.getUser();

  const { data: invite } = code
    ? await db
        .rpc('peek_shop_invite', { p_code: code })
        .maybeSingle<{ label: string; address: string | null; zip: string | null; phone: string | null }>()
    : { data: null };

  if (!invite) {
    // Someone who already finished signing up and opens the link again
    // should land in their portal, not on "this link was used".
    if (user) {
      const { data: staff } = await db.from('cleaner_staff').select('cleaner_id').limit(1);
      if (staff?.length) redirect('/settings');
    }
    return (
      <Shell>
        <div className="card">
          <div className="notice warn">
            This sign-up link has expired or was already used. Ask Crease for a new one.
          </div>
        </div>
      </Shell>
    );
  }

  if (!user) {
    return (
      <Shell>
        <div className="card">
          <h2 style={{ marginTop: 0 }}>{invite.label}</h2>
          <p style={{ color: 'var(--muted)' }}>
            Crease sends couriers to drop off and pick up laundry bags. You wash them at your own
            price per pound, and Crease pays you.
          </p>
          <p style={{ color: 'var(--muted)' }}>It takes about two minutes. Start by signing in:</p>
          <GoogleJoinButton code={code!} />
        </div>
      </Shell>
    );
  }

  const { line1, city } = splitProspectAddress(invite.address);
  return (
    <Shell>
      <JoinForm
        code={code!}
        email={user.email ?? ''}
        defaults={{
          name: invite.label,
          line1,
          city,
          state: 'NY',
          postal_code: invite.zip ?? '',
          phone: invite.phone ?? '',
        }}
      />
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="shell" style={{ maxWidth: 480, paddingTop: 48 }}>
      <h1 style={{ fontSize: 22, marginBottom: 4 }}>Crease</h1>
      <p style={{ color: 'var(--muted)', marginTop: 0, marginBottom: 24 }}>Shop sign-up</p>
      {children}
    </div>
  );
}
