"""Reproduce seven paired runs from this clone and its preserved main baseline."""
import hashlib
import json
import os
import re
import statistics
import subprocess
from pathlib import Path

zig = os.environ.get('ZIG', 'zig')
manifest = Path('build.zig.zon').read_text()
def package(name):
    block = manifest.split('.' + name + ' = .{', 1)[1].split('}', 1)[0]
    return Path('zig-pkg') / re.search(r'\.hash = "([^"]+)"', block)[1]
sdk = package('macos_sdk')
airlock = package('airlock')
sweep = package('sweep')
shakedown = package('shakedown')
provenance = dict(baseline_commit='24d0986362a0ff5e968338531a6abad0cd8b10d0',
                  manifest=manifest, sources={})
for lane, source in [('before', Path('.baseline/src')), ('after', Path('src'))]:
    provenance['sources'][lane] = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in sorted(source.rglob('*.zig'))}
Path('docs/final-ab-sources.json').write_text(json.dumps(provenance, indent=2) + '\n')
for lane, source in [('before', Path('.baseline/src')), ('after', Path('src'))]:
    common = ['-O', 'ReleaseFast', '--dep', 'airlock', '--dep', 'sweep']
    modules = ['-O', 'ReleaseFast', '--dep', 'seam', '-Mairlock=' + str(airlock / 'src/airlock.zig'),
               '-O', 'ReleaseFast', '-Mseam=' + str(airlock / 'src/seam.zig'),
               '-O', 'ReleaseFast', '-Msweep=' + str(sweep / 'src/sweep.zig')]
    driver = 'docs/filter-before-driver.zig' if lane == 'before' else 'bench/filter.zig'
    subprocess.run([zig, 'build-exe', '-O', 'ReleaseFast', '--dep', 'filter', '--dep', 'shakedown',
                    '-Mroot=' + driver, *common, '-Mfilter=' + str(source / 'CompiledFilter.zig'),
                    *modules, '-O', 'ReleaseFast', '-Mshakedown=' + str(shakedown / 'src/shakedown.zig'),
                    '-femit-bin=docs/filter-final-' + lane + '-bin'], check=True)
    subprocess.run([zig, 'build-exe', '-O', 'ReleaseFast', '-lc', '-framework', 'CoreServices',
                    '-F', str(sdk / 'Frameworks'), '-I', str(sdk / 'include'), '-L', str(sdk / 'lib'),
                    '--dep', 'lookout', '-Mroot=bench/speed_claims.zig', *common,
                    '-Mlookout=' + str(source / 'lookout.zig'), *modules,
                    '-femit-bin=docs/native-final-' + lane + '-bin'], check=True)

with open('docs/filter-final-ab.jsonl', 'w') as out:
    for round_no in range(1, 8):
        lanes = ['before', 'exact', 'folded', 'nfc']
        if round_no % 2 == 0:
            lanes.reverse()
        for lane in lanes:
            argv = ['docs/filter-final-' + ('before' if lane == 'before' else 'after') + '-bin']
            if lane == 'folded': argv.append('--folded')
            if lane == 'nfc': argv.append('--nfc')
            result = subprocess.run(argv, capture_output=True, text=True, check=True, timeout=120)
            for line in result.stdout.splitlines():
                out.write(json.dumps(dict(round=round_no, lane=lane, measurement=json.loads(line))) + '\n')
            out.flush()
rows = [json.loads(line) for line in open('docs/filter-final-ab.jsonl')]
with open('docs/filter-final-ab-summary.txt', 'w') as out:
    for lane in ['before', 'exact', 'folded', 'nfc']:
        for name in ['ignore_1', 'ignore_20', 'only_3', 'ignore_20_only_3']:
            values = [r['measurement']['best'] / 2 for r in rows if r['lane'] == lane and r['measurement']['row'] == name]
            out.write(f'{name} {lane}: best {min(values):.3f} ns/question; median of round best {statistics.median(values):.3f}; rounds {len(values)}\n')
with open('docs/native-final-ab.jsonl', 'w') as out:
    for round_no in range(1, 8):
        for lane in (['before', 'after'] if round_no % 2 else ['after', 'before']):
            result = subprocess.run(['docs/native-final-' + lane + '-bin'], capture_output=True, text=True, timeout=120)
            out.write(json.dumps(dict(round=round_no, lane=lane, exit=result.returncode, stdout=result.stdout, stderr=result.stderr)) + '\n')
            out.flush()
            if result.returncode and 'error: OverBudget' not in result.stderr:
                result.check_returncode()
rows = [json.loads(line) for line in open('docs/native-final-ab.jsonl')]
values = {}
for row in rows:
    for line in row['stdout'].splitlines():
        fields = line.split('\t')
        if len(fields) == 5 and fields[2] == 'elapsed':
            values.setdefault((row['lane'], fields[1]), []).append(float(fields[3]))
with open('docs/native-final-ab-summary.txt', 'w') as out:
    for (lane, name), samples in values.items():
        out.write(f'{name} {lane}: best {min(samples):g} ms, median {statistics.median(samples):g} ms, rounds {len(samples)}\n')
print(Path('docs/filter-final-ab-summary.txt').read_text())
print(Path('docs/native-final-ab-summary.txt').read_text())

# Paired ratios and spread, rather than treating this shared host as isolated.
with open('docs/final-ab-ratios.txt', 'w') as out:
    filter_rows = [json.loads(line) for line in open('docs/filter-final-ab.jsonl')]
    for name in ['ignore_1', 'ignore_20', 'only_3', 'ignore_20_only_3']:
        paired = {(r['round'], r['lane']): r['measurement']['best'] for r in filter_rows if r['measurement']['row'] == name}
        for lane in ['exact', 'folded', 'nfc']:
            ratios = [paired[(i, lane)] / paired[(i, 'before')] for i in range(1, 8)]
            out.write(f'{name} {lane}: median after/before {statistics.median(ratios):.4f}; spread [{min(ratios):.4f}, {max(ratios):.4f}]\n')
    native_rows = [json.loads(line) for line in open('docs/native-final-ab.jsonl')]
    paired = {}
    budgets = {}
    for r in native_rows:
        for line in r['stdout'].splitlines():
            fields = line.split('\t')
            if len(fields) != 5: continue
            _, name, metric, value, unit = fields
            if metric == 'elapsed': paired[(r['round'], r['lane'], name)] = float(value)
            if metric == 'budget': budgets[name] = float(value)
    for name in budgets:
        before = [paired[(i, 'before', name)] for i in range(1, 8)]
        after = [paired[(i, 'after', name)] for i in range(1, 8)]
        if all(before):
            ratios = [a / b for a, b in zip(after, before)]
            out.write(f'{name}: median after/before {statistics.median(ratios):.4f}; spread [{min(ratios):.4f}, {max(ratios):.4f}]\n')
        else:
            deltas = [a - b for a, b in zip(after, before)]
            out.write(f'{name}: timer-floor baseline; paired delta median {statistics.median(deltas):g} ms; spread [{min(deltas):g}, {max(deltas):g}] ms\n')
        out.write(f'{name}: target {budgets[name]:g} ms; observed after range [{min(after):g}, {max(after):g}] ms; misses {sum(a > budgets[name] for a in after)}/7\n')
print(Path('docs/final-ab-ratios.txt').read_text())
