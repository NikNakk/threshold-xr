import importlib.util
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package', Path(__file__).parents[1] / 'package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_archive_and_manifest_hash_actual_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / 'prefix'
            prefix.mkdir()
            (prefix / 'openvr_api.dll').write_bytes(b'fixture')
            output = root / 'output'
            artifact = package.package('xrizer', 'test', 'windows-x86_64', 'openvr-runtime', prefix, output)
            with tarfile.open(output / artifact['name']) as archive:
                self.assertEqual(archive.getnames(), ['xrizer', 'xrizer/openvr_api.dll'])
            self.assertEqual(artifact['sha256'], package.digest(output / artifact['name']))
            with self.assertRaisesRegex(ValueError, 'Incomplete'):
                package.manifest('xrizer', 'test', 'a' * 40,
                                 'https://github.com/NikNakk/xrizer/actions/runs/1',
                                 [output / 'windows-x86_64.json'], output)

    def test_safe_links_preserved_and_escaping_links_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / 'prefix'
            prefix.mkdir()
            (prefix / 'file.dll').write_bytes(b'fixture')
            (prefix / 'link.dll').symlink_to('file.dll')
            package.validate_tree(prefix)
            (prefix / 'escape.dll').symlink_to('../outside')
            with self.assertRaises(ValueError):
                package.validate_tree(prefix)

    def test_absolute_manifest_paths_are_rewritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'lib').mkdir()
            (root / 'lib/driver.dylib').write_bytes(b'fixture')
            path = root / 'icd.json'
            path.write_text(json.dumps({'ICD': {'library_path': '/build/driver.dylib'}}))
            package.relative_manifests(root)
            self.assertEqual(json.loads(path.read_text())['ICD']['library_path'], 'lib/driver.dylib')

    def test_external_manifest_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'icd.json').write_text('{"ICD":{"library_path":"../../outside.dylib"}}')
            with self.assertRaises(ValueError):
                package.relative_manifests(root)

    def test_public_archive_excludes_unreviewed_steam_bridge(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            (prefix / 'lsteamclient.dll').write_bytes(b'fixture')
            with self.assertRaisesRegex(ValueError, 'Excluded'):
                package.public_distribution_check(prefix)

    def test_public_archive_excludes_sdk_source_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            (prefix / 'steamworks_sdk_147').mkdir()
            (prefix / 'steamworks_sdk_147/header.h').write_text('fixture')
            with self.assertRaisesRegex(ValueError, 'Excluded'):
                package.public_distribution_check(prefix)

    def test_our_steam_stand_in_is_not_confused_with_valves_client(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            (prefix / 'mwxr-steam.exe').write_bytes(b'fixture')
            package.public_distribution_check(prefix)

    def test_version_cannot_escape_output(self):
        with self.assertRaises(ValueError):
            package.package('xrizer', '../escape', 'windows-x86_64', 'runtime', '.', '/tmp')


if __name__ == '__main__':
    unittest.main()
