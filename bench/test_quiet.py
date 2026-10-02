"""Check the pass protocol with invented output; never run timed jobs."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from quiet import Pass, paired, parse_rows


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
