#!/usr/bin/env python3
"""Record the latest release workflow status for each published fork branch."""
import json
from pathlib import Path
import subprocess
import urllib.parse

path = Path(__file__).resolve().parent / 'rollout.json'
records = json.loads(path.read_text())
for component, record in records.items():
    query = urllib.parse.urlencode({'branch': record['branch'], 'per_page': 30})
    result = subprocess.run(['gh', 'api', 'repos/' + record['repository'] + '/actions/runs?' + query],
                            text=True, capture_output=True, check=True, timeout=60)
    runs = [run for run in json.loads(result.stdout)['workflow_runs']
            if run['path'] == '.github/workflows/threshold-release.yml' and run['head_sha'] == record['commit']]
    if runs:
        run = runs[0]
        record['ci'] = {key: run[key] for key in ['id', 'status', 'conclusion', 'html_url', 'event']}
        print(component + ': ' + (run['conclusion'] or run['status']) + ' ' + run['html_url'], flush=True)
    else:
        print(component + ': no matching release workflow run observed', flush=True)
path.write_text(json.dumps(records, indent=2) + '\n')
