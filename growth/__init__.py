"""Crease growth engine — the daily loop that tries to make the site found.

Modules:
  ledger        what has been tried, what is running, what it measured
  metrics       yesterday's traffic and funnel, into the ledger
  keywords      the queries this site is trying to win
  searchconsole rank, when Search Console is connected (it degrades if not)
  review        judges active techniques and retires the dead ones
  techniques    the executable work: guides, link mesh, IndexNow
  writer        the one LLM call that writes a guide
  scout         the one LLM call that proposes new techniques
  report        the daily email
  snapshot      the PII-free state file the cloud review agent reads
"""
