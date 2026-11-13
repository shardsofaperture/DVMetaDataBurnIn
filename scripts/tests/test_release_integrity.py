import hashlib
import io
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import tarfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('verify_release', Path(__file__).parents[1]/'verify_release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root/'app.zip'
        self.project = self.root/'project.pbxproj'
        self.project.write_text('MARKETING_VERSION = 1.0.7;\nMARKETING_VERSION = 1.0.7;')
        self.manifest = dict(release_tag='v1.0.7-maintenance.2', version='1.0.7', source_commit='a'*40,
                             executable_sha256=hashlib.sha256(b'app').hexdigest(), bundled_tools_sha256={})
        self.package()

    def package(self, version='1.0.7', embedded=None):
        with zipfile.ZipFile(self.archive, 'w') as z:
            z.writestr('App.app/Contents/Info.plist', plistlib.dumps(dict(CFBundleShortVersionString=version, CFBundleExecutable='App')))
            z.writestr('App.app/Contents/MacOS/App', b'app')
            z.writestr('App.app/Contents/Resources/BUILD-MANIFEST.json', json.dumps(embedded or self.manifest))
        self.manifest['archive'] = dict(name='app.zip', bytes=self.archive.stat().st_size,
                                       sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest())

    def check(self):
        return module.verify('v1.0.7-maintenance.2', self.manifest, self.archive, self.project)

    def test_valid_package(self):
        self.assertEqual(self.check()['result'], 'passed')

    def test_historical_style_plist_mismatch(self):
        self.package(version='1.0.6')
        with self.assertRaisesRegex(ValueError, 'Info.plist'): self.check()

    def test_project_mismatch(self):
        self.project.write_text('MARKETING_VERSION = 1.0.6;')
        with self.assertRaisesRegex(ValueError, 'Source project'): self.check()

    def test_manifest_version_mismatch(self):
        self.manifest['version'] = '1.0.6'
        with self.assertRaisesRegex(ValueError, 'Tag and manifest'): self.check()

    def test_embedded_commit_mismatch(self):
        self.package(embedded=dict(self.manifest, source_commit='b'*40))
        with self.assertRaisesRegex(ValueError, 'Embedded build'): self.check()

    def test_archive_tampering(self):
        self.manifest['archive']['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'SHA-256'): self.check()

    def test_executable_mismatch(self):
        self.manifest['executable_sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'executable hash'): self.check()

    def source_delivery(self, corrupt=False, subset=False):
        source = self.root / 'dependency-sources.tar'
        archive = b'original vendor source archive'
        recipe = b'build with pinned inputs'
        entry = {'file': 'vendor.tar.gz', 'sha256': hashlib.sha256(archive).hexdigest()}
        if subset:
            entry = {'file': 'full-upstream.tar.gz', 'sha256': '0'*64, 'delivery': entry}
        lock = json.dumps({'archives': [entry]}).encode()
        with tarfile.open(source, 'w') as t:
            for name, data in [('scripts/dependencies/build.py', recipe),
                               ('scripts/dependencies/sources.lock.json', lock),
                               ('archives/vendor.tar.gz', b'wrong' if corrupt else archive)]:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
        self.manifest['dependency_sources'] = dict(name=source.name, bytes=source.stat().st_size,
            sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
            lock_sha256=hashlib.sha256(lock).hexdigest(), recipe_sha256=hashlib.sha256(recipe).hexdigest())
        return source

    def test_source_delivery_required_when_declared(self):
        self.source_delivery()
        with self.assertRaisesRegex(ValueError, 'source delivery is required'): self.check()

    def test_source_delivery_matches_locked_archives(self):
        source = self.source_delivery()
        self.assertEqual(module.verify(self.manifest['release_tag'], self.manifest,
                         self.archive, self.project, source)['result'], 'passed')

    def test_repacked_wrong_vendor_source_rejected(self):
        source = self.source_delivery(corrupt=True)
        with self.assertRaisesRegex(ValueError, 'source archive differs'):
            module.verify(self.manifest['release_tag'], self.manifest, self.archive, self.project, source)

    def test_source_subset_checked_against_delivery_hash(self):
        source = self.source_delivery(subset=True)
        self.assertEqual(module.verify(self.manifest['release_tag'], self.manifest,
                         self.archive, self.project, source)['result'], 'passed')


if __name__ == '__main__': unittest.main()
