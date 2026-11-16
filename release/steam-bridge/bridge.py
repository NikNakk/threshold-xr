#!/usr/bin/env python3
# Copyright 2026 Nick Kennedy
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Export a Wine development bundle and compile the Steam bridge outside Wine."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
PIN = json.loads((HERE / 'inputs.json').read_text())
LIBRARIES = ('user32', 'ws2_32', 'winecrt0', 'ucrtbase', 'kernel32', 'ntdll')
TARGETS = {'x86_64': 'x86_64-w64-mingw32', 'i386': 'i686-w64-mingw32'}
SCHEMA = 'threshold-xr/wine-bridge-sdk-1'


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def output(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def macos_version(value):
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', value):
        raise ValueError(f'Invalid macOS version: {value}')
    parts = [int(x) for x in value.split('.')]
    return tuple((parts + [0, 0, 0])[:3])


def macho_minimum(path):
    text = output('otool', '-l', path)
    match = re.search(r'\bminos ([0-9.]+)', text) or re.search(
        r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', text)
    if not match:
        raise ValueError(f'Cannot determine deployment target: {path}')
    return match.group(1)


def relative(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or '..' in path.parts or str(path) != value or '\\' in value:
        raise ValueError(f'Unsafe relative path: {value}')
    return Path(*path.parts)


def inventory(root):
    result = {}
    for p in sorted(root.rglob('*')):
        if p.is_symlink():
            raise ValueError(f'Symlink in bundle: {p}')
        if p.is_file() and p != root / 'sdk.json':
            result[p.relative_to(root).as_posix()] = sha(p)
        elif not p.is_dir() and p != root / 'sdk.json':
            raise ValueError(f'Unsupported bundle entry: {p}')
    return result


def load_sdk(root):
    if root.is_symlink():
        raise ValueError('SDK root must not be a symlink')
    data = json.loads((root / 'sdk.json').read_text())
    if data.get('schema') != SCHEMA or data.get('architectures') != ['i386', 'x86_64']:
        raise ValueError('Expected a dual-architecture Wine bridge SDK v1')
    for name in data['files']:
        relative(name)
    for name, digest in data['runtime_files'].items():
        if name not in ('lib/wine/i386-windows/ntdll.dll', 'lib/wine/x86_64-windows/ntdll.dll',
                        'lib/wine/x86_64-unix/ntdll.so') or not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Invalid SDK runtime inventory')
    if len(data['runtime_files']) != 3:
        raise ValueError('Incomplete SDK runtime inventory')
    macos_version(data['minimum_macos'])
    if inventory(root) != data['files']:
        raise ValueError('SDK inventory mismatch: missing, modified or unexpected files')
    return data


def archive_sdk(args):
    load_sdk(args.sdk)
    validate_destinations([args.output], [args.sdk])
    fresh_destination(args.output)
    with tarfile.open(args.output, 'w:gz') as stream:
        stream.add(args.sdk, arcname='wine-bridge-sdk', recursive=True)
    args.output.with_name(args.output.name + '.sha256').write_text(sha(args.output) + '\n')
    print(f'{args.output}: {sha(args.output)}')


def unpack_sdk(args):
    if not re.fullmatch('[0-9a-f]{64}', args.sha256) or sha(args.archive) != args.sha256:
        raise ValueError('SDK archive SHA-256 mismatch')
    fresh_destination(args.output)
    with tempfile.TemporaryDirectory(prefix='unpack-sdk-', dir=args.output.parent) as scratch:
        root = Path(scratch)
        with tarfile.open(args.archive) as stream:
            for entry in stream:
                p = relative(entry.name)
                if p.parts[0] != 'wine-bridge-sdk':
                    raise ValueError('Unexpected SDK archive root')
                target = root / p
                if entry.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif entry.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if target.exists():
                        raise ValueError('Duplicate SDK archive entry')
                    with stream.extractfile(entry) as src, target.open('wb') as dest:
                        shutil.copyfileobj(src, dest)
                    target.chmod(entry.mode & 0o755)
                else:
                    raise ValueError('SDK archive contains a link or unsupported entry')
        load_sdk(root / 'wine-bridge-sdk')
        shutil.move(str(root / 'wine-bridge-sdk'), args.output)
    print(f'Extracted verified SDK to {args.output}')


def copy_file(source, destination):
    if not source.is_file():
        raise ValueError(f'Missing prerequisite: {source}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def overlay_file(source, root, name):
    destination = root / relative(name)
    if destination.is_symlink() or not destination.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'Runtime overlay would follow a symlink: {name}')
    copy_file(source, destination)


def fresh_destination(path):
    if path.exists() or path.is_symlink():
        raise ValueError(f'Destination already exists; choose a new directory: {path}')
    path.parent.mkdir(parents=True, exist_ok=True)


def export_sdk(args):
    source, build, runtime = args.wine_source.resolve(), args.wine_build.resolve(), args.runtime.resolve()
    args.output = args.output.absolute()
    validate_destinations([args.output], [source, build, runtime])
    fresh_destination(args.output)
    revision = output('git', '-C', source, 'rev-parse', 'HEAD')
    dirty = output('git', '-C', source, 'status', '--porcelain', '--untracked-files=no')
    if dirty:
        raise ValueError('Wine tracked sources are modified; commit them before exporting an SDK')
    if output('git', '-C', source, 'ls-files', 'dlls/lsteamclient'):
        raise ValueError('Wine source contains tracked lsteamclient; use the Wine-only source tree')
    loader = (source / 'dlls/ntdll/loader.c').read_text()
    if 'MWXR_LSTEAMCLIENT' not in loader:
        raise ValueError('Wine source lacks the opt-in Steam redirect')
    makefile = (build / 'Makefile').read_text()
    if 'i386-windows/ntdll.dll' not in makefile:
        raise ValueError('Wine build must support i386 and x86_64')
    # Require the configured build to refer to the selected source, not another checkout.
    if f'srcdir = {source}\n' not in makefile:
        raise ValueError('Wine build does not reference the supplied Wine source')
    with tempfile.TemporaryDirectory(prefix='wine-sdk-', dir=args.output.parent) as scratch:
        root = Path(scratch) / 'sdk'
        root.mkdir()
        for base, dest in ((source / 'include', 'include/source'), (build / 'include', 'include/generated')):
            for p in sorted(base.rglob('*')):
                if p.is_file() and (dest == 'include/source' or p.suffix in ('.h', '.rh', '.inl')):
                    copy_file(p, root / dest / p.relative_to(base))
        for tool in ('winebuild', 'winegcc'):
            copy_file(build / f'tools/{tool}/{tool}', root / f'tools/{tool}/{tool}')
        expected = {}
        for arch in TARGETS:
            for library in LIBRARIES:
                name = f'dlls/{library}/{arch}-windows/lib{library}.a'
                copy_file(build / name, root / name)
            name = f'lib/wine/{arch}-windows/ntdll.dll'
            pe = runtime / name
            binary = pe.read_bytes()
            marker = 'MWXR_LSTEAMCLIENT' if arch == 'x86_64' else 'steamclient'
            if marker.encode('utf-16-le') not in binary:
                raise ValueError(f'Runtime lacks {arch} Steam redirect: {pe}')
            expected[name] = sha(pe)
        name = 'lib/wine/x86_64-unix/ntdll.so'
        expected[name] = sha(runtime / name)
        copy_file(runtime / name, root / 'link/ntdll.so')
        # A source archive is included, rather than relying only on a repository URL.
        archive = root / 'sources/wine.tar.gz'
        archive.parent.mkdir()
        subprocess.run(['git', '-C', str(source), 'archive', '--format=tar.gz',
                        '-o', str(archive), revision], check=True)
        for name in ('COPYING.LIB', 'LICENSE', 'AUTHORS'):
            copy_file(source / name, root / 'licenses' / name)
        configuration = output(build / 'config.status', '--config')
        for path, name in ((source, '${WINE_SOURCE}'), (build, '${WINE_BUILD}'), (runtime, '${RUNTIME}')):
            configuration = configuration.replace(str(path), name)
        (root / 'provenance').mkdir()
        (root / 'provenance/configure.txt').write_text(configuration + '\n')
        write_json(root / 'sdk.json', {
            'schema': SCHEMA, 'version': args.version, 'architectures': ['i386', 'x86_64'],
            'wine_revision': revision, 'wine_repository': 'https://github.com/NikNakk/wine-crossover',
            'runtime_files': expected, 'producer_host': platform.platform(),
            'minimum_macos': max((macho_minimum(root / p) for p in
                                  ('link/ntdll.so', 'tools/winegcc/winegcc', 'tools/winebuild/winebuild')),
                                 key=macos_version),
            'files': inventory(root),
        })
        load_sdk(root)
        shutil.move(str(root), args.output)
    print(f'Exported {args.output} ({len(load_sdk(args.output)["files"])} files)', flush=True)


def verify_runtime(sdk, runtime):
    for name, expected in sdk['runtime_files'].items():
        p = runtime / relative(name)
        if not p.is_file() or sha(p) != expected:
            raise ValueError(f'Runtime does not match SDK: {name}')


def doctor(sdk_path, sdk):
    if sys.platform != 'darwin':
        raise ValueError('The local bridge build requires macOS')
    if macos_version(platform.mac_ver()[0]) < macos_version(sdk['minimum_macos']):
        raise ValueError(f'This development bundle requires macOS {sdk["minimum_macos"]} or newer')
    required = ('clang++', 'xcrun', 'patch', 'curl', 'codesign',
                'x86_64-w64-mingw32-gcc', 'i686-w64-mingw32-gcc')
    missing = [x for x in required if not shutil.which(x)]
    if missing:
        raise ValueError('Missing tools: ' + ', '.join(missing) +
                         '. Install Apple Command Line Tools and MinGW-w64 (brew install mingw-w64).')
    sdkroot = Path(os.environ.get('SDKROOT') or output('xcrun', '--sdk', 'macosx', '--show-sdk-path'))
    if not (sdkroot / 'usr/include').is_dir():
        raise ValueError(f'Invalid macOS SDK: {sdkroot}')
    for tool in ('winegcc', 'winebuild'):
        # This also checks Rosetta availability for the supplied x86_64 tools.
        subprocess.run([str(sdk_path / f'tools/{tool}/{tool}'), '--version'],
                       check=True, stdout=subprocess.DEVNULL)
    versions = {x: output(x, '--version').splitlines()[0] for x in
                ('clang++', 'x86_64-w64-mingw32-gcc', 'i686-w64-mingw32-gcc')}
    print(f'Toolchain ready; Wine {sdk["wine_revision"][:12]}; macOS SDK {sdkroot}', flush=True)
    return sdkroot, versions


def upstream_digest(root):
    # Matches the original build script's sorted shasum output, including ./ prefixes.
    lines = []
    for p in sorted(root.rglob('*')):
        if p.is_symlink():
            raise ValueError('Symlink in upstream source')
        if p.is_file():
            lines.append(f'{sha(p)}  ./{p.relative_to(root).as_posix()}\n')
    return hashlib.sha256(''.join(lines).encode()).hexdigest()


def extract_upstream(archive, destination):
    with tarfile.open(archive) as stream:
        for entry in stream:
            # GitHub tarballs have a single root followed by lsteamclient/.
            path = PurePosixPath(entry.name)
            if len(path.parts) < 3 or path.parts[1] != 'lsteamclient':
                continue
            name = '/'.join(path.parts[2:])
            target = destination / relative(name)
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    raise ValueError(f'Duplicate upstream entry: {name}')
                with stream.extractfile(entry) as src, target.open('wb') as out:
                    shutil.copyfileobj(src, out)
            else:
                raise ValueError(f'Unsupported upstream archive entry: {entry.name}')


def run_logged(command, log, env, cwd=None):
    with log.open('w') as stream:
        stream.write(shlex.join([str(x) for x in command]) + '\n')
        stream.flush()
        result = subprocess.run([str(x) for x in command], stdout=stream,
                                stderr=subprocess.STDOUT, env=env, cwd=cwd)
    if result.returncode:
        tail = '\n'.join(log.read_text(errors='replace').splitlines()[-20:])
        raise RuntimeError(f'Build failed; see {log}\n{tail}')


def compile_stage(commands, jobs, logs, env, label):
    print(f'{label}: compiling {len(commands)} files with {jobs} jobs', flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run_logged, cmd, logs / f'{label}-{i:03}.log', env)
                   for i, cmd in enumerate(commands)]
        try:
            for count, future in enumerate(concurrent.futures.as_completed(futures), 1):
                future.result()
                if count % 25 == 0 or count == len(futures):
                    print(f'{label}: {count}/{len(futures)}', flush=True)
        except BaseException:
            for future in futures:
                future.cancel()
            raise


def check_dependencies(work, sdkroot, apple_sdk=None):
    """Compiler depfiles prove Wine/bridge headers came from the isolated inputs."""
    work, sdkroot = work.resolve(), sdkroot.resolve()
    dependencies = set()
    for depfile in (work / 'objects').rglob('*.d'):
        text = depfile.read_text().replace('\\\n', ' ')
        for name in shlex.split(text.split(':', 1)[1]):
            path = Path(name).resolve()
            if path.is_relative_to(work):
                dependencies.add('work/' + path.relative_to(work).as_posix())
            elif path.is_relative_to(sdkroot):
                dependencies.add('sdk/' + path.relative_to(sdkroot).as_posix())
            elif apple_sdk and path.is_relative_to(apple_sdk.resolve()):
                dependencies.add('apple-sdk/' + path.relative_to(apple_sdk.resolve()).as_posix())
            else:
                raise ValueError(f'Unexpected non-system source dependency: {path}')
    return sorted(dependencies)


def verify_pe(path, machine):
    data = path.read_bytes()
    offset = int.from_bytes(data[60:64], 'little')
    if data[:2] != b'MZ' or data[offset:offset + 4] != b'PE\0\0' or \
            int.from_bytes(data[offset + 4:offset + 6], 'little') != machine:
        raise ValueError(f'Unexpected PE architecture: {path}')


def build_bridge(args):
    sdkroot = args.sdk.resolve()
    sdk = load_sdk(sdkroot)
    verify_runtime(sdk, args.runtime.resolve())
    apple_sdk, versions = doctor(sdkroot, sdk)
    validate_destinations([args.work, args.output], [sdkroot, args.runtime])
    fresh_destination(args.output)
    fresh_destination(args.work)
    for key, name in (('patch_sha256', '0001-macos-host-steamclient.patch'),
                      ('launcher_sha256', 'steam_stand_in.c')):
        if sha(HERE / 'inputs' / name) != PIN[key]:
            raise ValueError(f'Build input hash mismatch: {name}')
    args.work.mkdir()
    work = args.work.resolve()
    src, logs, result = work / 'source', work / 'logs', work / 'result'
    src.mkdir()
    logs.mkdir()
    result.mkdir()
    if args.source_tree:
        if upstream_digest(args.source_tree) != PIN['tree_sha256']:
            raise ValueError('Supplied pristine Proton source does not match pin')
        shutil.copytree(args.source_tree, src, dirs_exist_ok=True)
    else:
        archive = args.source_archive or work / 'proton.tar.gz'
        if not args.source_archive:
            subprocess.run(['curl', '--fail', '--location', '--retry', '3',
                            f'https://codeload.github.com/ValveSoftware/Proton/tar.gz/{PIN["proton_revision"]}',
                            '-o', str(archive)], check=True)
        extract_upstream(archive, src)
        if upstream_digest(src) != PIN['tree_sha256']:
            raise ValueError('Downloaded Proton source does not match pin')
    env = os.environ.copy()
    # Avoid accidental use of another checkout's headers, libraries or Wine tool overrides.
    for name in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH',
                 'WINEBUILD', 'WINELOADER', 'WINESERVER', 'DYLD_LIBRARY_PATH'):
        env.pop(name, None)
    env['SDKROOT'] = str(apple_sdk)
    env['MACOSX_DEPLOYMENT_TARGET'] = sdk['minimum_macos']
    run_logged(['patch', '--batch', '--fuzz=0', '-p1', '-d', src, '-i',
                HERE / 'inputs/0001-macos-host-steamclient.patch'], logs / 'patch.log', env)
    includes = ['-I' + str(src), '-I' + str(sdkroot / 'include/generated'),
                '-I' + str(sdkroot / 'include/source')]
    definitions = ['-D__WINESRC__', '-DSTEAM_API_EXPORTS', '-Dprivate=public', '-Dprotected=public']
    for arch, target in TARGETS.items():
        obj = work / f'objects/{arch}'
        obj.mkdir(parents=True)
        common = [target + '-gcc', '-c', *includes, '-I' + str(sdkroot / 'include/source/msvcrt'),
                  '-D_UCRT', *definitions, '-D__WINE_PE_BUILD', '-fno-strict-aliasing',
                  '-ffunction-sections', '-g', '-gdwarf-4', '-O2', '-fno-omit-frame-pointer']
        common += ['-mcx16', '-mcmodel=small'] if arch == 'x86_64' else ['-mpreferred-stack-boundary=2']
        sources = sorted(src.glob('*.c'))
        compile_stage([common + ['-MMD', '-MF', obj / (p.stem + '.d'), '-o', obj / (p.stem + '.o'), p] for p in sources],
                      args.jobs, logs, env, arch)
        dest = result / f'{arch}-windows'
        dest.mkdir()
        libs = [sdkroot / f'dlls/{lib}/{arch}-windows/lib{lib}.a' for lib in LIBRARIES]
        run_logged([sdkroot / 'tools/winegcc/winegcc', '-o', dest / 'lsteamclient.dll',
                    '--wine-objdir', sdkroot, '-b', target, '-Wl,--wine-builtin', '-shared',
                    src / 'lsteamclient.spec', *sorted(obj.glob('*.o')), *libs,
                    *(['-Wl,--disable-stdcall-fixup'] if arch == 'i386' else [])],
                   logs / f'link-{arch}.log', env, cwd=work)
    obj = work / 'objects/unix'
    obj.mkdir()
    common = ['clang++', '-arch', 'x86_64', '-m64', '-std=c++17', '-c', *includes,
              *definitions, '-DWINE_UNIX_LIB', '-pipe', '-fcf-protection=none',
              '-fvisibility=hidden', '-fno-stack-protector', '-fno-strict-aliasing',
              '-gdwarf-4', '-fPIC', '-fasynchronous-unwind-tables', '-g', '-O2',
              '-U_FORTIFY_SOURCE', '-D_FORTIFY_SOURCE=0', '-Wno-deprecated-declarations']
    compile_stage([common + ['-MMD', '-MF', obj / (p.stem + '.d'), '-o', obj / (p.stem + '.o'), p]
                   for p in sorted(src.glob('*.cpp'))],
                  args.jobs, logs, env, 'unix')
    run_logged(['clang++', '-arch', 'x86_64', '-m64', '-o', result / 'lsteamclient.so',
                '-dynamiclib', '-install_name', '@rpath/lsteamclient.so', '-Wl,-rpath,@loader_path/',
                *sorted(obj.glob('*.o')), sdkroot / 'link/ntdll.so'], logs / 'link-unix.log', env)
    run_logged(['x86_64-w64-mingw32-gcc', '-municode', '-O2', '-Wall', '-o',
                result / 'mwxr-steam.exe', HERE / 'inputs/steam_stand_in.c'], logs / 'launcher.log', env)
    run_logged(['codesign', '--force', '--sign', '-', result / 'lsteamclient.so'],
               logs / 'codesign.log', env)
    verify_pe(result / 'i386-windows/lsteamclient.dll', 0x14c)
    verify_pe(result / 'x86_64-windows/lsteamclient.dll', 0x8664)
    verify_pe(result / 'mwxr-steam.exe', 0x8664)
    dependencies = check_dependencies(work, sdkroot, apple_sdk)
    write_json(logs / 'source-dependencies.json', dependencies)
    # Preserve the old builder's flat Win64 layout as well as explicit architectures.
    copy_file(result / 'x86_64-windows/lsteamclient.dll', result / 'lsteamclient.dll')
    copy_file(src / 'LICENSE', result / 'licenses/lsteamclient-LICENSE')
    copy_file(HERE / 'inputs/COPYING.LIB', result / 'licenses/launcher-COPYING.LIB')
    write_json(result / 'build.json', {
        'schema': 'threshold-xr/local-steam-bridge-1', 'sdk_sha256': sha(sdkroot / 'sdk.json'),
        'wine_revision': sdk['wine_revision'], 'runtime_files': sdk['runtime_files'],
        'inputs': PIN, 'toolchain': versions, 'macos_sdk': str(apple_sdk),
        'minimum_macos': sdk['minimum_macos'],
        'source_dependency_count': len(dependencies),
        'files': {p.relative_to(result).as_posix(): sha(p) for p in result.rglob('*') if p.is_file()},
    })
    shutil.copytree(result, args.output)
    print(f'Local bridge built in {args.output}; runtime and prefixes were not modified.', flush=True)


def validate_destinations(destinations, inputs):
    resolved = [p.resolve() for p in destinations]
    for i, path in enumerate(resolved):
        for other in resolved[i + 1:] + [p.resolve() for p in inputs]:
            if path.is_relative_to(other) or other.is_relative_to(path):
                raise ValueError(f'Input and output directories must be separate: {path}, {other}')


def stage_runtime(args):
    sdkroot = args.sdk.resolve()
    sdk = load_sdk(sdkroot)
    verify_runtime(sdk, args.runtime.resolve())
    info = json.loads((args.bridge / 'build.json').read_text())
    if info.get('schema') != 'threshold-xr/local-steam-bridge-1' or \
            info.get('sdk_sha256') != sha(sdkroot / 'sdk.json') or info.get('runtime_files') != sdk['runtime_files']:
        raise ValueError('Bridge was not built for this SDK/runtime')
    required = ['x86_64-windows/lsteamclient.dll', 'i386-windows/lsteamclient.dll',
                'lsteamclient.so', 'mwxr-steam.exe', 'licenses/lsteamclient-LICENSE',
                'licenses/launcher-COPYING.LIB']
    for name in required:
        p = args.bridge / name
        if not p.is_file() or sha(p) != info['files'].get(name):
            raise ValueError(f'Bridge inventory mismatch: {name}')
    validate_destinations([args.output], [sdkroot, args.runtime, args.bridge])
    fresh_destination(args.output)
    # APFS clone avoids copying an entire Wine runtime when supported.
    with tempfile.TemporaryDirectory(prefix='bridge-runtime-', dir=args.output.parent) as scratch:
        root = Path(scratch) / 'runtime'
        cloned = False
        if sys.platform == 'darwin':
            cloned = subprocess.run(['cp', '-cR', str(args.runtime.resolve()), str(root)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not cloned:
            if root.exists():
                shutil.rmtree(root)
            shutil.copytree(args.runtime, root, symlinks=True)
        for arch in TARGETS:
            overlay_file(args.bridge / f'{arch}-windows/lsteamclient.dll', root,
                         f'lib/wine/{arch}-windows/lsteamclient.dll')
        overlay_file(args.bridge / 'lsteamclient.so', root, 'lib/wine/x86_64-unix/lsteamclient.so')
        overlay_file(args.bridge / 'mwxr-steam.exe', root, 'bin/mwxr-steam.exe')
        for name in ('licenses/lsteamclient-LICENSE', 'licenses/launcher-COPYING.LIB', 'build.json'):
            overlay_file(args.bridge / name, root, 'share/threshold-steam-bridge/' + name)
        verify_runtime(sdk, root)
        shutil.move(str(root), args.output)
    print(f'Staged local runtime in {args.output}; source runtime and game prefixes were not modified.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export-sdk', help='Maintainer: export a matching Wine-only development bundle')
    for name in ('wine-source', 'wine-build', 'runtime', 'output'):
        export.add_argument('--' + name, type=Path, required=True)
    export.add_argument('--version', required=True)
    archive = commands.add_parser('archive-sdk')
    archive.add_argument('--sdk', type=Path, required=True)
    archive.add_argument('--output', type=Path, required=True)
    unpack = commands.add_parser('unpack-sdk')
    unpack.add_argument('--archive', type=Path, required=True)
    unpack.add_argument('--sha256', required=True)
    unpack.add_argument('--output', type=Path, required=True)
    for name in ('doctor', 'verify-runtime', 'build', 'stage-runtime'):
        p = commands.add_parser(name)
        p.add_argument('--sdk', type=Path, required=True)
        if name != 'doctor':
            p.add_argument('--runtime', type=Path, required=True)
        if name == 'build':
            p.add_argument('--work', type=Path, required=True)
            p.add_argument('--output', type=Path, required=True)
            offline = p.add_mutually_exclusive_group()
            offline.add_argument('--source-tree', type=Path, help='Optional offline pristine pinned lsteamclient source')
            offline.add_argument('--source-archive', type=Path, help='Optional offline pinned Proton tarball')
            p.add_argument('--jobs', type=int, default=min(os.cpu_count() or 2, 6))
        elif name == 'stage-runtime':
            p.add_argument('--bridge', type=Path, required=True)
            p.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'export-sdk':
            export_sdk(args)
        elif args.command == 'archive-sdk':
            archive_sdk(args)
        elif args.command == 'unpack-sdk':
            unpack_sdk(args)
        elif args.command == 'stage-runtime':
            stage_runtime(args)
        elif args.command == 'build':
            if not 1 <= args.jobs <= 64:
                raise ValueError('--jobs must be between 1 and 64')
            build_bridge(args)
        else:
            sdk = load_sdk(args.sdk)
            if args.command == 'doctor':
                doctor(args.sdk.resolve(), sdk)
            else:
                verify_runtime(sdk, args.runtime.resolve())
                print('Runtime matches SDK')
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
