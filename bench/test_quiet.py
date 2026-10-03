"""Check the pass protocol with invented output; never run timed jobs."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import io
from contextlib import redirect_stderr, redirect_stdout

from quiet import Pass, paired, parse_rows, verdict


class ProtocolTests(unittest.TestCase):
    def make_pass(self, smoke, root):
        results = root / 'results'
        results.mkdir()
        p = Pass(smoke, root, results)
        p.runs = 2
        return p

    def test_interleaves_pairs_after_one_warmup_and_keeps_every_sample(self):
        with tempfile.TemporaryDirectory() as name:
            p = self.make_pass(False, Path(name))
            calls = []
            def command(args, **kwargs):
                calls.append(args[0])
                return f'side\tjob\telapsed\t{len(calls)}\tms\n', ''
            p.command = command
            p.group('job', [('before', ['A']), ('after', ['B']), ('tool', ['C'])])
            self.assertEqual(calls, ['A', 'B', 'C'] * 3)
            self.assertEqual([(s['side'], s['trial']) for s in p.data['samples']],
                             [(side, trial) for trial in range(2) for side in ('before', 'after', 'tool')])
            self.assertEqual(len(p.data['before_after']), 1)
            self.assertEqual(p.data['before_after'][0]['pairs'], 2)

    def test_selected_jobs_run_and_the_others_are_skipped(self):
        with tempfile.TemporaryDirectory() as name:
            p = self.make_pass(False, Path(name))
            p.jobs = {'kept'}
            calls = []
            def command(args, **kwargs):
                calls.append(args[0])
                return 'side\tjob\telapsed\t1\tms\n', ''
            p.command = command
            p.group('skipped', [('before', ['S'])])
            p.group('kept', [('before', ['K'])])
            self.assertEqual(calls, ['K'] * 3)
            self.assertEqual(p.ran, {'kept'})

    def test_speed_checks_run_before_any_tree_workload(self):
        import workloads
        groups = []
        class Recorder:
            smoke = preparing = False
            scratch = Path('/nonexistent')
            env = {'CARGO_TARGET_DIR': '/nonexistent'}
            class prepared:
                @staticmethod
                def require(path): return path
            def tool(self, name): return name
            def setup_command(self, args, **kwargs): return ''
            def group(self, workload, sides, **kwargs): groups.append(workload)
        with patch('pathlib.Path.read_text', return_value='{}'):
            workloads.run(Recorder(), {'before': Path('/b'), 'after': Path('/a')})
        self.assertEqual(groups[0], 'backend-speed-checks')
        # The job that clones and changes 61,000 files runs after every
        # FSEvents measurement.
        self.assertEqual(groups[-1], 'baseline')
        self.assertLess(groups.index('tree_setup'), groups.index('backend_setup'))

    def test_smoke_runs_once_and_drops_time_rate_ratio_and_raw_output(self):
        with tempfile.TemporaryDirectory() as name:
            p = self.make_pass(True, Path(name))
            calls = []
            def command(args, **kwargs):
                calls.append(args[0])
                return ('side\tjob\telapsed\t123.45\tms\n'
                        'side\tjob\trate\t456.78\tlines/s\n'
                        'side\tjob\tratio\t2.3\tratio\n'
                        'side\tjob\tfiles_missed\t0\tfiles\n'), ''
            p.command = command
            p.group('job', [('before', ['A']), ('after', ['B'])])
            self.assertEqual(calls, ['A', 'B'])
            result = (p.results / 'smoke.json').read_text()
            self.assertNotIn('123.45', result)
            self.assertNotIn('456.78', result)
            self.assertNotIn('2.3', result)
            self.assertEqual(json.loads(result)['samples'], [])
            self.assertFalse(json.loads(result)['timings_recorded'])
            self.assertEqual(p.data['checks'][0]['correctness'][0]['value'], 0)

    def test_each_mutable_root_is_prepared_and_removed_even_on_failure(self):
        with tempfile.TemporaryDirectory() as name:
            p = self.make_pass(True, Path(name))
            calls = []
            def command(args, **kwargs):
                calls.append('run')
                raise RuntimeError('fixture failure')
            p.command = command
            with self.assertRaises(RuntimeError):
                p.group('job', [('before', ['A'])], prepare=lambda side: calls.append('prepare'),
                        cleanup=lambda side: calls.append('cleanup'))
            self.assertEqual(calls, ['prepare', 'run', 'cleanup'])

    def test_full_preflight_never_builds_or_invokes_workloads(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            p = self.make_pass(False, root)
            p.preparing = False
            p.plan_only = True
            binary = root/'before/bench/out/bin/job'
            binary.parent.mkdir(parents=True)
            binary.write_text('prepared')
            p.command = lambda *a, **k: self.fail('preflight executed a command')
            self.assertEqual(p.zig(root/'before/bench'), binary.parent.resolve())
            self.assertEqual(p.setup_command(['cargo', 'build']), '')
            p.group('job', [('before', [binary])], prepare=lambda side: self.fail('mutated fixture'))
            self.assertEqual(p.data['samples'], [])

    # What the speed-check binary prints when FSEvents misses its ceiling and
    # kqueue keeps to it, and when it passes.
    OVER = ('1/2 speed_claims.test.quiet: a change...fsevents: worst wake 4504 ms, budget 500 ms\n'
            'lookout\tblocked_change_fsevents\telapsed\t4504\tms\n'
            'lookout\tblocked_change_fsevents\tbudget\t500\tms\n'
            'lookout\tblocked_change_fsevents\twithin_budget\t0\tbool\n'
            'lookout\tblocked_change_kqueue\telapsed\t1\tms\n'
            'lookout\tblocked_change_kqueue\tbudget\t500\tms\n'
            'lookout\tblocked_change_kqueue\twithin_budget\t1\tbool\n'
            'FAIL (TestUnexpectedResult)\n'
            '2/2 speed_claims.test.quiet: a watcher can be woken...lookout\twake_fsevents\telapsed\t107\tms\n'
            'lookout\twake_fsevents\tbudget\t5000\tms\n'
            'lookout\twake_fsevents\twithin_budget\t1\tbool\n'
            'OK\n'
            '1 passed; 0 skipped; 1 failed.\n')
    WITHIN = ('1/1 speed_claims.test.quiet: a change...lookout\tblocked_change_fsevents\telapsed\t90\tms\n'
              'lookout\tblocked_change_fsevents\tbudget\t500\tms\n'
              'lookout\tblocked_change_fsevents\twithin_budget\t1\tbool\n'
              'OK\nAll 1 tests passed.\n')

    def test_an_over_budget_speed_check_is_a_failed_row_and_the_pass_goes_on(self):
        with tempfile.TemporaryDirectory() as name:
            p = self.make_pass(False, Path(name))
            calls = []
            def command(args, judged=False, **kwargs):
                self.assertTrue(judged)
                calls.append(args[0])
                return ('', self.OVER, 1) if len(calls) == 1 else ('', self.WITHIN, 0)
            p.command = command
            p.group('backend-speed-checks', [('before', ['A']), ('after', ['B'])], parser='test', warmup=False)
            # every trial of every side still ran, and every measurement was kept
            self.assertEqual(calls, ['A', 'B', 'A', 'B'])
            self.assertEqual([s['status'] for s in p.data['samples']], ['failed', 'passed', 'passed', 'passed'])
            failed = p.data['samples'][0]
            self.assertEqual({r['workload']: r['value'] for r in failed['metrics']},
                             {'blocked_change_fsevents': 4504, 'blocked_change_kqueue': 1, 'wake_fsevents': 107})
            self.assertEqual(p.data['failed_checks'], [
                {'job': 'backend-speed-checks', 'side': 'before', 'trial': 0,
                 'workload': 'blocked_change_fsevents', 'value': 4504, 'budget': 500, 'unit': 'ms', 'passed': False}])
            written = json.loads((p.results / 'results.json').read_text())
            self.assertEqual(written['failed_checks'], p.data['failed_checks'])
            self.assertIn('| backend-speed-checks | before | 0 | blocked_change_fsevents | 4504.0 | 500.0 | ms |',
                          (p.results / 'results.md').read_text())
            # the pass reports the failure, after the results, with a failing status
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                self.assertEqual(verdict(p.data, 'Timed pass', 'results/x'), 1)
            self.assertIn('blocked_change_fsevents 4504 ms (budget 500)', err.getvalue())
            self.assertEqual(out.getvalue(), '')
            p.data['failed_checks'] = []
            with redirect_stdout(out):
                self.assertEqual(verdict(p.data, 'Timed pass', 'results/x'), 0)

    def test_a_speed_check_that_breaks_rather_than_runs_slow_stops_the_pass(self):
        broken = [
            # an expectation other than a ceiling
            self.OVER.replace('FAIL (TestUnexpectedResult)', 'FAIL (EventNotObserved)'),
            # a failed test that reported nothing over its ceiling
            self.OVER.replace('within_budget\t0', 'within_budget\t1'),
            # a crash: no runner summary
            self.OVER.replace('1 passed; 0 skipped; 1 failed.\n', ''),
        ]
        for output in broken:
            with tempfile.TemporaryDirectory() as name:
                p = self.make_pass(False, Path(name))
                p.command = lambda args, judged=False, **kwargs: ('', output, 1)
                with redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
                    p.group('backend-speed-checks', [('before', ['A'])], parser='test', warmup=False)
                self.assertEqual(p.data['failed_checks'], [])
        with tempfile.TemporaryDirectory() as name:
            p = self.make_pass(False, Path(name))
            # a verdict over budget from a binary that exited cleanly
            p.command = lambda args, judged=False, **kwargs: ('', self.OVER.replace('1 failed', '0 failed'), 0)
            with self.assertRaises(RuntimeError):
                p.group('backend-speed-checks', [('before', ['A'])], parser='test', warmup=False)

    def test_unavailable_is_distinct_from_zero_and_bad_rows_fail(self):
        self.assertIsNone(parse_rows('tool\tjob\trate\tn/a\tlines/s\n')[0]['value'])
        self.assertEqual(parse_rows('tool\tjob\tmissed\t0\tfiles\n')[0]['value'], 0)
        for value in ('nan', 'inf', '-inf'):
            with self.assertRaises(RuntimeError):
                parse_rows(f'tool\tjob\trate\t{value}\tlines/s\n')
        with self.assertRaises(RuntimeError):
            parse_rows('malformed\trow\n')
        self.assertEqual(len(parse_rows('progress\ntool\tjob\telapsed\t1\tms\nOK\n', loose=True)), 1)
        self.assertEqual(parse_rows('tool\tjob\t4\tns\n', work=True)[0]['value'], 4)

    def test_pairs_use_the_same_trial_and_do_not_divide_by_zero(self):
        def sample(side, trial, value):
            return {'job': 'job', 'side': side, 'trial': trial, 'metrics':
                    [{'workload': 'work', 'metric': 'elapsed', 'unit': 'ns', 'value': value}]}
        values = [sample('before', 0, 4), sample('after', 0, 2),
                  sample('before', 1, 0), sample('after', 1, 9), sample('tool', 0, 300)]
        self.assertEqual(paired(values)[0]['median_after_over_before'], 0.5)
        self.assertEqual(paired(values)[0]['pairs'], 1)


if __name__ == '__main__':
    unittest.main()
