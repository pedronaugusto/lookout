"""The existing FSEvents comparison jobs and all-backend speed checks."""
import json
from quiet import HERE

PACKAGE = 'lookout'
COMPARISONS = ['Rust notify 8.2.0', 'Rust notify-debouncer-full 0.6.0', 'Go fsnotify v1.9.0']

UNAVAILABLE = ['Parcel (not implemented)']


def run(p, bins):
    print('Preparing existing same-job tools' if p.preparing else 'Using prepared same-job tools', flush=True)
    p.setup_command([p.tool('cargo'), 'build', '-j1', '--manifest-path', 'src/rust/Cargo.toml', '--release', '--locked'])
    fsnotify = p.scratch / 'fsnotify-bench'
    p.setup_command([p.tool('go'), 'build', '-p=1', '-mod=readonly', '-trimpath', '-ldflags=-s -w', '-o', fsnotify, '.'], cwd=HERE / 'src/go')
    p.setup_command([p.tool('python'), 'src/generate_inputs.py', '--mode', 'smoke' if p.smoke else 'full'])
    p.prepared.require(p.scratch / 'inputs')
    p.prepared.require(fsnotify)
    config = json.loads((p.scratch / 'inputs/config.json').read_text())
    rust = p.env['CARGO_TARGET_DIR'] + '/release/'
    tools = [('before', bins['before'] / 'lookout-bench'), ('after', bins['after'] / 'lookout-bench'),
             ('notify', rust + 'notify-raw-bench'), ('notify-debouncer-full', rust + 'notify-debounced-bench'),
             ('fsnotify', fsnotify)]
    # First, before any workload creates or removes a tree: FSEvents delivers
    # those removals to every later stream, and a check run behind 100,000 of
    # them measures the event service's backlog, not lookout. The checks'
    # own trees are a few files each and settle within their tests.
    p.group('backend-speed-checks', [(side, [bins[side] / 'speed-claims'])
                                     for side in ('before', 'after')], parser='test', warmup=False)
    for job in ('latency', 'burst', 'rename', 'idle', 'tree_setup'):
        roots = {side: p.scratch / 'work' / f'{side}-{job}' for side, _ in tools}
        def prepare(side):
            if job != 'tree_setup':
                p.command([p.tool('python'), 'src/prepare_run.py', roots[side], job])
        def cleanup(side):
            if job != 'tree_setup':
                p.command([p.tool('python'), 'src/prepare_run.py', roots[side], job, '--remove'])
        def validate(side, rows):
            # Check writes outside the measured region; delivery differences stay visible.
            root = roots[side]
            patterns = {'latency': ('latency-*.txt', config['latency_trials']),
                        'rename': ('r*-new.txt', config['rename_count']),
                        'idle': ('idle-*.txt', config['idle_seconds'] * config['idle_rate'])}
            if job in patterns:
                pattern, expected = patterns[job]
                if sum(1 for _ in root.glob(pattern)) != expected:
                    raise RuntimeError(f'{side}/{job}: writer did not complete')
            if job == 'burst':
                for count in config['burst_counts']:
                    if sum(1 for _ in (root / f'burst-{count}').glob('f*.txt')) != count:
                        raise RuntimeError(f'{side}/{job}: writer did not complete')
            if job == 'rename' and any(root.glob('r*-old.txt')):
                raise RuntimeError(f'{side}/{job}: old rename paths remain')
            if job == 'tree_setup' and not any(r['metric'] == 'setup_success' and r['value'] == 1 for r in rows):
                raise RuntimeError(f'{side}: tree setup failed')
        sides = [(side, [exe, job, p.scratch / 'inputs',
                          p.scratch / 'inputs/setup_tree' if job == 'tree_setup' else roots[side]])
                 for side, exe in tools]
        p.group(job, sides, prepare=prepare, cleanup=cleanup, validate=validate, warmup=False,
                repetitions=int(p.env.get('BENCH_RUNS', '5' if job in ('rename', 'tree_setup') else '3')))
