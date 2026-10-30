#!/usr/bin/env python3
"""Request log and throttle-episode success count, through the real reader CLI.

Run: USAGE_TEST_ROOT=<dir> python3 test_request_log.py --script <reader under root> --out <dir under root>
Synthetic loopback fixtures only.
"""
import argparse, importlib.machinery, importlib.util, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixture_usage import Fixture, guard  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument('--script', required=True)
p.add_argument('--out', required=True)
a = p.parse_args()
out = guard(a.out)
out.mkdir(parents=True, exist_ok=True)
results = []


def check(name, condition, detail=None):
    results.append({'case': name, 'result': 'pass' if condition else 'fail', **({'detail': detail} if not condition and detail is not None else {})})


def rows(f, provider='claude'):
    path = f.cache / f'statusline-{provider}-requests.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def meta(f, provider='claude'):
    return json.loads((f.cache / f'statusline-{provider}-weekly.json.refresh.json').read_text())


def due(f, provider='claude'):
    """Metadata boundary: every local gate has elapsed (no real Retry-After is used here)."""
    m = meta(f, provider)
    for key in ('next_attempt_at', 'next_manual_at', 'recovery_next_at'):
        if key in m: m[key] = time.time() - 1
    m['last_attempt_started_at'] = time.time() - 120
    for attempt in m.get('attempts') or []:
        attempt['started_at'] = attempt.get('started_at', 0) - 120
        if 'completed_at' in attempt: attempt['completed_at'] -= 120
    (f.cache / f'statusline-{provider}-weekly.json.refresh.json').write_text(json.dumps(m))
    cache = f.cache / f'statusline-{provider}-weekly.json'
    if cache.exists():
        d = json.loads(cache.read_text())
        if 'retry_at' in d: d['retry_at'] = time.time() - 1
        for key in ('fetched_at', 'five_hour_fetched_at', 'seven_day_fetched_at'):
            if key in d: d[key] = time.time() - 70
        cache.write_text(json.dumps(d))


