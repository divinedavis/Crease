import fs from 'node:fs';
import path from 'node:path';

/**
 * Guides the growth engine writes, read at request time.
 *
 * The engine runs on the droplet; this app is built on a laptop and rsynced.
 * A technique that had to trigger `next build` to publish a page could not run
 * unattended at 5am — the box has ~800MB free and shares it with five other
 * production sites, and an OOM during a rebuild takes all of them down. So the
 * engine writes JSON into `content/guides/` and the route below renders it.
 * Publishing a page becomes a file write, and nothing is rebuilt or restarted.
 *
 * Consequences that are easy to forget:
 *   - `deploy/deploy.sh` excludes `content/`, or its `rsync --delete` would
 *     erase every page the engine has ever published.
 *   - Nothing here is trusted. The engine validates what a model writes before
 *     it writes the file, and this validates it again on read, because the two
 *     halves ship independently and only one of them is in this repo's build.
 */

export interface GuideSection {
  heading: string;
  body: string[];
}

export interface GuideFaq {
  q: string;
  a: string;
}

export interface Guide {
  slug: string;
  title: string;
  description: string;
  /** ISO date the engine first published it. */
  published: string;
  /** ISO date of the last content change — feeds sitemap <lastmod>. */
  updated: string;
  intro: string;
  sections: GuideSection[];
  faq: GuideFaq[];
  /** Neighborhood slugs this guide is most relevant to, for the link mesh. */
  areas: string[];
}

/**
 * A slug is a URL forever and also a filename. Anchoring both ends and
 * refusing dots is what keeps `../../etc/passwd` from being a guide.
 */
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+){1,12}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isGuideSlug(slug: string): boolean {
  return SLUG_RE.test(slug) && slug.length <= 90;
}

export function guidesDir(): string {
  const base = process.env.CREASE_CONTENT_DIR || path.join(process.cwd(), 'content');
  return path.join(base, 'guides');
}

function str(v: unknown, max: number): string {
  return typeof v === 'string' ? v.trim().slice(0, max) : '';
}

function strList(v: unknown, maxItems: number, maxLen: number): string[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((x) => str(x, maxLen))
    .filter(Boolean)
    .slice(0, maxItems);
}

/**
 * Parse one guide file. Returns null rather than throwing: one malformed file
 * must not take the whole /guides index down with it.
 */
export function parseGuide(slug: string, raw: string): Guide | null {
  if (!isGuideSlug(slug)) return null;
  let doc: Record<string, unknown>;
  try {
    doc = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return null;
  }
  const title = str(doc.title, 120);
  const description = str(doc.description, 300);
  const intro = str(doc.intro, 1200);
  if (!title || !description || !intro) return null;

  const sections: GuideSection[] = (Array.isArray(doc.sections) ? doc.sections : [])
    .slice(0, 12)
    .map((s) => {
      const sec = (s ?? {}) as Record<string, unknown>;
      return { heading: str(sec.heading, 140), body: strList(sec.body, 10, 1600) };
    })
    .filter((s) => s.heading && s.body.length);
  if (!sections.length) return null;

  const faq: GuideFaq[] = (Array.isArray(doc.faq) ? doc.faq : [])
    .slice(0, 10)
    .map((f) => {
      const item = (f ?? {}) as Record<string, unknown>;
      return { q: str(item.q, 200), a: str(item.a, 900) };
    })
    .filter((f) => f.q && f.a);

  const published = ISO_RE.test(String(doc.published)) ? String(doc.published) : '';
  const updated = ISO_RE.test(String(doc.updated)) ? String(doc.updated) : published;

  return {
    slug,
    title,
    description,
    published,
    updated,
    intro,
    sections,
    faq,
    areas: strList(doc.areas, 12, 60).filter(isGuideSlug),
  };
}

export function getGuide(slug: string): Guide | null {
  if (!isGuideSlug(slug)) return null;
  const file = path.join(guidesDir(), `${slug}.json`);
  // The slug regex already forbids '.' and '/', so this cannot escape the
  // directory; the resolve check is the belt to that braces, and costs nothing.
  if (path.dirname(path.resolve(file)) !== path.resolve(guidesDir())) return null;
  try {
    return parseGuide(slug, fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/** Every readable guide, newest first. */
export function allGuides(): Guide[] {
  let names: string[];
  try {
    names = fs.readdirSync(guidesDir());
  } catch {
    return []; // no content dir yet — a site with no guides, not an error
  }
  const out: Guide[] = [];
  for (const name of names) {
    if (!name.endsWith('.json')) continue;
    const g = getGuide(name.slice(0, -5));
    if (g) out.push(g);
  }
  return out.sort((a, b) => (b.published || '').localeCompare(a.published || ''));
}

/**
 * Serialise for a <script type="application/ld+json">.
 *
 * JSON.stringify happily emits `</script>` inside a string value, which ends
 * the block early and drops whatever follows into the document as markup. The
 * guide text comes from a model, so this is not hypothetical.
 */
export function ldJson(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c').replace(/>/g, '\\u003e');
}
