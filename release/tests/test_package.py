import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package', Path(__file__).parents[1] / 'package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def build_shared(self, path, symbol, dependency=None):
        source = path.with_suffix('.c')
        source.write_text(f'int {symbol}(void) {{ return 1; }}' if dependency is None else
                          f'extern int shared(void); int {symbol}(void) {{ return shared(); }}')
        subprocess.run(['clang', '-dynamiclib', '-o', str(path), str(source),
                        '-install_name', str(path), *([str(dependency)] if dependency else [])],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    @unittest.skipUnless(sys.platform == 'darwin', 'Mach-O relocation requires macOS')
    def test_shared_dependency_is_reused_after_its_copy_is_relocated(self):
        with tempfile.TemporaryDirectory(prefix='relocation with spaces ') as temporary:
            root = Path(temporary).resolve()
            prefix, external = root / 'prefix', root / 'external'
            prefix.mkdir()
            external.mkdir()
            shared = external / 'libshared.dylib'
            self.build_shared(shared, 'shared')
            self.build_shared(prefix / 'liba.dylib', 'a', shared)
            self.build_shared(prefix / 'libb.dylib', 'b', shared)
            package.relocate(prefix)
            copy = prefix / 'lib/libshared.dylib'
            self.assertTrue(copy.is_file())
            self.assertNotEqual(package.digest(copy), package.digest(shared))
            for name in ('liba.dylib', 'libb.dylib'):
                dependencies = subprocess.check_output(['otool', '-L', str(prefix / name)], text=True)
                self.assertIn('@loader_path/lib/libshared.dylib', dependencies)
                self.assertNotIn(str(external), dependencies)

    @unittest.skipUnless(sys.platform == 'darwin', 'Mach-O relocation requires macOS')
    def test_distinct_dependencies_with_the_same_name_still_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            prefix = root / 'prefix'
            prefix.mkdir()
            for number, symbol in ((1, 'a'), (2, 'b')):
                external = root / str(number)
                external.mkdir()
                shared = external / 'libshared.dylib'
                self.build_shared(shared, 'shared')
                self.build_shared(prefix / f'lib{symbol}.dylib', symbol, shared)
            with self.assertRaisesRegex(ValueError, 'Dylib name collision'):
                package.relocate(prefix)
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
