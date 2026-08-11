/**
 * Server-side call into the dispatch service.
 *
 * Only ever imported from server actions, so the shared secret and the
 * dispatch URL never reach the browser. The body defaults to '{}' because
 * every dispatch route is a POST and fastify rejects an empty body on a
 * json content-type.
 */

const DISPATCH_URL = process.env.DISPATCH_URL ?? 'http://localhost:8080';

export async function callDispatch(path: string, body: Record<string, unknown> = {}) {
  const res = await fetch(`${DISPATCH_URL}${path}`, {
    method: 'POST',
    headers: {
      'x-crease-key': process.env.INTERNAL_API_KEY!,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
    cache: 'no-store',
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? `dispatch returned ${res.status}`);
  return json;
}
