#!/usr/bin/env python3
"""Publish isolated review branches; never move an integration branch or release tag."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--publish', action='store_true')
parser.add_argument('--source', type=Path, default=Path('build/release-forks'))
parser.add_argument('--record', type=Path, default=Path('release/rollout.json'))
args = parser.parse_args()
root = Path(__file__).resolve().parent
forks = json.loads((root / 'forks.json').read_text())
branch = 'codex/threshold-releases'
records = json.loads(args.record.read_text()) if args.record.exists() else {}


def api(path, payload=None, missing_ok=False):
    command = ['gh', 'api', path]
    if payload is not None:
        command += ['--method', 'POST', '--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, timeout=60)
    if result.returncode:
        if missing_ok and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


for component, config in forks.items():
    repository = config['repository']
    endpoint = 'repos/' + repository
    files = sorted(p for p in (args.source / component).rglob('*') if p.is_file())
    if len(files) != 4:
        raise ValueError('Generate the fork payloads first: ' + component)
    head = api(endpoint + '/git/ref/heads/' + urllib.parse.quote(config['base'], safe=''))['object']['sha']
    existing = api(endpoint + '/git/ref/heads/' + urllib.parse.quote(branch, safe=''), missing_ok=True)
    if existing:
        previous = records.get(component, {})
        if previous.get('commit') == existing['object']['sha']:
            print(repository + ': already published', flush=True)
            continue
        raise ValueError('Refusing to overwrite an existing branch in ' + repository)
    print(repository + ': ' + config['base'] + '@' + head[:12] + ' -> ' + branch, flush=True)
    if not args.publish:
        continue
    commit = api(endpoint + '/git/commits/' + head)
    entries = [dict(path=str(path.relative_to(args.source / component)), mode='100644', type='blob', content=path.read_text())
               for path in files]
    tree = api(endpoint + '/git/trees', dict(base_tree=commit['tree']['sha'], tree=entries))
    message = 'Add Threshold XR dependency release workflow and packaging'
    if component == 'kosmickrisp':
        # Use the user's own text, as required by this fork's contribution policy.
        message = 'Please proceed with the plan for allowing Threshold XR to install releases for dependencies that are created by GitHub Actions in each of our relevant forks.'
    new_commit = api(endpoint + '/git/commits', dict(message=message + '\n\nGenerated-by: LLM', tree=tree['sha'], parents=[head]))
    api(endpoint + '/git/refs', dict(ref='refs/heads/' + branch, sha=new_commit['sha']))
    records[component] = dict(repository=repository, base=config['base'], base_commit=head,
                              branch=branch, commit=new_commit['sha'],
                              url='https://github.com/' + repository + '/tree/' + branch)
    args.record.write_text(json.dumps(records, indent=2) + '\n')
    print(records[component]['url'], flush=True)
