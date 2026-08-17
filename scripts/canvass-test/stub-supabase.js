// Test stub for supabase-js, matching only the surface the canvass page uses.
// The "server" is an in-page store; auth failures are simulated by clearing the
// session, which makes every write answer 42501 the way PostgREST does under
// the anon role.
(function () {
  const listeners = [];
  const server = {
    rows: [
      { id: 'aaa', osm_id: '1', kind: 'dry_cleaner', name: 'Yes Cleaners', address: null, zip: null,
        phone: null, lat: 40.6, lng: -73.9, neighborhood: 'Clinton Hill', visited: true,
        visited_at: null, outcome: null, notes: null, full_service: null, own_app: null,
        cash_only: null, created_at: null, updated_at: null },
      { id: 'bbb', osm_id: '2', kind: 'dry_cleaner', name: 'Atlantic Dry Cleaners', address: '68 Bond', zip: '11217',
        phone: null, lat: 40.6, lng: -73.9, neighborhood: 'Boerum Hill', visited: true,
        visited_at: null, outcome: 'follow_up', notes: null, full_service: null, own_app: true,
        cash_only: null, created_at: null, updated_at: null },
    ],
    writes: [],
    offline: false,
  };
  window.__server = server;

  const DENIED = { code: '42501', details: null, hint: null, message: 'permission denied for table prospects' };

  const session = () => {
    const raw = localStorage.getItem('stub-session');
    return raw ? JSON.parse(raw) : null;
  };
  window.__expire = () => { localStorage.removeItem('stub-session'); };

  function query(table) {
    const q = { _filters: {}, _op: null, _payload: null };
    q.select = () => q;
    q.limit = () => q;
    q.eq = (col, val) => { q._filters[col] = val; return q; };
    q.update = (payload) => { q._op = 'update'; q._payload = payload; return q; };
    q.maybeSingle = () => q.then.call(q, (r) => r).then ? q : q;
    q._run = () => {
      if (server.offline) return { data: null, error: { message: 'Failed to fetch' } };
      if (q._op === 'update') {
        if (!session()) return { data: null, error: DENIED };
        if (server.rlsDenies) return { data: [], error: null };   // policy refusal: 0 rows, no error
        const row = server.rows.find((r) => r.id === q._filters.id);
        if (row) Object.assign(row, q._payload);
        server.writes.push({ id: q._filters.id, payload: { ...q._payload } });
        return { data: row ? [{ id: row.id }] : [], error: null };
      }
      if (!session()) return { data: null, error: DENIED };
      let rows = server.rows.map((r) => ({ ...r }));
      if (q._filters.id) rows = rows.filter((r) => r.id === q._filters.id);
      return { data: q._single ? (rows[0] ?? null) : rows, error: null };
    };
    q.then = (res, rej) => Promise.resolve().then(() => q._run()).then(res, rej);
    const maybeSingle = () => { q._single = true; return q; };
    q.maybeSingle = maybeSingle;
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
            listeners.forEach((cb) => cb('SIGNED_IN'));
            return { error: null };
          },
          async signOut() { localStorage.removeItem('stub-session'); listeners.forEach((cb) => cb('SIGNED_OUT')); },
          onAuthStateChange(cb) { listeners.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
        },
      };
    },
  };
})();
