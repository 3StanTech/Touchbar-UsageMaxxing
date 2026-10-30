#!/usr/bin/env python3
"""App rules through the real built verification executable (no Touch Bar or GUI needed):
limit-notification eligibility and its restart ledger, monitoring-gap warnings, and the
Touch Bar health label and menu line for each reader state.

Run: USAGE_TEST_ROOT=<dir> python3 test_app_rules.py --app <verification .app under root> --out <dir under root>
"""
import argparse, json, plistlib, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixture_usage import guard  # noqa: E402

p = argparse.ArgumentParser(); p.add_argument('--app', required=True); p.add_argument('--out', required=True); a = p.parse_args()
APP, OUT = guard(a.app), guard(a.out)
OUT.mkdir(parents=True, exist_ok=True)
assert plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == 'local.agents.usagetouchbar.provider-verification', 'verification bundle required'
EXE = APP / 'Contents/MacOS/UsageTouchBar'
results = []


def check(name, condition, detail=None):
    results.append({'case': name, 'result': 'pass' if condition else 'fail', **({'detail': detail} if not condition else {})})


def run(flag, data, tag):
    root = OUT / tag; root.mkdir(parents=True, exist_ok=True)
    inp, out = root / 'input.json', root / 'output.json'
    inp.write_text(json.dumps(data))
    r = subprocess.run([str(EXE), '--' + flag, str(inp), str(out)], capture_output=True, text=True, timeout=20)
    return r, (json.loads(out.read_text()) if r.returncode == 0 else None)


# Limit notifications: 90 % five-hour / 98 % weekly from fresh measured readings only.
now = time.time(); cases = []; expected = []; counter = 0


def add(name, expected_schedule=True, expected_eligible=None, **changes):
    global counter
    counter += 1
    window = {'provider': 'claude', 'kind': 'five_hour', 'percent': 90, 'reset': now + 3600 + counter, 'acquired': now, 'basis': 'api_acquisition', 'interval': 30, 'fresh': True}
    window.update(changes)
    cases.append({'case': name, 'now': now, 'window': window})
    expected.append((expected_schedule, expected_schedule if expected_eligible is None else expected_eligible))


for provider in ['claude', 'codex']:
    for kind, values in [('five_hour', [87.99, 88, 89.99, 90, 100]), ('seven_day', [96.99, 97, 97.99, 98, 100])]:
        for pct in values: add(f'{provider}/{kind}/{pct}', pct >= (90 if kind == 'five_hour' else 98), provider=provider, kind=kind, percent=pct)
reset = now + 7200
add('high startup/jump', reset=reset); add('restart persisted dedup', False, True, reset=reset)
add('independent weekly window', kind='seven_day', percent=98, reset=reset); add('independent other provider', provider='codex', reset=reset)
add('new five-hour reset', reset=reset + 1)
for status, name in [(0, 'permission undetermined'), (1, 'permission denied'), (2, 'authorized'), (3, 'provisional')]:
    add(name, status in (2, 3), True); cases[-1]['authorization'] = status
for name, changes in [('stale', {'fresh': False}), ('age exceeds fast allowance', {'acquired': now - 36}), ('age exceeds normal allowance', {'acquired': now - 66, 'interval': 60}),
                      ('future', {'acquired': now + 1}), ('unknown native age', {'acquired': None, 'basis': 'unverified_native_receipt'}), ('reset missing', {'reset': None}),
                      ('window ended', {'reset': now}), ('unknown percentage', {'percent': None}), ('unknown source', {'basis': 'unknown'}), ('invalid provider', {'provider': 'other'})]:
    add(name, False, **changes)
add('fast freshness boundary', acquired=now - 35); add('normal freshness boundary', interval=60, acquired=now - 65)
r, actual = run('notification-rules', {'cases': cases}, 'notification-rules')
ok = actual is not None and [row['case'] for row in actual] == [c['case'] for c in cases]
for row, (schedule, eligible) in zip(actual or [], expected):
    ok = ok and row['schedules'] == schedule and row['eligible'] == eligible
