#!/usr/bin/env python3
"""Keep the app's bundled builder identical to the command-line implementation."""
from pathlib import Path
import argparse
import shutil

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
source = root / 'release/steam-bridge'
destination = root / 'Sources/ThresholdCore/Resources/SteamBridge'
files = ['bridge.py', 'inputs.json'] + [p.relative_to(source).as_posix() for p in (source / 'inputs').rglob('*') if p.is_file()]
for name in files:
    if args.check:
        if not (destination / name).is_file() or (source / name).read_bytes() != (destination / name).read_bytes():
            parser.exit(1, f'Bundled builder is stale: {name}; run {parser.prog}\n')
    else:
        (destination / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, destination / name)
