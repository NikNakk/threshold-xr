import argparse
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BundleTests(unittest.TestCase):
    def sdk(self, root):
        root.mkdir()
        (root / 'header.h').write_text('fixture')
        runtime = {f'lib/wine/{arch}/ntdll.{ext}': 'a' * 64 for arch, ext in
                   [('i386-windows', 'dll'), ('x86_64-windows', 'dll'), ('x86_64-unix', 'so')]}
        data = {'schema': bridge.SCHEMA, 'architectures': ['i386', 'x86_64'], 'minimum_macos': '14.0',
                'runtime_files': runtime, 'files': bridge.inventory(root)}
        bridge.write_json(root / 'sdk.json', data)
        return data

    def test_modified_missing_and_extra_files_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'sdk'
            self.sdk(root)
            bridge.load_sdk(root)
            (root / 'extra.h').write_text('unexpected')
            with self.assertRaisesRegex(ValueError, 'inventory'):
                bridge.load_sdk(root)
            (root / 'extra.h').unlink()
            (root / 'header.h').write_text('modified')
            with self.assertRaisesRegex(ValueError, 'inventory'):
                bridge.load_sdk(root)
            (root / 'header.h').unlink()
            with self.assertRaisesRegex(ValueError, 'inventory'):
                bridge.load_sdk(root)

    def test_symlink_payload_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'sdk'
            self.sdk(root)
            (root / 'escape').symlink_to('/etc/passwd')
            with self.assertRaisesRegex(ValueError, 'Symlink'):
                bridge.load_sdk(root)

    def test_runtime_requires_all_three_exact_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = self.sdk(root / 'sdk')
            runtime = root / 'runtime'
            with self.assertRaisesRegex(ValueError, 'does not match'):
                bridge.verify_runtime(data, runtime)
            for name in data['runtime_files']:
                path = runtime / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'ntdll')
                data['runtime_files'][name] = bridge.sha(path)
            bridge.verify_runtime(data, runtime)
            (runtime / 'lib/wine/i386-windows/ntdll.dll').write_bytes(b'other version')
            with self.assertRaisesRegex(ValueError, 'i386-windows'):
                bridge.verify_runtime(data, runtime)

    def test_runtime_inventory_cannot_be_empty_or_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'sdk'
            data = self.sdk(root)
            for mapping in ({}, {'../escape': 'a' * 64}):
                data['runtime_files'] = mapping
                bridge.write_json(root / 'sdk.json', data)
                with self.assertRaises(ValueError):
                    bridge.load_sdk(root)

    def test_archive_roundtrip_and_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.sdk(root / 'sdk')
            # Ensure executable tool permissions survive the archive path.
            (root / 'sdk/header.h').chmod(0o755)
            bridge.archive_sdk(argparse.Namespace(sdk=root / 'sdk', output=root / 'sdk.tar.gz'))
            args = argparse.Namespace(archive=root / 'sdk.tar.gz', sha256='0' * 64, output=root / 'unpacked')
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                bridge.unpack_sdk(args)
            self.assertFalse(args.output.exists())
            args.sha256 = bridge.sha(args.archive)
            bridge.unpack_sdk(args)
            self.assertEqual(bridge.load_sdk(args.output), bridge.load_sdk(root / 'sdk'))
            self.assertTrue((args.output / 'header.h').stat().st_mode & 0o100)

    def test_sdk_archive_traversal_and_links_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, kind in [('wine-bridge-sdk/../../escape', tarfile.REGTYPE),
                               ('wine-bridge-sdk/link', tarfile.SYMTYPE)]:
                archive = root / 'bad.tar'
                with tarfile.open(archive, 'w') as stream:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    entry.linkname = '/etc/passwd'
                    stream.addfile(entry, io.BytesIO())
                with self.assertRaises(ValueError):
                    bridge.unpack_sdk(argparse.Namespace(archive=archive, sha256=bridge.sha(archive),
                                                          output=root / 'unpacked'))
            self.assertFalse((root / 'escape').exists())

    def test_upstream_only_extracts_selected_component(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'upstream.tar'
            with tarfile.open(archive, 'w') as stream:
                for name in ('proton/lsteamclient/file.h', 'proton/other/file.h'):
                    entry = tarfile.TarInfo(name)
                    entry.size = 4
                    stream.addfile(entry, io.BytesIO(b'test'))
            bridge.extract_upstream(archive, root / 'source')
            self.assertEqual([p.name for p in (root / 'source').iterdir()], ['file.h'])

    def test_upstream_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'upstream.tar'
            with tarfile.open(archive, 'w') as stream:
                entry = tarfile.TarInfo('proton/lsteamclient/../../escape')
                stream.addfile(entry)
            with self.assertRaises(ValueError):
                bridge.extract_upstream(archive, root / 'source')

    def test_dependency_check_handles_spaces_and_rejects_old_source_tree(self):
        with tempfile.TemporaryDirectory(prefix='with spaces ') as temporary:
            root = Path(temporary)
            work, sdk = root / 'work', root / 'sdk'
            (work / 'objects').mkdir(parents=True)
            header = sdk / 'include/file.h'
            depfile = work / 'objects/test.d'
            depfile.write_text('test.o: ' + str(header).replace(' ', '\\ ') + '\n')
            self.assertEqual(bridge.check_dependencies(work, sdk), ['sdk/include/file.h'])
            depfile.write_text('test.o: /original/wine/include/header.h\n')
            with self.assertRaisesRegex(ValueError, 'Unexpected non-system'):
                bridge.check_dependencies(work, sdk)

    def test_existing_destination_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'already exists'):
                bridge.fresh_destination(Path(temporary))

    def test_nested_work_and_output_directories_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                bridge.validate_destinations([root / 'sdk/work'], [root / 'sdk'])
            with self.assertRaises(ValueError):
                bridge.validate_destinations([root / 'work', root / 'work/result'], [])

    def test_staging_clones_runtime_preserves_inputs_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdkroot, runtime, built = root / 'sdk', root / 'runtime', root / 'built'
            sdk = self.sdk(sdkroot)
            for name in sdk['runtime_files']:
                path = runtime / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'ntdll')
                sdk['runtime_files'][name] = bridge.sha(path)
            bridge.write_json(sdkroot / 'sdk.json', sdk)
            for name in ('x86_64-windows/lsteamclient.dll', 'i386-windows/lsteamclient.dll',
                         'lsteamclient.so', 'mwxr-steam.exe', 'licenses/lsteamclient-LICENSE',
                         'licenses/launcher-COPYING.LIB'):
                path = built / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            bridge.write_json(built / 'build.json', {
                'schema': 'threshold-xr/local-steam-bridge-1',
                'sdk_sha256': bridge.sha(sdkroot / 'sdk.json'), 'runtime_files': sdk['runtime_files'],
                'files': {p.relative_to(built).as_posix(): bridge.sha(p) for p in built.rglob('*') if p.is_file()},
            })
            args = argparse.Namespace(sdk=sdkroot, runtime=runtime, bridge=built, output=root / 'result')
            bridge.stage_runtime(args)
            self.assertFalse((runtime / 'lib/wine/x86_64-unix/lsteamclient.so').exists())
            self.assertTrue((args.output / 'lib/wine/i386-windows/lsteamclient.dll').is_file())
            self.assertTrue((args.output / 'share/threshold-steam-bridge/licenses/lsteamclient-LICENSE').is_file())
            (built / 'lsteamclient.so').write_bytes(b'modified')
            args.output = root / 'result2'
            with self.assertRaisesRegex(ValueError, 'inventory mismatch'):
                bridge.stage_runtime(args)
            self.assertFalse(args.output.exists())

    def test_overlay_cannot_write_through_runtime_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / 'runtime'
            runtime.mkdir()
            (runtime / 'lib').symlink_to(root / 'outside')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                bridge.overlay_file(root / 'source', runtime, 'lib/file')


if __name__ == '__main__':
    unittest.main()
