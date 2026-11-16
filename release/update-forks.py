#!/usr/bin/env python3
"""Fast-forward only the recorded review branches, refusing concurrent remote edits."""
import argparse
import json
from pathlib import Path
import subprocess
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--component', action='append', required=True)
parser.add_argument('--publish', action='store_true')
parser.add_argument('--source', type=Path, default=Path('build/release-forks'))
args = parser.parse_args()
path = Path(__file__).resolve().parent / 'rollout.json'
records = json.loads(path.read_text())


def api(endpoint, payload=None, method=None):
    command = ['gh', 'api', endpoint]
    if payload is not None:
        command += ['--method', method or 'POST', '--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


for component in args.component:
    record = records[component]
    endpoint = 'repos/' + record['repository']
    ref = '/git/ref/heads/' + urllib.parse.quote(record['branch'], safe='')
    current = api(endpoint + ref)['object']['sha']
    if current != record['commit']:
        raise RuntimeError('Remote branch changed; inspect before updating: ' + record['repository'])
    files = sorted(p for p in (args.source / component).rglob('*') if p.is_file())
    print(record['repository'] + ': update ' + str(len(files)) + ' files from ' + current[:12], flush=True)
    if not args.publish:
        continue
    commit = api(endpoint + '/git/commits/' + current)
    entries = [dict(path=str(p.relative_to(args.source / component)), mode='100755' if p.stat().st_mode & 0o111 else '100644', type='blob', content=p.read_text()) for p in files]
    tree = api(endpoint + '/git/trees', dict(base_tree=commit['tree']['sha'], tree=entries))
    if tree['sha'] == commit['tree']['sha']:
        print('No tree changes', flush=True)
        continue
    message = 'Fix release build dependencies and prepare managed launch integration'
    if component == 'kosmickrisp':
        message = 'The release actions have been failing'
    new = api(endpoint + '/git/commits', dict(tree=tree['sha'], parents=[current], message=message + '\n\nGenerated-by: LLM'))
    # The new commit descends only from the leased head. A concurrent divergent
    # update makes this non-fast-forward PATCH fail; force is never used.
    api(endpoint + '/git/refs/heads/' + urllib.parse.quote(record['branch'], safe=''), dict(sha=new['sha'], force=False), 'PATCH')
    if 'ci' in record:
        record['previous_ci'] = record.pop('ci')
    record['commit'] = new['sha']
    path.write_text(json.dumps(records,indent=2)+'\n')
    print(record['url'] + ' @ ' + new['sha'], flush=True)
