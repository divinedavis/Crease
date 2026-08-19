/**
 * The nav and footer every page below the home page shares.
 *
 * The home page keeps its own — it advertises services and neighborhoods in
 * the footer and is the only page that should. These are for the pages the
 * growth engine multiplies: one copy, so adding a section to the site does not
 * mean remembering to add it to thirty neighborhood pages and every guide.
 */
export function SiteNav({ guides = true }: { guides?: boolean }) {
  return (
    <nav className="wrap nav">
      <div className="brand">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src="/assets/icon.svg" alt="" width={34} height={34} />
        <a href="/" style={{ color: 'inherit', textDecoration: 'none' }}>
          Crease
        </a>
      </div>
      <div className="links">
        <a href="/order">Order</a>
        <a href="/#areas">Where we collect</a>
        {guides && <a href="/guides">Guides</a>}
      </div>
      <a href="/order" style={{ color: 'var(--green)' }}>
        Book a pickup
      </a>
    </nav>
  );
}

export function SiteFooter() {
  return (
    <footer className="sitefoot">
      <div className="wrap">
        <div className="footgrid">
          <div>
            <h4>Crease</h4>
            <ul>
              <li>
                <a href="/order">Book a pickup</a>
              </li>
              <li>
                <a href="/#areas">Where we collect</a>
              </li>
              <li>
                <a href="/guides">Guides</a>
              </li>
              <li>
                <a href="mailto:divinejdavis@gmail.com">Contact</a>
              </li>
            </ul>
          </div>
          <div>
            <h4>Service</h4>
            <ul>
              <li>Wash &amp; fold · $2.00/lb</li>
              <li>$20 minimum</li>
              <li>Dry cleaning · soon</li>
            </ul>
          </div>
          <div className="legal">
            © 2026 Crease · <a href="/privacy.html">Privacy</a>
          </div>
        </div>
      </div>
    </footer>
  );
}