check(f'limit notification rules ({len(cases)} cases)', ok, r.stderr or actual)
(OUT / 'notification-rules/rules-ledger.json').write_text('{corrupt')
r, _ = run('notification-rules', {'cases': cases}, 'notification-rules')
check('corrupt notification ledger fails closed', r.returncode != 0, r.returncode)

# Monitoring-gap warnings: three active minutes without fresh data near a limit, once per outage.
base = {'provider': 'claude', 'kind': 'five_hour', 'percent': 88, 'reset': now + 3600, 'acquired': now - 180, 'basis': 'api_acquisition', 'interval': 30, 'fresh': False}
cases, expected = [], []


def gap(name, scheduled, windows=None, **changes):
    row = {'case': name, 'now': now, 'active_age': 180, 'authorized': True, 'windows': windows or []}
    row.update(changes); cases.append(row); expected.append(scheduled)


gap('179.999 active grace', 0, [base], active_age=179.999)
gap('denied permission', 0, authorized=False)
gap('idle cancels warning', 0, active_age=None)
gap('180 boundary sends one', 1)
gap('restart/permission/focus preserve sent', 0)
gap('same acquisition replay', 0, [base])
gap('partial other window does not recover five', 0, [dict(base, kind='seven_day', percent=20, acquired=now)])
gap('future acquisition rejected', 0, [dict(base, percent=1, acquired=now + 1)])
gap('native update does not erase evidence', 0, [dict(base, percent=1, basis='unverified_native_receipt', acquired=None)])
gap('low trusted acquisition closes episode', 0, [dict(base, percent=10, acquired=now)])
gap('later near reading gets new outage', 1, [dict(base, acquired=now + 1)], now=now + 181)
r, rows = run('monitoring-rules', {'seed': {'version': 1, 'scheduled': {'usage-limit.claude.five_hour.legacy': now}}, 'cases': cases}, 'monitoring-episode')
ok = rows is not None and [row['case'] for row in rows] == [c['case'] for c in cases] and all(len(row['scheduled']) == n for row, n in zip(rows, expected))
ok = ok and all('usage-limit.claude.five_hour.legacy' in row['ledger']['scheduled'] for row in rows) and rows[3]['scheduled'] != rows[-1]['scheduled']
check(f'monitoring episode rules ({len(cases)} cases)', ok, r.stderr or rows)
count = 0
for provider in ['claude', 'codex']:
    for kind, threshold in [('five_hour', 88), ('seven_day', 97)]:
        for name, changes, n in [('below', {'percent': threshold - .01}, 0), ('threshold', {'percent': threshold}, 1), ('179.999 reading', {'acquired': now - 179.999}, 0),
                                 ('missing reset', {'reset': None}, 0), ('expired reset', {'reset': now}, 0), ('future reading', {'acquired': now + 1}, 0), ('missing reading', {'acquired': None}, 0)]:
            win = dict(base, provider=provider, kind=kind, percent=threshold); win.update(changes)
            r, rows = run('monitoring-rules', {'seed': {'version': 1, 'scheduled': {}}, 'cases': [{'case': name, 'now': now, 'active_age': 180, 'authorized': True, 'windows': [win]}]}, f'monitoring-{provider}-{kind}-{count}')
            check(f'monitoring boundary {provider}/{kind}/{name}', rows is not None and len(rows) == 1 and rows[0]['case'] == name and len(rows[0]['scheduled']) == n, r.stderr or rows)
            count += 1


# Health labels: what the strip and menu say for each reader state.
def meter(pct, age, fresh=True):
    return {'pct': pct, 'end': '', 'color': '48,209,88', 'fetched_at': now - age, 'observed_at': now - age, 'freshness_basis': 'api_acquisition', 'is_fresh': fresh}


