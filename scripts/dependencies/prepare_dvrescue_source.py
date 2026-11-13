#!/usr/bin/env python3
"""Remove unrelated GUI media and prebuilt binaries from the upstream CLI source delivery."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = 'dvrescue_CLI_GNU_FromSource/'
EXCLUDED = ('dvrescue/Source/GUI', 'dvrescue/docs', 'MediaInfoLib/Contrib')
UPSTREAM_SHA256 = 'e3089cf62757bb2a87bb38c353acf37c03195bcc8bcbf17565f7cb9b8ee51a72'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('upstream', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    if a.output.exists():
        p.error('output already exists')
    if hashlib.sha256(a.upstream.read_bytes()).hexdigest() != UPSTREAM_SHA256:
        raise ValueError('Unexpected upstream archive')
    kept = 0
    # Deterministic uncompressed tar; metadata is preserved from the vendor archive.
    with tarfile.open(a.upstream) as source, tarfile.open(a.output, 'w') as target:
        for member in source:
            relative = member.name.removeprefix(ROOT).rstrip('/')
            if any(relative == path or relative.startswith(path+'/') for path in EXCLUDED):
                continue
            target.addfile(member, source.extractfile(member) if member.isfile() else None)
            kept += 1
    print(json.dumps(dict(file=a.output.name, sha256=hashlib.sha256(a.output.read_bytes()).hexdigest(),
                         bytes=a.output.stat().st_size, upstream_sha256=UPSTREAM_SHA256,
                         excluded_prefixes=list(EXCLUDED), retained_members=kept), indent=2))

if __name__ == '__main__':
    main()
