#!/usr/bin/env python3
"""The executable growth techniques.

Every technique is a function named `t_<slug>` taking a Context and returning a
dict describing what it did. The slug matches a record in the ledger, and the
ledger alone decides what runs — flipping a technique to "retired" stops it
tomorrow with no code change, which is what lets review.py prune on its own.

A technique must be:

  idempotent      it runs every morning, and a second run the same day changes
                  nothing. `ok: True, detail: "nothing to do"` is a good day.
  honest          it never fabricates data and never publishes an empty page
                  just to have a URL to submit.
  attributable    it declares URL prefixes, so metrics.py can say whether it
                  earned anything and review.py can retire it if it did not.
  cheap           only one technique here calls a model, and it makes exactly
                  one call. See BUDGET.md.

Guardrails, learned elsewhere and kept here:

  * **never delete** a file. Nothing in this module unlinks anything.
  * **write atomically**, because the site reads these files at request time
    and a half-written one is a 500 on a live page.
  * **at most one new page per run.** A hundred thin pages overnight is exactly
    the pattern Google's scaled-content policy targets.
"""
import glob
import json
import os
import urllib.error
import urllib.request

from . import facts, keywords, ledger, writer

SITE = facts.SITE
INDEXNOW_ENDPOINT = "https://api.indexnow.org/indexnow"


class Context:
    """Everything a technique needs: where content lives, and what it published.

    `content_dir` is the directory the running site reads guides out of. On the
    droplet that is /opt/crease/apps/web/content and this process writes it
    directly — there is no staging step, because there is nothing to rsync: the
    site renders these files where they land. `deploy/deploy.sh` excludes the
    directory so a later code deploy cannot delete them.
    """

    def __init__(self, content_dir, dry_run=False, log=print):
        self.content_dir = content_dir
        self.dry_run = dry_run
        self.log = log
        self.new_urls = []
        self.changed_urls = []

    def guides(self):
        out = []
        for path in sorted(glob.glob(os.path.join(self.content_dir, "guides", "*.json"))):
            try:
                with open(path) as f:
                    doc = json.load(f)
                doc["_path"] = path
                out.append(doc)
            except Exception:
                continue
        return out


# ------------------------------------------------------------------- guides

def t_guides(ctx):
    """Answer the oldest question on the site that nothing answers.

    Publishes at most one guide, and only when the queue holds a query with no
    page behind it. An empty queue is a success, not a failure — it means every
    tracked question has an answer and the scout's job is to find more.
    """
    queue = [k for k in keywords.guide_queue(limit=40)]
    have = set(writer.published(ctx.content_dir))
    if not queue:
        return {"ok": True, "detail": "queue empty — every tracked question has a page"}

    target = queue[0]
    if ctx.dry_run:
        return {"ok": True, "detail": f"would write a guide for {target['query']!r} "
                                      f"({len(queue)} queries queued)"}

    try:
        guide, _resp = writer.draft(target["query"])
    except writer.Rejected as e:
        # A refused draft is a real outcome, not a crash: the query stays in the
        # queue and tomorrow tries again. Recorded so a run of refusals is
        # visible in the report instead of looking like an idle morning.
        ledger.set_state("writer_last", {"date": ledger.today(), "ok": False,
                                         "query": target["query"], "error": str(e)})
        return {"ok": False, "detail": f"draft refused: {e}"}
    except Exception as e:
        ledger.set_state("writer_last", {"date": ledger.today(), "ok": False,
                                         "query": target["query"], "error": str(e)})
        return {"ok": False, "detail": f"writer failed: {e}"}

    if guide["slug"] in have:
        # The model reached for a slug that already exists. Do not overwrite a
        # published page with a different question's answer.
        ledger.set_state("writer_last", {"date": ledger.today(), "ok": False,
                                         "query": target["query"],
                                         "error": f"slug {guide['slug']} already published"})
        return {"ok": False, "detail": f"slug collision on {guide['slug']} — not overwritten"}

    path, url, created = writer.write_guide(ctx.content_dir, guide, dry_run=False)
    (ctx.new_urls if created else ctx.changed_urls).append(url)
    keywords.set_target(target["query"], url)
    ledger.set_state("writer_last", {"date": ledger.today(), "ok": True,
                                     "query": target["query"], "slug": guide["slug"],
                                     "url": url})
    return {"ok": True, "detail": f"published {url} for {target['query']!r} "
                                  f"({len(queue) - 1} left in the queue)",
            "url": url, "path": path}


# ---------------------------------------------------------------- link mesh

