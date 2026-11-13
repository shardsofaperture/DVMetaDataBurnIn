#!/usr/bin/env python3
"""Check local file targets in project Markdown; no network or third-party docs."""
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit


def main():
    root = Path(__file__).resolve().parents[1]
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    errors = []
    count = 0
    for name in files:
        if not name.lower().endswith('.md') or name.startswith('Resources/'):
            continue
        path = root / name
        # Ignore fenced examples. Handle ordinary inline links/images, including spaces.
        source = re.sub(r'^```.*?^```[^\n]*$', '', path.read_text(), flags=re.M | re.S)
        for match in re.finditer(r'!?\[[^\]]*\]\((<[^>]+>|[^)]+)\)', source):
            target = match[1].strip().strip('<>')
            target = re.sub(r'\s+"[^"]*"$', '', target)
            url = urlsplit(target)
            if url.scheme or url.netloc or not url.path:
                continue
            count += 1
            resolved = (root if url.path.startswith('/') else path.parent) / unquote(url.path).lstrip('/')
            if not resolved.exists():
                line = source[:match.start()].count('\n') + 1
                errors.append(f'{name}:{line}: missing {target}')
    for error in errors:
        print(error)
    print(f'Checked {count} local Markdown file targets; {len(errors)} missing.')
    raise SystemExit(bool(errors))


if __name__ == '__main__':
    main()