f = Fixture(guard(a.script), out, 'request-log-fixture')
ACCOUNT = 'synthetic-account-7731'
f.cfg['codex_auth']['account_id'] = ACCOUNT; f.config.write_text(json.dumps(f.cfg))
try:
    # Healthy automatic acquisition for both providers, then an immediate deferral.
    f.command()
    claude, codex = rows(f), rows(f, 'codex')
    first = claude[0] if claude else {}
    check('touchbar attempt logged per provider', len(claude) == 1 and len(codex) == 1, [claude, codex])
    check('attempt row fields', first.get('caller') == 'touchbar' and first.get('attempted') is True and first.get('http_status') == 200
          and first.get('outcome') == 'success' and first.get('reason') == 'automatic' and first.get('level') == 0
          and first.get('recovery_state') == 'normal' and first.get('five_hour_age_s') is not None and first.get('five_hour_age_s') < 5, first)
    check('no desktop process scan in test mode', 'desktop_code_running' not in first, first)
    f.command('claude')
    claude = rows(f)
    check('touchbar deferral logged with its deadline', len(claude) == 2 and claude[1]['attempted'] is False
          and claude[1]['deferred_until'] and claude[1]['deferred_until'] > time.time(), claude[-1:])

    # Alternating refusals and successes: the episode records both.
    f.sequence['claude'] = [{'status': 429, 'retry': 0}, {}, {'status': 429, 'retry': 0}, {}, {}, {}]
    for step in range(6):
        due(f)
        f.command('claude')
        if step == 0:
            spacing = meta(f)['next_attempt_at'] - time.time()
            check('429 spacing unchanged (60 s at level 1)', 50 <= spacing <= 65, spacing)
    episode = meta(f)['throttle_episodes'][-1]
    check('episode counts refusals and successes', episode.get('refused') == 2 and episode.get('successes') == 4 and episode.get('ended_at'), episode)
    attempts = [r for r in rows(f) if r['attempted']]
    refused = [r for r in attempts if r.get('http_status') == 429]
    check('refused attempts logged with status, level and reason', len(refused) == 2 and all(r['outcome'] == 'rate_limited' and r['level'] == 1 for r in refused), refused)
    check('recovery state follows the episode', [r['recovery_state'] for r in attempts[-6:]] == ['recovering'] * 5 + ['normal'], [r['recovery_state'] for r in attempts[-6:]])

    # A manual tap is logged as manual.
    due(f)
    f.command('claude', 'manual')
    check('manual tap logged', rows(f)[-1].get('reason') == 'manual' and rows(f)[-1]['attempted'], rows(f)[-1])

    # A terminal status line logs attempts only.
    f.cfg['caller'] = 'statusline'; f.config.write_text(json.dumps(f.cfg))
    before = len(rows(f))
    f.command('claude')
    check('terminal deferral not logged', len(rows(f)) == before, rows(f)[before:])
    due(f)
    f.command('claude')
    check('terminal attempt logged as statusline', len(rows(f)) == before + 1 and rows(f)[-1]['caller'] == 'statusline' and rows(f)[-1]['attempted'], rows(f)[-1:])
    f.cfg.pop('caller'); f.config.write_text(json.dumps(f.cfg))

    # Secrets never reach the logs.
    text = ''.join(path.read_text() for path in f.cache.glob('*-requests.jsonl*'))
    check('no credentials or account in logs', not any(word in text for word in ('synthetic-primary', 'synthetic-codex', 'Bearer', ACCOUNT)), None)

    # Rotation keeps exactly one older file.
    f.cfg['request_log_max_bytes'] = 600; f.config.write_text(json.dumps(f.cfg))
    for _ in range(8): f.command('claude')
    log = f.cache / 'statusline-claude-requests.jsonl'
    rotated = sorted(p.name for p in f.cache.glob('statusline-claude-requests.jsonl.*') if not p.name.endswith('.lock'))
    check('rotation keeps one older file', rotated == ['statusline-claude-requests.jsonl.1'] and log.stat().st_size <= 600 + 600, rotated)
    f.cfg.pop('request_log_max_bytes'); f.config.write_text(json.dumps(f.cfg))

    # An unwritable log never changes the reading.
    for path in f.cache.glob('statusline-codex-requests.jsonl*'): path.unlink()
    (f.cache / 'statusline-codex-requests.jsonl').mkdir()
    due(f, 'codex')
    f.rows['codex'] = (33, 50)
    before = f.count['codex']
    card = f.command('codex')
    check('unwritable log leaves a fresh reading intact', card['codex']['five_hour']['pct'] == 33 and f.count['codex'] == before + 1
          and card['codex'].get('error') is None, [card['codex'], f.count['codex'] - before])
finally:
    f.close()

# Production caller selection is a pure rule: only the Touch Bar's slots format counts as the
# Touch Bar. Tested by importing the reader (the CLI cases above use the test-mode override,
# because test isolation is only available with --format slots).
loader = importlib.machinery.SourceFileLoader('reader_under_test', str(a.script))
spec = importlib.util.spec_from_loader('reader_under_test', loader)
reader = importlib.util.module_from_spec(spec); loader.exec_module(reader)
check('caller selection: slots is the Touch Bar, every other format a terminal status line',
      reader.caller_for('slots') == 'touchbar' and all(reader.caller_for(fmt) == 'statusline' for fmt in ('tui', 'plain', 'btt', 'ansi')),
      {fmt: reader.caller_for(fmt) for fmt in ('slots', 'tui', 'plain', 'btt', 'ansi')})

(out / 'request-log-results.json').write_text(json.dumps({'checks': results}, indent=2))
failed = [r for r in results if r['result'] != 'pass']
print(f'request log: {len(results) - len(failed)}/{len(results)} passed')
for r in failed: print('FAIL', json.dumps(r))
sys.exit(1 if failed else 0)
