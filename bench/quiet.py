#!/usr/bin/env python3
"""Build immutable A/B snapshots, interleave jobs, retain portable results."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from prepared import Prepared

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
CUTOFF = '2026-09-30 00:00:00 +0100'


class Pass:
    def __init__(self, smoke: bool, scratch: Path, results: Path):
        self.smoke, self.scratch, self.results = smoke, scratch, results
        self.env = os.environ.copy()
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', PYTHONDONTWRITEBYTECODE='1')
        self.preparing = smoke
        self.plan_only = False
        self.prepared = Prepared(HERE, scratch)
        self.env.update(BENCH_SMOKE='1' if smoke else '0',
                        BENCH_MODE='smoke' if smoke else 'full',
                        BENCH_BUILD_DIR=str(scratch))
        cache = HERE / 'build' / 'quiet-cache'
        cache.mkdir(parents=True, exist_ok=True)
        for name, directory in [('ZIG_GLOBAL_CACHE_DIR', 'zig-global'),
                                ('CARGO_HOME', 'cargo-home'),
                                ('CARGO_TARGET_DIR', 'cargo-target'),
                                ('GOCACHE', 'go-cache'), ('GOPATH', 'go-path'),
                                ('GOMODCACHE', 'go-mod')]:
            self.env[name] = str(cache / directory)
        self.data = {'schema': 1, 'mode': 'smoke' if smoke else 'full',
                     'status': 'preparing', 'timings_recorded': False,
                     'started_utc': utc(), 'samples': [], 'checks': [], 'failed_checks': []}
        self.runs = int(os.environ.get('BENCH_RUNS', '5'))
        if self.runs < 1:
            raise ValueError('BENCH_RUNS must be positive')

    def tool(self, name):
        return self.env.get('PYTHON', sys.executable) if name == 'python' else self.env.get(name.upper(), name)

    def command(self, args, cwd=HERE, capture=False, timeout=None, judged=False):
        """`judged` returns a failed run's output and status to the caller, which
        records it; any other failure raises."""
        result = subprocess.run([str(x) for x in args], cwd=cwd, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=timeout)
        if judged:
            return result.stdout, result.stderr, result.returncode
        if result.returncode:
            if capture and self.smoke:
                # Failed smoke stderr may contain time values; do not retain it.
                raise RuntimeError(f'{Path(str(args[0])).name} failed ({result.returncode})')
            sys.stderr.write(result.stderr)
            raise RuntimeError(f'{Path(str(args[0])).name} failed ({result.returncode})')
        return (result.stdout, result.stderr) if capture else result.stdout

    def setup_command(self, args, **kwargs):
        if self.preparing:
            return self.command(args, **kwargs)
        return ''

    def zig(self, directory: Path):
        if not self.preparing:
            return self.prepared.require(directory / 'out' / 'bin')
        print(f'Building {directory.relative_to(self.scratch)}', flush=True)
        self.command([self.tool('zig'), 'build', '-j1', '-Doptimize=ReleaseFast',
                      *(['-Dsnapshot=true'] if directory.name == 'bench' else []),
                      f'-Dsmoke={str(self.smoke).lower()}', '--prefix', directory / 'out',
                      '--cache-dir', directory / 'cache'], cwd=directory)
        return self.prepared.require(directory / 'out' / 'bin')

    def snapshots(self, before, after):
        binaries = {}
        for side, revision in [('before', before), ('after', after)]:
            root = self.scratch / side
            if not self.preparing:
                marker = root / '.bench-revision'
                if not marker.exists() or marker.read_text() != revision:
                    raise RuntimeError('Snapshot revision differs from preparation; run bench/quiet.sh --smoke')
                binaries[side] = self.zig(root / 'bench')
                continue
            root.mkdir(parents=True, exist_ok=True)
            marker = root / '.bench-revision'
            if not marker.exists() or marker.read_text() != revision:
                shutil.rmtree(root)
                root.mkdir()
                archive = subprocess.check_output(['git', 'archive', revision], cwd=REPO, env=self.env)
                subprocess.run(['tar', '-xf', '-', '-C', str(root)], input=archive, check=True)
                marker.write_text(revision)
            def ignored(directory, names):
                return [n for n in names if n in {'build', 'results', '.zig-cache',
                        'zig-out', 'zig-pkg', 'target', '__pycache__'}]
            shutil.copytree(HERE, root / 'bench', ignore=ignored, dirs_exist_ok=True)
            binaries[side] = self.zig(root / 'bench')
        return binaries

    def group(self, workload, sides, *, prepare=None, cleanup=None,
              parser='tsv', validate=None, warmup=True, repetitions=None):
        """For each job: A,B,A,B; comparisons follow each A/B pair."""
        if self.plan_only:
            for _, argv in sides:
                if Path(str(argv[0])).is_absolute(): self.prepared.require(argv[0])
            return
        print(f'Checking {workload}' if self.smoke else f'Running {workload}', flush=True)
        count = 1 if self.smoke else (self.runs if repetitions is None else repetitions)
        def invoke(side, args, trial):
            if prepare:
                prepare(side)
            try:
                # A full pass keeps a speed check that went over its ceiling as a
                # failed sample and goes on; smoke still stops at the first failure.
                judged = parser == 'test' and not self.smoke
                if judged:
                    stdout, stderr, status = self.command(args, capture=True, judged=True)
                else:
                    stdout, stderr = self.command(args, capture=True)
                if parser == 'text':
                    rows = []
                    if not stdout.strip():
                        raise RuntimeError(f'{workload}/{side}: empty output')
                else:
                    rows = parse_rows(stderr if parser == 'test' else stdout, work=parser == 'work', loose=parser == 'test')
                    if not rows:
                        raise RuntimeError(f'{workload}/{side}: no result rows')
                if validate:
                    validate(side, rows)
                verdicts = []
                if judged:
                    rows, verdicts = budgets(rows)
                    over = {v['workload'] for v in verdicts if not v['passed']}
                    if status and not only_over_budget(stderr, over):
                        # Not a ceiling: a broken check is not a measurement.
                        sys.stderr.write(stderr)
                        raise RuntimeError(f'{Path(str(args[0])).name} failed ({status})')
                    if not status and over:
                        raise RuntimeError(f'{workload}/{side}: over budget but the check passed')
                if trial is None:
                    return
                item = {'job': workload, 'side': side, 'trial': trial,
                        'status': 'failed' if any(not v['passed'] for v in verdicts) else 'passed',
                        'result_rows': len(rows)}
                if verdicts:
                    item['budgets'] = verdicts
                for v in verdicts:
                    if not v['passed']:
                        self.data['failed_checks'].append({'job': workload, 'side': side, 'trial': trial, **v})
                if self.smoke:
                    # Keep only counts/booleans; discard all timing/throughput/ratios.
                    item['correctness'] = [r for r in rows if r['unit'] in
                                           {'events', 'files', 'bool', 'renames', 'records', 'bytes'}]
                    self.data['checks'].append(item)
                else:
                    item['metrics'] = rows
                    item['load_average'] = list(os.getloadavg()) if hasattr(os, 'getloadavg') else None
                    if parser == 'text':
                        item['output'] = stdout
                    self.data['samples'].append(item)
            finally:
                if cleanup:
                    cleanup(side)
        if not self.smoke and warmup:
            for side, args in sides:
                invoke(side, args, None)
        for trial in range(count):
            for side, args in sides:
                invoke(side, args, trial)
            self.persist()

    def persist(self):
        path = self.results / ('smoke' if self.smoke else 'results')
        self.data['timings_recorded'] = bool(self.data['samples'])
        self.data['summary'] = summarize(self.data['samples'])
        self.data['before_after'] = paired(self.data['samples'])
        path.with_suffix('.json').write_text(json.dumps(self.data, indent=2, allow_nan=False) + '\n')
        lines = [f"# {self.data.get('package', 'Package')} benchmark {'smoke' if self.smoke else 'pass'}",
                 '', f"Status: {self.data['status']}", '',
                 f"Before: `{self.data.get('before', '')}`", '',
                 f"After: `{self.data.get('after', '')}`", '',
                 'Order for each job: before, after, then existing same-job tools; repeat.', '',
                 'Smoke only: no timing values retained or performance claims.' if self.smoke else
                 'One untimed warm-up per side (watchers warm up internally); all samples retained, median summaries.', '',
                 '## Machine and toolchains', '', '```json',
                 json.dumps(self.data.get('machine', {}), indent=2), '```', '']
        if self.smoke:
            lines.extend(['## Checks', '', f"{len(self.data['checks'])} smoke invocations passed.", ''])
        if self.data['failed_checks']:
            lines.extend(['## Failed checks', '', '| Job | Side | Trial | Workload | Value | Budget | Unit |',
                          '|---|---|---:|---|---:|---:|---|'])
            for r in self.data['failed_checks']:
                lines.append(f"| {r['job']} | {r['side']} | {r['trial']} | {r['workload']} | {r['value']} | {r['budget']} | {r['unit']} |")
            lines.append('')
        lines.extend(['## Comparison scope', '', *['- ' + name for name in self.data.get('comparisons', [])], '',
                      *['Unavailable: ' + name for name in self.data.get('unavailable', [])], ''])
        if self.data['summary']:
            lines.extend(['## Measurements', '', '| Job | Side | Workload | Metric | Median | Unit | N |',
                          '|---|---|---|---|---:|---|---:|'])
            for r in self.data['summary']:
                lines.append(f"| {r['job']} | {r['side']} | {r['workload']} | {r['metric']} | {r['median']} | {r['unit']} | {r['n']} |")
        if self.data['before_after']:
            lines.extend(['', '## Before / after', '',
                          'Factors are after / before for each adjacent trial pair; lower time and higher throughput are better.', '',
                          '| Job | Workload | Metric | Unit | Median factor | Paired trials |',
                          '|---|---|---|---|---:|---:|'])
            for row in self.data['before_after']:
                lines.append(f"| {row['job']} | {row['workload']} | {row['metric']} | {row['unit']} | {row['median_after_over_before']:.6f} | {row['pairs']} |")
        for sample in self.data['samples']:
            if 'output' in sample:
                lines.extend(['', f"### {sample['job']} / {sample['side']} / trial {sample['trial']}",
                              '', '```text', sample['output'].rstrip(), '```'])
        if 'error' in self.data:
            lines.extend(['', f"Error: {self.data['error']}"])
        path.with_suffix('.md').write_text('\n'.join(lines) + '\n')


def parse_rows(output, work=False, loose=False):
    rows = []
    for line in output.splitlines():
        fields = line.split('\t')
        if work and len(fields) == 4:
            fields.insert(2, 'elapsed' if fields[-1] != 'ratio' else 'ratio')
        if len(fields) != 5:
            if loose or not line.strip():
                continue  # Zig's test runner also prints progress.
            raise RuntimeError('malformed benchmark row')
        _, workload, metric, value, unit = fields
        number = None if value == 'n/a' else float(value)
        if number is not None and not math.isfinite(number):
            raise RuntimeError(f'non-finite metric: {workload}/{metric}')
        rows.append({'workload': workload, 'metric': metric, 'value': number, 'unit': unit})
    return rows


def budgets(rows):
    """Splits a speed check's ceilings out of its measurements: each `budget`
    row and `within_budget` verdict joins the `elapsed` row of its workload."""
    measured, ceilings, within = [], {}, {}
    for row in rows:
        if row['metric'] == 'budget':
            ceilings[row['workload']] = row
        elif row['metric'] == 'within_budget':
            within[row['workload']] = row['value'] == 1
        else:
            measured.append(row)
    if set(ceilings) != set(within):
        raise RuntimeError('speed check budget without a verdict')
    values = {r['workload']: r for r in measured if r['metric'] == 'elapsed'}
    verdicts = []
    for workload in sorted(ceilings):
        if workload not in values or values[workload]['unit'] != ceilings[workload]['unit']:
            raise RuntimeError(f'{workload}: budget without a matching measurement')
        verdicts.append({'workload': workload, 'value': values[workload]['value'],
                         'budget': ceilings[workload]['value'], 'unit': ceilings[workload]['unit'],
                         'passed': within[workload]})
    return measured, verdicts


def only_over_budget(output, over):
    """Whether every test the Zig runner failed went over a ceiling, and
    nothing else went wrong: each failure is an unmet expectation in a test
    that reported a workload in `over`."""
    tests, current, failed = {}, None, []
    for line in output.splitlines():
        if re.match(r'\d+/\d+ ', line):
            current = line.split('...', 1)[0]
            tests[current] = set()
        fields = line.split('\t')
        if current is not None and len(fields) == 5:
            tests[current].add(fields[1])
        reason = re.search(r'FAIL \((\w+)\)$', line)
        if reason:
            if reason.group(1) != 'TestUnexpectedResult':
                return False
            failed.append(current)
    if not failed or 'leaked' in output or not re.search(rf'\b{len(failed)} failed\.', output):
        return False
    return all(name is not None and tests[name] & over for name in failed)


def summarize(samples):
    groups = {}
    for sample in samples:
        for row in sample['metrics']:
            key = (sample['job'], sample['side'], row['workload'], row['metric'], row['unit'])
            groups.setdefault(key, []).append(row['value'])
    return [dict(zip(('job', 'side', 'workload', 'metric', 'unit'), key),
                 median=statistics.median([x for x in values if x is not None])
                 if any(x is not None for x in values) else None, n=len(values))
            for key, values in sorted(groups.items())]


def paired(samples):
    values = {}
    for sample in samples:
        if sample['side'] not in ('before', 'after'):
            continue
        for row in sample['metrics']:
            if row['value'] is None or row['unit'] in {'events', 'files', 'bool', 'renames', 'records', 'bytes'} or row['metric'] == 'target':
                continue
            key = (sample['job'], row['workload'], row['metric'], row['unit'], sample['trial'])
            values.setdefault(key, {})[sample['side']] = row['value']
    factors = {}
    for key, pair in values.items():
        if 'before' in pair and 'after' in pair and pair['before'] > 0:
            factors.setdefault(key[:-1], []).append(pair['after'] / pair['before'])
    return [dict(zip(('job', 'workload', 'metric', 'unit'), key),
                 median_after_over_before=statistics.median(rows), pairs=len(rows))
            for key, rows in sorted(factors.items())]


def git(*args):
    return subprocess.check_output(['git', *args], cwd=REPO, text=True).strip()


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def machine(p):
    data = {'load_average': list(os.getloadavg()) if hasattr(os, 'getloadavg') else None,
            'free_disk_bytes': shutil.disk_usage(HERE).free, 'os': platform.system(), 'os_version': platform.mac_ver()[0] or platform.release(),
            'architecture': platform.machine(), 'logical_cpus': os.cpu_count(),
            'python': platform.python_version(), 'toolchains': {}}
    for key, args in [('cpu', ['sysctl', '-n', 'machdep.cpu.brand_string']),
                      ('memory_bytes', ['sysctl', '-n', 'hw.memsize']),
                      ('model', ['sysctl', '-n', 'hw.model']),
                      ('power', ['pmset', '-g', 'batt'])]:
        try:
            value = p.command(args)
            # Battery names can be machine-specific; retain power source only.
            if key == 'power':
                value = value.splitlines()[0]
            data[key] = value.strip()
        except (OSError, RuntimeError):
            data[key] = 'unavailable'
    for name, flags in [('zig', ['version']), ('cargo', ['--version']),
                        ('rustc', ['--version']), ('go', ['version']), ('cc', ['--version'])]:
        try:
            data['toolchains'][name] = p.command([p.tool(name), *flags]).splitlines()[0]
        except (OSError, RuntimeError):
            data['toolchains'][name] = 'unavailable'
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--before', help='override the pre-pass main revision')
    parser.add_argument('--after', help='override current main')
    parser.add_argument('--prepare-only', action='store_true', help='Build full artifacts without running workloads')
    parser.add_argument('--check-prepared', action='store_true', help='Verify full artifacts without building or measuring')
    args = parser.parse_args()
    if args.smoke:
        subprocess.run([sys.executable, __file__, *[a for a in sys.argv[1:] if a != '--smoke'], '--prepare-only'], check=True)
    pins = json.loads((HERE / 'revisions.json').read_text())
    before = git('rev-parse', f'{args.before or pins["before"]}^{{commit}}')
    after = git('rev-parse', f'{args.after or pins["after"]}^{{commit}}')
    if not before:
        parser.error('no main revision before cutoff')
    if not args.after:
        subprocess.run(['git', 'merge-base', '--is-ancestor', after, 'HEAD'], cwd=REPO, check=True)
    stamp = dt.datetime.now(dt.timezone.utc)
    results = HERE / 'results' / stamp.strftime('%Y-%m-%d') / stamp.strftime('%H%M%S.%fZ')
    results.mkdir(parents=True)
    build = HERE / 'build'
    build.mkdir(exist_ok=True)
    # Smoke and full artifacts persist separately, including compiled snapshots.
    scratch = build / 'quiet-prepared' / ('smoke' if args.smoke else 'full')
    scratch.mkdir(parents=True, exist_ok=True)
    p = Pass(args.smoke, scratch, results)
    p.preparing = args.smoke or args.prepare_only
    p.plan_only = args.prepare_only or args.check_prepared
    if not p.preparing:
        p.prepared.check()
        if not json.loads(p.prepared.receipt.read_text()).get('smoke_passed'):
            raise RuntimeError('Preparation has not passed smoke; run bench/quiet.sh --smoke')
    import workloads
    p.data.update(package=workloads.PACKAGE, before=before, after=after,
                  cutoff=CUTOFF, optimize='ReleaseFast', harness_revision=git('rev-parse', 'HEAD'),
                  harness_dirty=bool(git('status', '--porcelain', '--', 'bench')),
                  comparisons=workloads.COMPARISONS,
                  unavailable=getattr(workloads, 'UNAVAILABLE', []),
                  trials=1 if args.smoke else p.runs)
    digest = hashlib.sha256()
    for name in sorted(git('ls-files', '--', 'bench').splitlines()):
        source = REPO / name
        if source.is_file():
            digest.update(name.encode() + b'\0' + source.read_bytes())
    p.data['harness_sha256'] = digest.hexdigest()
    p.data['machine'] = machine(p)
    p.persist()
    try:
        bins = p.snapshots(before, after)
        p.data['status'] = 'running'
        workloads.run(p, bins)
        if args.prepare_only: p.prepared.write()
        if args.smoke: Prepared(HERE, build/'quiet-prepared/full').certify()
        p.data['status'] = 'failed' if p.data['failed_checks'] else 'passed'
    except Exception as error:
        p.data.update(status='failed', error=f'{type(error).__name__}: pass failed; see terminal')
        raise
    finally:
        p.data['finished_utc'] = utc()
        p.persist()
    label = 'Preparation' if args.prepare_only else 'Prepared checks' if args.check_prepared else 'Smoke checks' if args.smoke else 'Timed pass'
    return verdict(p.data, label, results.relative_to(REPO))


def verdict(data, label, results):
    """Says how the pass ended, once its results are written; the exit status."""
    if data['failed_checks']:
        for r in data['failed_checks']:
            print(f"Over budget: {r['job']}/{r['side']}/trial {r['trial']} {r['workload']} "
                  f"{r['value']:g} {r['unit']} (budget {r['budget']:g})", file=sys.stderr)
        print(f"{label} failed: {len(data['failed_checks'])} speed checks over budget. Results: {results}",
              file=sys.stderr)
        return 1
    print(f"{label} passed. Results: {results}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
