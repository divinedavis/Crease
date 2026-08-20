/* One sign-in for every page served off this origin.
 *
 * The cleaner portal signs in through @supabase/ssr, which keeps the session
 * in a cookie. Plain supabase-js keeps it in localStorage. Same origin, two
 * drawers — so a page using the defaults asks for its own login even though
 * the session is already sitting there. This adapter puts supabase-js in the
 * same drawer as the portal.
 *
 * It lives in its own file, loaded by both index.html and roadmap.html,
 * because the first version of this fix was pasted inline into index.html
 * only and roadmap.html went on asking for a second login. Two copies of an
 * auth detail is how that happens; there is now one.
 *
 * Format is @supabase/ssr 0.5.2's, exactly:
 *
 *   name    sb-<project-ref>-auth-token  — supabase-js and @supabase/ssr
 *           derive this identically, so callers must NOT set storageKey
 *   value   "base64-" + base64url(JSON)
 *   chunks  <name>.0, <name>.1, … above 3180 chars; read by trying the
 *           unchunked name first, then counting up until one is missing
 *
 * This works only because the portal deliberately leaves httpOnly off, for
 * its own realtime client (apps/portal/lib/session-cookie.ts). Turn httpOnly
 * on there and every page here goes back to asking for its own login, with no
 * error anywhere to say why.
 */
(function (root) {
  var CHUNK = 3180;
  var B64 = 'base64-';
  var MAX_AGE = 60 * 60 * 24 * 7;   // matches the portal's cookie lifetime

  function b64urlEncode(str) {
    var bytes = new TextEncoder().encode(str), bin = '';
    bytes.forEach(function (b) { bin += String.fromCharCode(b); });
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function b64urlDecode(str) {
    var pad = str.replace(/-/g, '+').replace(/_/g, '/');
    var bin = atob(pad + '='.repeat((4 - (pad.length % 4)) % 4));
    return new TextDecoder().decode(Uint8Array.from(bin, function (c) { return c.charCodeAt(0); }));
  }
  function read(name) {
    var hit = document.cookie.split('; ').find(function (c) { return c.indexOf(name + '=') === 0; });
    return hit ? decodeURIComponent(hit.slice(name.length + 1)) : null;
  }
  function write(name, value) {
    var secure = location.protocol === 'https:' ? '; Secure' : '';
    document.cookie = name + '=' + encodeURIComponent(value)
      + '; Path=/; Max-Age=' + MAX_AGE + '; SameSite=Lax' + secure;
  }
  function drop(name) {
    var secure = location.protocol === 'https:' ? '; Secure' : '';
    document.cookie = name + '=; Path=/; Max-Age=0; SameSite=Lax' + secure;
  }

  root.creaseCookieStorage = {
    getItem: function (key) {
      var raw = read(key);
      if (!raw) {
        var parts = [];
        for (var i = 0; ; i++) {
          var part = read(key + '.' + i);
          if (!part) break;
          parts.push(part);
        }
        if (!parts.length) return null;
        raw = parts.join('');
      }
      if (raw.indexOf(B64) !== 0) return raw;   // plain JSON: an older writer
      try { return b64urlDecode(raw.slice(B64.length)); } catch (e) { return null; }
    },
    setItem: function (key, value) {
      var encoded = B64 + b64urlEncode(value);
      // Clear the old shape first, or a shorter session leaves a stale `.1`
      // that the reader concatenates onto the new `.0` and gets garbage.
      root.creaseCookieStorage.removeItem(key);
      if (encoded.length <= CHUNK) { write(key, encoded); return; }
      for (var i = 0; i * CHUNK < encoded.length; i++) {
        write(key + '.' + i, encoded.slice(i * CHUNK, (i + 1) * CHUNK));
      }
    },
    removeItem: function (key) {
      drop(key);
      for (var i = 0; i < 16; i++) drop(key + '.' + i);
    },
  };
})(window);
