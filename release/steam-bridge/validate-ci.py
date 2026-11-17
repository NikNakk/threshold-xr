#!/usr/bin/env python3
"""Maintainer: validate a completed CI runtime/SDK pair and compile locally."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def extract_runtime(archive, destination, work):
    # Reuse the app's guarded extractor, including its path, symlink and size checks.
    source = HERE.parents[1] / 'Sources/CThresholdArchive'
    helper = work / 'extract-runtime.c'
    helper.write_text('''#include <stdio.h>
#include "CThresholdArchive.h"
int main(int argc, char **argv) {
    char error[1024] = {0};
    if (argc != 3) return 2;
    int result = threshold_extract(argv[1], argv[2], error, sizeof(error));
    if (result) fprintf(stderr, "%s\\n", error);
    return result ? 1 : 0;
}
''')
    subprocess.run(['clang', '-I' + str(source / 'include'), '-I' + str(source),
                    str(helper), str(source / 'extract.c'), '-larchive', '-o', str(work / 'extract-runtime')], check=True)
    destination.mkdir()
    subprocess.run([str(work / 'extract-runtime'), str(archive), str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, type=int)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--proton-archive', type=Path)
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{40}', args.commit) or args.work.exists():
        parser.error('Supply an exact commit and a new working directory')
    root = args.work.resolve()
    root.mkdir(parents=True)
    repository = 'NikNakk/threshold-xr'
    def run(*command, **options):
        print('Running:', ' '.join(map(str, command)), flush=True)
        return subprocess.run([str(p) for p in command], check=True, **options)
    def cli(*command):
        run(sys.executable, HERE / 'bridge.py', *command)
    try:
        metadata = json.loads(subprocess.check_output([
            'gh', 'run', 'view', str(args.run), '--repo', repository,
            '--json', 'headSha,workflowName,headBranch'], text=True))
        if metadata['headSha'] != args.commit or metadata['workflowName'] != 'Prototype Wine bridge development bundle':
            raise ValueError('CI run does not match the expected source/workflow')
        run('gh', 'run', 'watch', args.run, '--repo', repository, '--exit-status', '--interval', 30)
        artifacts = root / 'artifacts'
        run('gh', 'run', 'download', args.run, '--repo', repository,
            '--name', 'wine-bridge-sdk-prototype', '--dir', artifacts)
        info = json.loads((artifacts / 'macos-x86_64.json').read_text())
        name = info['name']
        if Path(name).name != name or not re.fullmatch(r'wine-[A-Za-z0-9._-]+-macos-x86_64\.tar\.xz', name):
            raise ValueError('Unexpected runtime artifact name')
        archive = artifacts / name
        if archive.stat().st_size != info['size'] or digest(archive) != info['sha256']:
            raise ValueError('Runtime archive identity mismatch')
        bundles = list(artifacts.glob('wine-bridge-sdk-*.tar.gz'))
        if len(bundles) != 1:
            raise ValueError('Expected one development bundle')
        bundle = bundles[0]
        expected = bundle.with_name(bundle.name + '.sha256').read_text().strip()
        cli('unpack-sdk', '--archive', bundle, '--sha256', expected, '--output', root / 'sdk')
        extract_runtime(archive, root / 'runtime', root)
        cli('doctor', '--sdk', root / 'sdk')
        cli('verify-runtime', '--sdk', root / 'sdk', '--runtime', root / 'runtime')
        offline = ['--source-archive', args.proton_archive.resolve()] if args.proton_archive else []
        cli('build', '--sdk', root / 'sdk', '--runtime', root / 'runtime',
            '--work', root / 'build', '--output', root / 'bridge', *offline)
        cli('stage-runtime', '--sdk', root / 'sdk', '--runtime', root / 'runtime',
            '--bridge', root / 'bridge', '--output', root / 'staged-runtime')
        environment = os.environ.copy()
        for key in ('WINEDLLPATH', 'WINELOADER', 'WINESERVER', 'DYLD_LIBRARY_PATH'):
            environment.pop(key, None)
        environment['WINEPREFIX'] = str(root / 'version-check-prefix')
        version = subprocess.check_output([str(root / 'runtime/bin/wine'), '--version'], env=environment, text=True).strip()
        report = {'run': args.run, 'commit': args.commit, 'workflow': metadata,
                  'runtime_archive': info, 'sdk_archive_sha256': expected, 'wine_version': version,
                  'build': json.loads((root / 'bridge/build.json').read_text()), 'passed': True}
        (root / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
        print('CI runtime/SDK pair and local bridge build passed:', root / 'validation.json', flush=True)
    except Exception as error:
        (root / 'failure.json').write_text(json.dumps({'run': args.run, 'error': str(error)}, indent=2) + '\n')
        raise


if __name__ == '__main__':
    main()
