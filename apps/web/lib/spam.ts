/**
 * Junk from the web pickup form. Two bot submissions (2026-09-13, 09-24) came
 * in with a crypto-scam link as the name and six random characters in every
 * other field, and sat on the owner dashboard as people waiting on a call.
 */

/** A filled bot-trap field, or a link where a name goes. */
export function looksLikeSpam(trap: string, name: string): boolean {
  if (trap.trim()) return true;
  return /(https?:\/\/|www\.|[a-z0-9-]+\.(org|com|net|io|ru|xyz|top|info)\/)/i.test(name);
}

/** A street address has a number and a street, so at least one space. */
export function looksLikeStreetAddress(address: string): boolean {
  return address.trim().length >= 3 && /\s/.test(address.trim());
}
