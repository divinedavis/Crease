import QRCode from 'qrcode';
import { normalizeInviteCode } from '@/lib/join';
import { publicOrigin } from '@/lib/public-origin';

/**
 * The join link as a QR code, for the shop to scan off the founder's phone.
 *
 * Encodes nothing but the link itself, so it is safe to serve to anyone who
 * already has the code, and it does not look the code up: a QR for a dead
 * code just lands on the page that says so. The middleware matcher skips
 * .svg paths, so this needs no session.
 */
export async function GET(request: Request, { params }: { params: Promise<{ code: string }> }) {
  const code = normalizeInviteCode((await params).code);
  if (!code) return new Response('not found', { status: 404 });
  const svg = await QRCode.toString(`${publicOrigin(request.headers)}/join/${code}`, {
    type: 'svg',
    margin: 2,
    errorCorrectionLevel: 'M',
  });
  return new Response(svg, {
    headers: {
      'content-type': 'image/svg+xml',
      'cache-control': 'private, max-age=300',
      'x-content-type-options': 'nosniff',
    },
  });
}
