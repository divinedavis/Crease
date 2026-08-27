#!/usr/bin/env python3
"""Give the exported xcresult attachments back the names the test gave them.

`xcresulttool export attachments` writes every attachment under a UUID and
records the real name in a manifest beside them. The composer keys off the
names ("01-home", "05-tracking"), so without this step it finds nothing.

Lifted out of marketing-shots.sh, where it was an inline heredoc: that made
the shell script unquotable inside anything else that used the same delimiter,
and it is easier to read as a file anyway.

    python3 scripts/lib/name-shots.py apps/ios/marketing/raw
"""
from __future__ import annotations

import json
import pathlib
import shutil
import sys


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    manifest = out / "manifest.json"
    if not manifest.exists():
        print("no manifest — nothing exported")
        return 1

    count = 0
    for entry in json.loads(manifest.read_text()):
        for att in entry.get("attachments", []):
            name = att.get("suggestedHumanReadableName") or att.get("exportedFileName")
            src = out / att["exportedFileName"]
            if not src.exists() or not name:
                continue
            stem = pathlib.Path(name).stem
            # Screens are numbered; everything else in a result bundle is not.
            if not stem[:2].isdigit():
                continue
            shutil.copy(src, out / f"{stem}.png")
            count += 1

    print(f"exported {count} named screenshots to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
