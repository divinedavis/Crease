// Test stub for supabase-js, matching only the surface the roadmap page uses:
// a session, and read-only selects against two in-page tables. Auth is a
// localStorage flag so the test can drive the signed-out path too.
(function () {
  const server = {
    prospects: [
      // Brooklyn: 4 of 5 visited, one interested, one follow-up.
      { id: 'p1', borough: 'Brooklyn', kind: 'dry_cleaner', visited: true,  outcome: 'interested' },
      { id: 'p2', borough: 'Brooklyn', kind: 'dry_cleaner', visited: true,  outcome: 'declined' },
      { id: 'p3', borough: 'Brooklyn', kind: 'laundromat',  visited: true,  outcome: 'follow_up' },
      { id: 'p4', borough: 'Brooklyn', kind: 'dry_cleaner', visited: true,  outcome: null },
      { id: 'p5', borough: 'Brooklyn', kind: 'laundromat',  visited: false, outcome: null },
      // A row written before migration 0036 backfilled: the page must read a
      // missing borough as Brooklyn, not drop it.
      { id: 'p6', borough: null,       kind: 'dry_cleaner', visited: false, outcome: null },
      { id: 'q1', borough: 'Queens',   kind: 'dry_cleaner', visited: false, outcome: null },
    ],
    cleaners: [
      { id: 'c1', name: 'Fulton Cleaners',  city: 'Brooklyn',      state: 'NY', postal_code: '11217', active: true },
      { id: 'c2', name: 'Chelsea Cleaners', city: 'New York',      state: 'NY', postal_code: '10001', active: true },
      { id: 'c3', name: 'LIC Cleaners',     city: 'Long Island City', state: 'NY', postal_code: '11101', active: true },
      // 115xx is Nassau County — must land in no borough at all.
      { id: 'c4', name: 'Hempstead Cleaners', city: 'Hempstead',   state: 'NY', postal_code: '11550', active: true },
      // Inactive shops are not partners.
      { id: 'c5', name: 'Closed Cleaners',  city: 'Brooklyn',      state: 'NY', postal_code: '11238', active: false },
      // No usable ZIP: falls back to the city it typed for itself.
      { id: 'c6', name: 'Bay Ridge Cleaners', city: 'Brooklyn',    state: 'NY', postal_code: '', active: true },
    ],
    // Read from localStorage, not a plain field: the reload that exercises
    // this path re-runs the stub and would reset a field.
    get failCleaners() { return localStorage.getItem('stub-fail-cleaners') === '1'; },
  };
  window.__server = server;

  const session = () => {
    const raw = localStorage.getItem('stub-session');
    return raw ? JSON.parse(raw) : null;
  };

  function query(table) {
    const q = {};
    q.select = () => q;
    q.limit = () => q;
    q._run = () => {
      if (!session()) return { data: null, error: { code: '42501', message: 'permission denied' } };
      if (table === 'cleaners' && server.failCleaners) {
        return { data: null, error: { message: 'permission denied for table cleaners' } };
      }
      return { data: server[table].map((r) => ({ ...r })), error: null };
    };
    q.then = (res, rej) => Promise.resolve().then(() => q._run()).then(res, rej);
    return q;
  }

  window.supabase = {
    createClient() {
      return {
        from: (t) => query(t),
        auth: {
          async getSession() { return { data: { session: session() } }; },
          async signInWithPassword({ email, password }) {
            if (password !== 'good') return { error: { message: 'Invalid login credentials' } };
            localStorage.setItem('stub-session', JSON.stringify({ user: { email } }));
            return { error: null };
          },
          async signOut() { localStorage.removeItem('stub-session'); },
          onAuthStateChange() { return { data: { subscription: { unsubscribe() {} } } }; },
        },
      };
    },
  };
})();