def t_link_mesh(ctx):
    """Keep every guide pointing at neighborhoods, and every neighborhood at guides.

    The renderer builds both directions out of a guide's `areas` list, so the
    mesh is only as good as that list. A guide with no valid areas is an
    orphan: nothing on the site links to it except the hub, and an orphan is
    the page search engines are slowest to trust.

    Costs nothing and calls nothing. Most of what this engine does should look
    like this.
    """
    known = set(writer.area_slugs())
    fixed, orphans = [], []
    for g in ctx.guides():
        areas = [a for a in (g.get("areas") or []) if a in known]
        if areas:
            continue
        orphans.append(g.get("slug"))
        if ctx.dry_run:
            continue
        g2 = {k: v for k, v in g.items() if not k.startswith("_")}
        g2["areas"] = writer.area_slugs()[:6]
        tmp = g["_path"] + ".tmp"
        with open(tmp, "w") as f:
            json.dump(g2, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, g["_path"])
        fixed.append(g.get("slug"))
        ctx.changed_urls.append(f"/guides/{g.get('slug')}")
    if not orphans:
        return {"ok": True, "detail": f"{len(ctx.guides())} guides, all linked"}
    if ctx.dry_run:
        return {"ok": True, "detail": f"would relink {len(orphans)} orphaned guides"}
    return {"ok": True, "detail": f"relinked {len(fixed)}: {', '.join(fixed)}"}


# ----------------------------------------------------------------- indexnow

def indexnow_key():
    """The key, from the file the site serves it at.

    IndexNow verifies ownership by fetching https://host/<key>.txt and checking
    it contains the key. The file lives in apps/web/public/, so the key is
    discoverable from a checkout and there is nothing to configure — and if the
    file was never deployed, submission fails loudly rather than silently
    posting to an endpoint that will reject it.
    """
    env = os.environ.get("CREASE_INDEXNOW_KEY")
    if env:
        return env.strip()
    root = os.environ.get("CREASE_PUBLIC_DIR")
    roots = [root] if root else [
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "apps", "web", "public"),
        "/opt/crease/apps/web/public",
    ]
    for r in roots:
        for path in glob.glob(os.path.join(r or "", "*.txt")):
            name = os.path.basename(path)[:-4]
            if len(name) >= 8 and all(c in "0123456789abcdef" for c in name):
                return name
    return None


def t_indexnow(ctx):
    """Tell the search engines that take a hint.

    Google does not participate — it re-crawls from the sitemap's <lastmod>,
    which is why the sitemap reports the date a guide actually changed and not
    today's date. Bing, Yandex and Seznam do, and on a site this small the
    difference between "indexed this week" and "indexed next month" is most of
    the value a new page has.

    Only URLs this run created or changed. Resubmitting the whole site every
    morning is how a host gets its submissions ignored.
    """
    urls = list(dict.fromkeys(ctx.new_urls + ctx.changed_urls))
    if not urls:
        return {"ok": True, "detail": "nothing new to submit"}
    key = indexnow_key()
    if not key:
        return {"ok": False, "detail": "no IndexNow key file found in apps/web/public — "
                                       "cannot submit (the key must be web-served to verify)"}
    if ctx.dry_run:
        return {"ok": True, "detail": f"would submit {len(urls)} URLs"}

    host = SITE.split("//", 1)[1]
    body = json.dumps({
        "host": host,
        "key": key,
        "keyLocation": f"{SITE}/{key}.txt",
        "urlList": [SITE + u for u in urls],
    }).encode()
    req = urllib.request.Request(INDEXNOW_ENDPOINT, data=body,
                                 headers={"content-type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        # 422 is "the key does not verify" and is the one worth reading: it
        # means the .txt file is not being served, not that the URLs are bad.
        return {"ok": False, "detail": f"IndexNow rejected the submission: HTTP {e.code} "
                                       f"{e.read().decode('utf-8', 'replace')[:120]}"}
    except Exception as e:
        return {"ok": False, "detail": f"IndexNow unreachable: {e}"}
    ledger.set_state("indexnow_last", {"date": ledger.today(), "urls": urls, "http": code})
    return {"ok": True, "detail": f"submitted {len(urls)} URLs (HTTP {code})"}


# The order techniques run in. Guides first, because the mesh and the
# submission both need to see what it published this morning.
ORDER = ["guides", "link_mesh", "indexnow"]

REGISTRY = {
    "guides": t_guides,
    "link_mesh": t_link_mesh,
    "indexnow": t_indexnow,
}
