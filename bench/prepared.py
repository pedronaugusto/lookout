"""Preparation receipt: source identity and required immutable artifacts, no clocks."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

class Prepared:
    def __init__(self, here, root):
        self.here, self.root = Path(here), Path(root)
        self.receipt = self.root / 'prepared.json'
        self.assets = set()

    def identity(self):
        env = os.environ.copy()
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        names = subprocess.check_output(['git', 'ls-files', '--', 'bench'], cwd=self.here.parent, env=env, text=True).splitlines()
        digest = hashlib.sha256()
        for name in sorted(set(names + ['bench/prepared.py'])):
            path = self.here.parent / name
            if path.is_file():
                digest.update(name.encode() + b'\0' + path.read_bytes())
        return digest.hexdigest()

    def require(self, path):
        path = Path(path).resolve()
        if not path.exists():
            raise RuntimeError(f'Missing prepared artifact: {path}; run bench/quiet.sh --smoke')
        if path.is_file():
            self.assets.add(str(path))
        else:
            # Existence checks avoid reading corpus bytes into the page cache.
            self.assets.update(str(p.resolve()) for p in path.rglob('*') if p.is_file())
        return path

    def write(self):
        self.receipt.parent.mkdir(parents=True, exist_ok=True)
        self.receipt.write_text(json.dumps({'source':self.identity(), 'assets':{
            p:Path(p).stat().st_size for p in sorted(self.assets)}}, indent=2) + '\n')

    def certify(self):
        saved = json.loads(self.receipt.read_text())
        if saved['source'] != self.identity():
            raise RuntimeError('Harness changed during preparation; rerun bench/quiet.sh --smoke')
        saved['smoke_passed'] = True
        self.receipt.write_text(json.dumps(saved, indent=2) + '\n')

    def check(self):
        if not self.receipt.exists():
            raise RuntimeError('No preparation receipt; run bench/quiet.sh --smoke')
        saved = json.loads(self.receipt.read_text())
        if saved['source'] != self.identity():
            raise RuntimeError('Preparation is stale; run bench/quiet.sh --smoke')
        for name, size in saved['assets'].items():
            path = Path(name)
            if not path.is_file() or path.stat().st_size != size:
                raise RuntimeError(f'Missing or changed prepared artifact: {name}; run bench/quiet.sh --smoke')
        print(f"Prepared: {len(saved['assets'])} artifacts; no builds or benchmark clocks", flush=True)
