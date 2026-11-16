#!/usr/bin/env python3
"""Pin downloaded release manifests into an importable Threshold XR stack."""
import argparse
import json
from pathlib import Path
from package import REPOSITORIES, TOKEN, digest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--id', required=True)
parser.add_argument('--channel', choices=['experimental', 'stable'], default='experimental')
parser.add_argument('--evidence', help='Recorded hardware evidence required for a stable stack')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('manifests', nargs='+', type=Path)
args = parser.parse_args()
if not TOKEN.fullmatch(args.id) or (args.channel == 'stable' and not args.evidence):
    parser.error('Use a safe stack ID and supply --evidence for stable stacks')
pins = []
seen = set()
for path in args.manifests:
    manifest = json.loads(path.read_text())
    component, version = manifest['component'], manifest['version']
    if (manifest['schema'] != 'threshold-xr/release-1' or component in seen or
            REPOSITORIES.get(component) != manifest['repository'] or not TOKEN.fullmatch(version)):
        parser.error(f'Invalid, duplicate or unsupported manifest: {path}')
    seen.add(component)
    pins.append(dict(component=component, repository=manifest['repository'], tag='threshold-' + version,
                     manifest_sha256=digest(path)))
stack = dict(schema='threshold-xr/stack-1', id=args.id, channel=args.channel,
             releases=sorted(pins, key=lambda p: p['component']))
if args.evidence:
    stack['verified'] = {'evidence': args.evidence}
args.output.write_text(json.dumps(stack, indent=2) + '\n')
print(args.output)
