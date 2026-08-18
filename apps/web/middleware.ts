import { NextResponse, type NextRequest } from 'next/server';

/**
 * Keep the owner's devices out of the traffic count as they move.
 *
 * A device that has been marked with /?owner=1 carries a cookie. Every request
 * it makes from a new network re-registers that address, so switching from
 * home wifi to cell does not silently turn the person building the site into
 * a visitor. The registration itself is a fire-and-forget call to the route
 * that owns the file.
 */
export function middleware(request: NextRequest) {
  const marked = request.cookies.get('crease_owner')?.value === '1';
  const asking = request.nextUrl.searchParams.has('owner');
  if (marked && !asking && request.nextUrl.pathname === '/') {
    const url = new URL('/api/owner', request.url);
    url.searchParams.set('owner', '1');
    // Not awaited: the visitor should never wait on our own bookkeeping.
    fetch(url, { headers: { 'x-real-ip': request.headers.get('x-real-ip') ?? '' } }).catch(
      () => undefined,
    );
  }
  return NextResponse.next();
}

export const config = { matcher: ['/'] };
