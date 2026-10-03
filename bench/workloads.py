"""The existing FSEvents comparison jobs and all-backend speed checks."""
import json
from pathlib import Path
import shutil
import subprocess
from quiet import HERE

PACKAGE = 'lookout'
COMPARISONS = ['Rust notify 8.2.0', 'Rust notify-debouncer-full 0.6.0', 'Go fsnotify v1.9.0',
               'Rust notify 8.2.0 kqueue and poll backends', 'Rust globset 0.4.20', 'Rust std Path',
               'Go doublestar v4.10.2', 'Go path/filepath', 'Python watchdog 6.0.0 DirectorySnapshot']

UNAVAILABLE = ['Parcel (not implemented)',
               'checkpoint: notify and notify-debouncer-full (FSEvents streams start at now, no since or history API), '
               'fsnotify (kqueue has no history), watchdog (no history), watchman (since-clocks need its resident daemon; not installed)',
               'refilter: notify, fsnotify, watchdog (a watch has no filter to change)',
               'backend_setup fsevents and poll, poll_cpu: fsnotify (kqueue only on macOS, no polling backend)',
               'baseline: notify, fsnotify (no snapshot or diff API)',
               'kqueue add, refilter and remove over the 50,000-file tree: every side is timed on the 1,000- and '
               '10,000-file trees, because lookout checks each added file against every node (minutes at 50,000)',
               'filter, path, baseline: notify-debouncer-full (the same notify underneath)']

WATCHDOG = 'watchdog==6.0.0'


def run(p, bins):
    print('Preparing existing same-job tools' if p.preparing else 'Using prepared same-job tools', flush=True)
    p.setup_command([p.tool('cargo'), 'build', '-j1', '--manifest-path', 'src/rust/Cargo.toml', '--release', '--locked'])
    fsnotify = p.scratch / 'fsnotify-bench'
    p.setup_command([p.tool('go'), 'build', '-p=1', '-mod=readonly', '-trimpath', '-ldflags=-s -w', '-o', fsnotify, '.'], cwd=HERE / 'src/go')
    p.setup_command([p.tool('python'), 'src/generate_inputs.py', '--mode', 'smoke' if p.smoke else 'full'])
    p.prepared.require(p.scratch / 'inputs')
    p.prepared.require(fsnotify)
    for crate in ('rust-extra', 'rust-kqueue'):
        p.setup_command([p.tool('cargo'), 'build', '-j1', '--manifest-path', f'src/{crate}/Cargo.toml', '--release', '--locked'])
    venv = HERE / 'build' / 'quiet-cache' / 'watchdog-venv'
    if p.preparing and not (venv / 'bin/python').exists():
        p.command([p.tool('python'), '-m', 'venv', venv])
    p.setup_command([venv / 'bin/python', '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', WATCHDOG])
    # The venv's own name for its interpreter: resolved, it is the base
    # Python, which has no watchdog.
    p.prepared.require(venv / 'bin/python')
    watchdog = venv / 'bin/python'
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

    # Every public operation the jobs above do not time. Read-only and
    # CPU-bound ones first; the baseline job clones and changes 61,000
    # files, so it runs last, where FSEvents has no later stream to slow.
    inputs = p.scratch / 'inputs'
    zig = {side: bins[side] / 'lookout-bench' for side in ('before', 'after')}
    extra, kqueue = rust + 'notify-extra-bench', rust + 'notify-kqueue-bench'
    agreed = {}

    def agree(job, keys):
        """The rows named in `keys` agree across every side and trial of
        `job`: the same result, or it is not a comparison."""
        def validate(side, rows):
            for r in rows:
                if (r['workload'], r['metric']) in keys or r['metric'] in keys:
                    seen = agreed.setdefault((job, r['workload'], r['metric']), (side, r['value']))
                    if seen[1] != r['value']:
                        raise RuntimeError(f"{job}/{r['workload']}: {side} {r['metric']} {r['value']:g}, {seen[0]} {seen[1]:g}")
        return validate

    def no_events(side, rows):
        if any(r['unit'] == 'events' and r['value'] != 0 for r in rows):
            raise RuntimeError(f'{side}: events from a tree nothing changed')

    setup_tree = inputs / 'setup_tree'
    p.group('backend_setup', [(side, [exe, 'backend_setup', inputs, setup_tree]) for side, exe in zig.items()]
            + [('notify', [extra, 'backend_setup', inputs, setup_tree]),
               ('notify-kqueue', [kqueue, 'backend_setup', inputs, setup_tree]),
               ('fsnotify', [fsnotify, 'backend_setup', inputs, setup_tree])],
            validate=no_events, warmup=False, repetitions=int(p.env.get('BENCH_RUNS', '3')))
    p.group('poll_cpu', [(side, [exe, 'poll_cpu', inputs, setup_tree]) for side, exe in zig.items()]
            + [('notify', [extra, 'poll_cpu', inputs, setup_tree])],
            validate=no_events, warmup=False, repetitions=int(p.env.get('BENCH_RUNS', '3')))

    checkpoint_roots = {side: p.scratch / 'work' / f'{side}-checkpoint' for side in zig}
    def checkpoint_missed(side, rows):
        # Kept visible, as burst losses are, smoke included: a resumed
        # watcher drops a removal fseventsd delivers more than a second
        # after its replay ends, which a loaded machine does.
        if not any(r['metric'] == 'removals_missed' for r in rows):
            raise RuntimeError(f'{side}/checkpoint: no removal count')
    p.group('checkpoint', [(side, [exe, 'checkpoint', inputs, checkpoint_roots[side]]) for side, exe in zig.items()],
            prepare=lambda side: p.command([p.tool('python'), 'src/prepare_run.py', checkpoint_roots[side], 'checkpoint']),
            cleanup=lambda side: p.command([p.tool('python'), 'src/prepare_run.py', checkpoint_roots[side], 'checkpoint', '--remove']),
            validate=checkpoint_missed, warmup=False, repetitions=int(p.env.get('BENCH_RUNS', '3')))

    p.group('filter', [(side, [exe, 'filter', inputs, setup_tree]) for side, exe in zig.items()]
            + [('globset', [extra, 'filter', inputs, setup_tree]),
               ('doublestar', [fsnotify, 'filter', inputs, setup_tree])],
            validate=agree('filter', {'excluded', 'paths'}), warmup=False,
            repetitions=int(p.env.get('BENCH_RUNS', '5')))
    p.group('path', [(side, [exe, 'path', inputs, setup_tree]) for side, exe in zig.items()]
            + [('rust-std', [extra, 'path', inputs, setup_tree]),
               ('go-filepath', [fsnotify, 'path', inputs, setup_tree])],
            validate=agree('path', {'inside', 'relative_bytes', 'paths'}), warmup=False,
            repetitions=int(p.env.get('BENCH_RUNS', '5')))

    # Clones of the pristine trees, shared by every side: each run puts
    # back what it changed before it returns.
    trees = p.scratch / 'work' / 'baseline'
    def clone(_side):
        if not trees.exists():
            trees.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['cp', '-cR', str(inputs / 'baseline_trees'), str(trees)], check=True)
    try:
        p.group('baseline', [(side, [exe, 'baseline', inputs, trees]) for side, exe in zig.items()]
                + [('watchdog', [watchdog, HERE / 'src/watchdog_bench.py', 'baseline', inputs, trees])],
                prepare=clone, validate=agree('baseline', {'created', 'modified', 'removed'}), warmup=False,
                repetitions=int(p.env.get('BENCH_RUNS', '3')))
    finally:
        shutil.rmtree(trees, ignore_errors=True)