def card(failure=None, age=10, fresh=True, **extra):
    row = {'name': 'Claude', 'five_hour': meter(40, age, fresh), 'seven_day': meter(20, age, fresh), 'fetched_at': now - age, 'poll_interval_seconds': 60,
           'next_refresh_at': now + 50, 'diagnostics': {'current_failure': failure} if failure else {}}
    if failure: row.update(error='usage_unavailable', fetch_error=failure)
    row.update(extra); return row


labels = [
    ('healthy', card(), None, 'up to date'),
    ('sign-in expired', card('sign_in_expired', 700, False), 'Sign in', 'usage reader credential expired'),
    ('sign-in missing', card('sign_in_required', 700, False), 'Sign in', 'usage reader credential unavailable'),
    ('throttled, 4 min 5 s to the next attempt', card('rate_limited', 400, False, retry_at=now + 245, next_refresh_at=now + 245), 'Wait 5m', 'usage endpoint throttled'),
    ('throttled, exactly 4 min left', card('rate_limited', 400, False, retry_at=now + 240, next_refresh_at=now + 240), 'Wait 4m', 'usage endpoint throttled'),
    ('throttled, under a minute left', card('rate_limited', 400, False, retry_at=now + 45, next_refresh_at=now + 45), 'Wait 1m', 'usage endpoint throttled'),
    ('throttled, server asks 90 min', card('rate_limited', 400, False, retry_at=now + 5400, next_refresh_at=now + 60), 'Wait 1h 30m', 'usage endpoint throttled'),
    ('throttled, 59 min 1 s rounds up to the hour', card('rate_limited', 400, False, retry_at=now + 3541, next_refresh_at=now + 60), 'Wait 1h 00m', 'usage endpoint throttled'),
    ('throttled, 90 min 1 s rounds up', card('rate_limited', 400, False, retry_at=now + 5401, next_refresh_at=now + 60), 'Wait 1h 31m', 'usage endpoint throttled'),
    ('throttled, deadline passed', card('rate_limited', 400, False, retry_at=now - 5, next_refresh_at=now - 5), 'Wait', 'usage endpoint throttled'),
    ('access denied', card('access_denied', 700, False), 'Access denied', 'usage access denied'),
    ('stale without failure', card(None, 720, False), '↻ 12m', 'waiting for fresh usage'),
] + [(f'{failure}, cached reading kept', card(failure, 700, False), '↻ 11m', text) for failure, text in [
    ('transport_timeout', 'usage request timed out; retained reading'), ('renewal_transport_timeout', 'usage request timed out; retained reading'),
    ('malformed_response', 'usage response incomplete or invalid'), ('renewal_malformed_response', 'usage response incomplete or invalid'),
    ('partial_response', 'usage response incomplete or invalid'), ('operation_timeout', 'usage read timed out; result uncertain'),
    ('budget_timeout', 'usage read timed out; result uncertain'), ('app_timeout', 'usage read timed out; result uncertain'),
    ('network_error', 'connection failed; retrying'), ('usage_unavailable', 'usage unavailable; retrying')]] + [
    ('network error, no cached reading', dict(card('network_error'), five_hour={}, seven_day={}), '↻', 'connection failed; retrying')]
r, rows = run('health-labels', {'cases': [{'case': n, 'now': now, 'card': c} for n, c, _, _ in labels]}, 'health-labels')
check('health labels: one result per case, in order', rows is not None and [row['case'] for row in rows] == [n for n, _, _, _ in labels], r.stderr or rows)
for (name, _, label, text), row in zip(labels, rows or [{}] * len(labels)):
    check(f'health label: {name}', row.get('label') == label and text in (row.get('description') or ''), r.stderr or row)

(OUT / 'app-rules-results.json').write_text(json.dumps({'checks': results}, indent=2))
failed = [x for x in results if x['result'] != 'pass']
print(f'app rules: {len(results) - len(failed)}/{len(results)} passed')
for x in failed: print('FAIL', json.dumps(x)[:600])
sys.exit(1 if failed else 0)
