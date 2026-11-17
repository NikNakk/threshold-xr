#!/usr/bin/env python3
"""Generate self-contained files to install into each public dependency fork."""
import argparse
import json
from pathlib import Path
import shutil
import ast

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=Path('build/release-forks'))
args = parser.parse_args()
root = Path(__file__).resolve().parent
forks = json.loads((root / 'forks.json').read_text())
for component, config in forks.items():
    destination = args.output / component
    workflow = destination / '.github/workflows/threshold-release.yml'
    workflow.parent.mkdir(parents=True, exist_ok=True)
    workflow.write_text((root / 'workflow.yml.in').read_text().replace('@COMPONENT@', component)
                        .replace('@MATRIX@', json.dumps(config['artifacts'])))
    scripts = destination / 'scripts/threshold-release'
    scripts.mkdir(parents=True, exist_ok=True)
    for name in ('build.sh', 'package.py', 'distribution-policy.json'):
        shutil.copy2(root / name, scripts / name)
    if component == 'kosmickrisp':
        # Mesa requests that generated code carry no generated prose/comments.
        shell = scripts / 'build.sh'
        shell.write_text('\n'.join(line for line in shell.read_text().splitlines()
                                   if not line.lstrip().startswith('#') or line.startswith('#!')) + '\n')
        python = scripts / 'package.py'
        tree = ast.parse(python.read_text())
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if node.body and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant) and isinstance(node.body[0].value.value, str):
                    node.body.pop(0)
        python.write_text(ast.unparse(tree) + '\n')
        workflow.write_text('\n'.join(line for line in workflow.read_text().splitlines()
                                      if not line.lstrip().startswith('#')) + '\n')
    print(f"{config['repository']} ({config['base']}): {destination}")
