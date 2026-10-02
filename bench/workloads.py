"""The existing FSEvents comparison jobs and all-backend speed checks."""
from quiet import HERE

PACKAGE = 'lookout'
COMPARISONS = ['Rust notify 8.2.0', 'Rust notify-debouncer-full 0.6.0', 'Go fsnotify v1.9.0']

UNAVAILABLE = ['Parcel (not implemented)']


def run(p, bins):
    print('Building existing same-job tools', flush=True)
    p.command([p.tool('cargo'), 'build', '-j1', '--manifest-path', 'src/rust/Cargo.toml', '--release', '--locked'])
    fsnotify = p.scratch / 'fsnotify-bench'
    p.command([p.tool('go'), 'build', '-p=1', '-mod=readonly', '-trimpath', '-ldflags=-s -w', '-o', fsnotify, '.'], cwd=HERE / 'src/go')
    p.command([p.tool('python'), 'src/generate_inputs.py', '--mode', 'smoke' if p.smoke else 'full'])
    rust = p.env['CARGO_TARGET_DIR'] + '/release/'
    tools = [('before', bins['before'] / 'lookout-bench'), ('after', bins['after'] / 'lookout-bench'),
             ('notify', rust + 'notify-raw-bench'), ('notify-debouncer-full', rust + 'notify-debounced-bench'),
             ('fsnotify', fsnotify)]
    for job in ('latency', 'burst', 'rename', 'idle', 'tree_setup'):
        roots = {side: p.scratch / 'work' / f'{side}-{job}' for side, _ in tools}
        def prepare(side):
            if job != 'tree_setup':
                p.command([p.tool('python'), 'src/prepare_run.py', roots[side], job])
        def cleanup(side):
            if job != 'tree_setup':
                p.command([p.tool('python'), 'src/prepare_run.py', roots[side], job, '--remove'])
        def validate(side, rows):
            # Delivery differences stay visible. The setup itself must succeed.
            if job == 'tree_setup' and not any(r['metric'] == 'setup_success' and r['value'] == 1 for r in rows):
                raise RuntimeError(f'{side}: tree setup failed')
        sides = [(side, [exe, job, p.scratch / 'inputs',
                          p.scratch / 'inputs/setup_tree' if job == 'tree_setup' else roots[side]])
                 for side, exe in tools]
        p.group(job, sides, prepare=prepare, cleanup=cleanup, validate=validate, warmup=False,
                repetitions=int(p.env.get('BENCH_RUNS', '5' if job in ('rename', 'tree_setup') else '3')))
    p.group('backend-speed-checks', [(side, [bins[side] / 'speed-claims'])
                                     for side in ('before', 'after')], parser='test', warmup=False)
