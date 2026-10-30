#!/usr/bin/env python3
"""Window identity and reset validation through the real reader CLI: Codex windows are
placed by their duration (never by primary/secondary position), and an invalid or ended
reset never overwrites a useful cached window or its provenance.

Run: USAGE_TEST_ROOT=<dir> python3 test_reader_windows.py --script <reader under root> --out <dir under root>
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixture_usage import Fixture, guard  # noqa: E402

CHECKS = []


def passed(name):
    CHECKS.append({'case': name, 'result': 'pass'})


def body(windows):
    return {'rate_limit': dict(zip(('primary_window', 'secondary_window'), windows))}


def codex_window(duration, pct=21, reset=None):
    window = {'used_percent': pct, 'reset_at': time.time() + 3600 if reset is None else reset}
    if duration != 'missing':
        window['limit_window_seconds'] = duration
    return window


def windows():
    f = Fixture(SCRIPT, OUT, 'windows-fixture')
    try:
        for durations in [(18000, 604800), (604800, 18000), (18000,), (604800,),
                          (900, 86400), ('missing',), (True,), (18000.9,),
                          ('18000',), (float('inf'),), (10**400,)]:
            f.reset()
            windows = [codex_window(duration, pct=21+i) for i, duration in enumerate(durations)]
            f.sequence['codex'] = [{'raw': json.dumps(body(windows))}]
            row = f.command('codex')['codex']
            for duration, slot in [(18000, 'five_hour'), (604800, 'seven_day')]:
                expected = next((21+i for i, value in enumerate(durations)
                                 if value == duration or value == str(duration)), None)
                assert row[slot]['pct'] == expected, (durations, row)
                assert row[slot]['is_fresh'] == (expected is not None)
            passed('Codex duration identity: ' + str(durations))

        # Every malformed/reset boundary is run against the actual provider CLI.
        for provider, key in [('claude', 'week'), ('codex', 'codex')]:
            invalids = ['invalid-reset', None, float('nan'), float('inf'), 10**400,
                        True, time.time()-1, '2020-01-01T00:00:00Z']
            for index, reset in enumerate(invalids):
                f.reset()
                prior = f.command(provider)[key]
                f.advance(provider)
                before = f.command(provider, only=True)[key]['five_hour']
                if provider == 'claude':
                    payload = {'five_hour': {'utilization': 99, 'resets_at': reset},
                               'seven_day': {'utilization': 51, 'resets_at': f.ends[provider][1]}}
                else:
                    payload = body([{'used_percent': 99, 'limit_window_seconds': 18000, 'reset_at': reset},
                                    codex_window(604800, 51, f.ends[provider][1])])
                f.sequence[provider] = [{'raw': json.dumps(payload)}]
                row = f.command(provider, 'manual')[key]
                for field in ('pct', 'resets_at', 'fetched_at', 'observed_at', 'freshness_basis', 'reading_source'):
                    assert row['five_hour'][field] == before[field], (provider, index, field, row)
                assert row['seven_day']['pct'] == 51 and row['seven_day']['is_fresh']
                assert row['diagnostics']['current_failure'] == 'partial_response'
                assert row['five_hour']['pct'] == prior['five_hour']['pct']
                passed(f'{provider}: invalid reset boundary {index} retains old provenance; peer updates')

        f.reset()
        prior = f.command('claude')['week']['five_hour']
        f.command('codex', payload={'rate_limits': {'five_hour': {'utilization': 99, 'resets_at': 'bad'}}})
        current = f.command('claude', only=True)['week']['five_hour']
        assert all(current[k] == prior[k] for k in ('pct', 'resets_at', 'fetched_at', 'freshness_basis'))
        passed('Malformed Claude native receipt cannot overwrite a valid API window')
    finally:
        f.close()



if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--script', required=True); p.add_argument('--out', required=True); a = p.parse_args()
    SCRIPT, OUT = guard(a.script), guard(a.out)
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        windows()
    except AssertionError as exc:
        print('FAIL:', repr(exc)[:2000]); sys.exit(1)
    finally:
        (OUT / 'windows-results.json').write_text(json.dumps(CHECKS, indent=2) + '\n')
    print(f'reader windows: {len(CHECKS)} passed')
