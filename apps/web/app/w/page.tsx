import { scanRedirect } from '@/lib/scan';

/**
 * /w — the window cling. The reader is on the pavement and has never heard of
 * Crease, so this one lands on the page that explains what it is.
 */
export default async function WindowScan() {
  return scanRedirect('qr-window', '/');
}
