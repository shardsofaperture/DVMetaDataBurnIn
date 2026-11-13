#!/usr/bin/env python3
"""Publish exact source archives and build scripts without modifying vendor files."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

HERE = Path(__file__).resolve().parent

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--archives", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    if a.output.exists():
        p.error("output already exists")
    files = [(p, "scripts/dependencies/" + p.name) for p in sorted(HERE.iterdir()) if p.is_file()]
    files.append((HERE.parents[1] / "LICENSE", "LICENSE"))
    for item in json.loads((HERE / "sources.lock.json").read_text())["archives"]:
        item = item.get("delivery", item)
        path = a.archives / item["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Source hash mismatch: " + str(path))
        files.append((path, "archives/" + item["file"]))
    # Sources are already compressed; do not waste CPU recompressing vendor archives.
    with tarfile.open(a.output, "w") as archive:
        for path, name in files:
            info = archive.gettarinfo(str(path), name)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 1759276800
            with path.open("rb") as f:
                archive.addfile(info, f)
    print(json.dumps({"name": a.output.name, "bytes": a.output.stat().st_size,
                      "sha256": hashlib.sha256(a.output.read_bytes()).hexdigest()}, indent=2))

if __name__ == "__main__":
    main()
