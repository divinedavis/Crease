#!/usr/bin/env python3
"""One look and one sender for everything this engine emails.

The constraints are not stylistic — each one is a way these emails silently
fail if it is ignored:

  inline CSS only   Gmail strips <style> blocks. A stylesheet in the head
                    becomes an unstyled email for a large share of recipients,
                    and it renders fine in your own client so you never see it.
  no images         An email with no images renders identically whether or not
                    the client blocks them, which most do by default. It also
                    means no tracking pixel, which we are not doing.
  a real text part  multipart/alternative with a plain-text body written for a
                    reader, not stripped tags. A junk text part is a spam signal.
  explicit colours  Dark-mode clients invert unstyled backgrounds and leave
                    styled text where it was. Every container sets both.
"""
import os
import re
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr

SITE = "https://creasenyc.com"
BRAND = "Crease"

# The site's own palette (apps/web/app/globals.css), so the report looks like
# the thing it is reporting on.
GREEN = "#1F705C"
INK = "#17211E"
INK2 = "#5C6B66"
LINE = "#E3E8E6"
PAPER = "#FFFFFF"
SOFT = "#F7F8F7"
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"

GOOD, GOOD_BG = "#0b7a4b", "#eaf7f0"
BAD, BAD_BG = "#b42318", "#fef3f2"
WARN, WARN_BG = "#b54708", "#fff8eb"
TONES = {"good": (GOOD, GOOD_BG), "bad": (BAD, BAD_BG), "warn": (WARN, WARN_BG),
         "info": (GREEN, "#E7F1ED"), "mute": (INK2, SOFT)}


def esc(s):
    return (str(s if s is not None else "").replace("&", "&amp;")
            .replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))


def safe_url(u):
    """Only http(s), mailto and site-relative links reach an href.

    Some URLs in these emails were written by a model — the scout's evidence
    links. esc() stops attribute injection but not a `javascript:` href, so the
    scheme is checked here rather than trusted at a dozen call sites.
    """
    s = str(u or "").strip()
    if re.match(r"^(https?://|mailto:|/|#)", s, re.I) and "\n" not in s:
        return s
    return "#"


def _section(title, rows, tone=None):
    """rows: list of (label, value) or plain strings."""
    fg, bg = TONES.get(tone or "mute", TONES["mute"])
    out = [f'<tr><td style="padding:18px 24px 6px;font:600 13px/1.4 {FONT};'
           f'color:{fg};background:{PAPER};letter-spacing:.04em;'
           f'text-transform:uppercase">{esc(title)}</td></tr>']
    body = []
    for r in rows:
        if isinstance(r, (tuple, list)) and len(r) == 2:
            body.append(
                f'<div style="margin:0 0 6px"><span style="color:{INK2};font:400 14px/1.5 {FONT}">'
                f'{esc(r[0])}</span> <span style="color:{INK};font:600 14px/1.5 {FONT}">'
                f'{esc(r[1])}</span></div>')
        else:
            body.append(f'<div style="margin:0 0 6px;color:{INK};font:400 14px/1.55 {FONT}">'
                        f'{esc(r)}</div>')
    if not body:
        body.append(f'<div style="color:{INK2};font:400 14px/1.5 {FONT}">nothing</div>')
    out.append(f'<tr><td style="padding:0 24px 10px;background:{PAPER};'
               f'border-bottom:1px solid {LINE}">{"".join(body)}</td></tr>')
    if tone in ("bad", "warn"):
        out[-1] = out[-1].replace(f"background:{PAPER}", f"background:{bg}")
    return "".join(out)


def render(title, intro, sections, footer=""):
    """sections: list of (heading, rows, tone). Returns (html, text)."""
    parts = [
        f'<tr><td style="padding:26px 24px 4px;background:{PAPER}">'
        f'<div style="font:700 20px/1.3 {FONT};color:{INK}">{esc(title)}</div>'
        f'<div style="font:400 14px/1.6 {FONT};color:{INK2};margin-top:6px">{esc(intro)}</div>'
        f'</td></tr>']
    for heading, rows, tone in sections:
        parts.append(_section(heading, rows, tone))
    parts.append(
        f'<tr><td style="padding:18px 24px 26px;background:{PAPER};'
        f'font:400 12px/1.6 {MONO};color:{INK2}">'
        f'{esc(footer)}<br><a href="{SITE}" style="color:{GREEN}">{SITE}</a></td></tr>')

    html = (f'<!doctype html><html><body style="margin:0;padding:24px 12px;'
            f'background:{SOFT}">'
            f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
            f'style="max-width:600px;margin:0 auto;border:1px solid {LINE};'
            f'border-radius:12px;overflow:hidden;background:{PAPER}">'
            f'{"".join(parts)}</table></body></html>')

    tl = [title, "=" * len(title), "", intro, ""]
    for heading, rows, _tone in sections:
        tl.append(heading.upper())
        if not rows:
            tl.append("  nothing")
        for r in rows:
            if isinstance(r, (tuple, list)) and len(r) == 2:
                tl.append(f"  {r[0]} {r[1]}")
            else:
                tl.append(f"  {r}")
        tl.append("")
    tl.append(footer)
    tl.append(SITE)
    return html, "\n".join(tl)


def smtp_configured():
    return all(os.environ.get(k) for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD"))


def send(to, subject, html, text):
    host = os.environ.get("SMTP_HOST")
    user = os.environ.get("SMTP_USER")
    pw = os.environ.get("SMTP_PASSWORD")
    if not (host and user and pw):
        raise RuntimeError("SMTP_HOST / SMTP_USER / SMTP_PASSWORD not set")
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = formataddr((f"{BRAND} growth", os.environ.get("SMTP_FROM", user)))
    msg["To"] = to
    msg.attach(MIMEText(text, "plain", "utf-8"))
    msg.attach(MIMEText(html, "html", "utf-8"))
    with smtplib.SMTP(host, int(os.environ.get("SMTP_PORT", "587")), timeout=30) as s:
        s.starttls()
        s.login(user, pw)
        s.send_message(msg)
    return True
