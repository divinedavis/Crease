import { scanRedirect } from '@/lib/scan';

/**
 * /r — the counter card. Printed on the piece that sits by a cash register,
 * so the reader is standing in a laundromat with a bag in their hand: the
 * order form, not the sales pitch.
 */
export default async function RegisterScan() {
  return scanRedirect('qr-register', '/order');
}
