#!/usr/bin/env python3
"""Fail closed on application release identity; Python standard library only."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import tarfile
import zipfile


def verify(tag, manifest, archive, project=None, sources=None):
    match = re.fullmatch(r'v?(\d+\.\d+\.\d+)(?:beta|alpha|[-.][A-Za-z0-9.-]+)?', tag)
    if not match:
        raise ValueError('Not an application version tag')
    version = match[1]
    if manifest['release_tag'] != tag or manifest['version'] != version:
        raise ValueError('Tag and manifest version differ')
    commit = manifest['source_commit']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Manifest requires a full source commit')
    if project:
        versions = re.findall(r'MARKETING_VERSION = ([^;]+);', project.read_text())
        if not versions or set(versions) != {version}:
            raise ValueError('Source project and release version differ')
    identity = manifest['archive']
    if archive.name != identity['name'] or archive.stat().st_size != identity['bytes']:
        raise ValueError('Archive name or size differs from manifest')
    if hashlib.sha256(archive.read_bytes()).hexdigest() != identity['sha256']:
        raise ValueError('Archive SHA-256 differs from manifest')
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None:
            raise ValueError('ZIP CRC failure')
        plists = [n for n in z.namelist() if n.endswith('.app/Contents/Info.plist') and not n.startswith('__MACOSX/')]
        if len(plists) != 1:
            raise ValueError('Expected exactly one application Info.plist')
        plist = plistlib.loads(z.read(plists[0]))
        if plist['CFBundleShortVersionString'] != version:
            raise ValueError('Built Info.plist and release version differ')
        prefix = plists[0].removesuffix('Info.plist')
        embedded = json.loads(z.read(prefix+'Resources/BUILD-MANIFEST.json'))
        for key in ('release_tag', 'version', 'source_commit'):
            if embedded[key] != manifest[key]:
                raise ValueError('Embedded build identity differs: '+key)
        binary = z.read(prefix+'MacOS/'+plist['CFBundleExecutable'])
        if hashlib.sha256(binary).hexdigest() != manifest['executable_sha256']:
            raise ValueError('App executable hash differs')
        for tool, expected in manifest['bundled_tools_sha256'].items():
            if tool not in ('ffmpeg', 'dvrescue'):
                raise ValueError('Unexpected bundled tool')
            if hashlib.sha256(z.read(prefix+'Resources/'+tool)).hexdigest() != expected:
                raise ValueError('Bundled tool hash differs: '+tool)
        for name, expected in manifest.get('bundled_resources_sha256', {}).items():
            if '/' in name or name in ('.', '..'):
                raise ValueError('Expected a flat bundled resource name')
            if hashlib.sha256(z.read(prefix+'Resources/'+name)).hexdigest() != expected:
                raise ValueError('Bundled resource hash differs: '+name)
    if 'dependency_sources' in manifest:
        source_identity = manifest['dependency_sources']
        if not sources or sources.name != source_identity['name'] or sources.stat().st_size != source_identity['bytes']:
            raise ValueError('Matching dependency source delivery is required')
        if hashlib.sha256(sources.read_bytes()).hexdigest() != source_identity['sha256']:
            raise ValueError('Dependency source delivery hash differs')
        with tarfile.open(sources) as t:
            lock_bytes = t.extractfile('scripts/dependencies/sources.lock.json').read()
            if hashlib.sha256(lock_bytes).hexdigest() != source_identity['lock_sha256']:
                raise ValueError('Dependency source lock differs')
            recipe = t.extractfile('scripts/dependencies/build.py').read()
            if hashlib.sha256(recipe).hexdigest() != source_identity['recipe_sha256']:
                raise ValueError('Dependency build recipe differs')
            for item in json.loads(lock_bytes)['archives']:
                item = item.get('delivery', item)
                data = t.extractfile('archives/'+item['file']).read()
                if hashlib.sha256(data).hexdigest() != item['sha256']:
                    raise ValueError('Dependency source archive differs: '+item['file'])
    return {'tag': tag, 'version': version, 'source_commit': commit,
            'archive_sha256': identity['sha256'], 'result': 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--project', type=Path)
    parser.add_argument('--sources', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.tag, json.loads(args.manifest.read_text()), args.archive, args.project, args.sources), indent=2))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        parser.exit(1, 'Release validation failed: '+str(error)+'\n')


if __name__ == '__main__':
    main()
