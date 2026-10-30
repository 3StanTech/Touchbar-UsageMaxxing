#!/usr/bin/env python3
"""Claude throttle contract through the real reader CLI and its own functions: 429 spacing
60/120/240/480/900 s, one level down per complete success, exit at level 0 after three
successes, manual taps (60 s floor, a refused tap never escalates), real Retry-After as the
only server backoff, the bounded episode tally, and legacy metadata repair.

Some boundaries age isolated metadata instead of waiting real minutes.
Run: USAGE_TEST_ROOT=<dir> python3 test_throttle.py --script <reader under root> --out <new dir under root>
"""
import argparse, hashlib, importlib.machinery, importlib.util, json, re, sys, time, traceback
from email.utils import formatdate
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixture_usage import Fixture, guard  # noqa: E402


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def clean(value):
    if isinstance(value, dict): return {k: clean(v) for k, v in value.items() if k not in ('auth', 'accessToken', 'access_token', 'account_id')}
    if isinstance(value, list): return [clean(v) for v in value]
    if isinstance(value, str): return re.sub(r"synthetic-(?:primary|codex)", "[synthetic credential]", re.sub(r"Bearer \S+", "Bearer [redacted]", value))
    return value


def save(path, value): Path(path).write_text(json.dumps(clean(value), indent=2))
def meta_path(f, provider='claude'): return f.cache / f'statusline-{provider}-weekly.json.refresh.json'
def meta(f, provider='claude'): return json.loads(meta_path(f, provider).read_text())


def seed(f, provider='claude', **changes):
    d = meta(f, provider); d.update(changes); meta_path(f, provider).write_text(json.dumps(d))


def age_attempt(f, provider='claude', by=61):
    """Metadata boundary: pretend the last attempt started `by` seconds earlier."""
    d = meta(f, provider); d['last_attempt_started_at'] = d['last_attempt_started_at'] - by
    for a in d.get('attempts') or []:  # the floor reads attempt history (latest start or finish)
        a['started_at'] -= by
        if 'completed_at' in a: a['completed_at'] -= by
    meta_path(f, provider).write_text(json.dumps(d))


def expire_gates(f, provider='claude'):
    """Metadata boundary: the reader's own spacing has elapsed (server deadlines untouched)."""
    cp = f.cache / f'statusline-{provider}-weekly.json'; d = json.loads(cp.read_text()); d['retry_at'] = time.time() - 1; cp.write_text(json.dumps(d))
    seed(f, provider, next_attempt_at=time.time() - 1, recovery_next_at=time.time() - 1)


def reqs(f, provider='claude'): return [r for r in f.requests if r['provider'] == provider]
def near(value, target, tol=3): return abs(value - target) <= tol


def load_reader():
    loader = importlib.machinery.SourceFileLoader('reader_under_test', str(SCRIPT))
    spec = importlib.util.spec_from_loader('reader_under_test', loader)
    module = importlib.util.module_from_spec(spec); loader.exec_module(module)
    return module


def fast(root):
    checks = []
    reader = load_reader()
    now = time.time()
    cases = {None: 0, '': 0, '0': 0, '0.0': 0, '-5': 0, 'nan': 0, 'inf': 0, 'soon': 0, '120': 120, '1.2': 2,
             formatdate(now - 60, usegmt=True): 0}
    for raw, want in cases.items():
        assert reader.retry_seconds(raw) == want, (raw, reader.retry_seconds(raw), want)
    future = reader.retry_seconds(formatdate(now + 300, usegmt=True)); assert 295 <= future <= 301, future
    assert [reader.recovery_spacing(n) for n in range(6)] == [60, 60, 120, 240, 480, 900]
    checks.append('retry_seconds: absent/0/past/invalid -> 0, real seconds/HTTP-date -> positive; spacing table 60/60/120/240/480/900')

    f = Fixture(SCRIPT, root, 'fast-fixture'); out = {}
    try:
        # Real Retry-After 120 blocks every caller, including manual, and says why.
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 120}]
        first = f.command('claude')['week']; m = meta(f)
        assert first['request']['attempted'] and first['fetch_error'] == 'rate_limited'
        assert near(m['server_retry_at'] - time.time(), 120), m
        rows = {r: f.command('claude', r)['week'] for r in ('manual', 'automatic', 'wake', 'provider-start')}
        age_attempt(f); rows['manual-after-floor'] = f.command('claude', 'manual')['week']
        assert len(reqs(f)) == 1, f.requests
        for name in ('manual', 'manual-after-floor'):
            q = rows[name]['request']; assert q['reason'] == 'manual' and not q['attempted'] and q['deferred_by'] == 'server_retry', q
            assert near(q['deferred_until'], m['server_retry_at'], .01), q
        assert rows['automatic']['request']['deferred_by'] == 'server_retry'
        out['retry_after_120'] = {'first': first['request'], 'deferred': {k: v['request'] for k, v in rows.items()}}
        checks.append('real Retry-After 120: manual/automatic/wake/provider-start make no request; manual reports deferred_by=server_retry until the server deadline (also after the 60 s floor)')

        # Retry-After 0 and absent are local spacing only: manual bypasses it after the 60 s floor.
        for label, retry in (('retry_after_0', 0), ('retry_after_absent', None)):
            f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': retry}, {}]
            first = f.command('claude')['week']; m = meta(f)
            assert 'server_retry_at' not in m and m['rate_limit_failures'] == 1 and m['recovery_state'] == 'recovering', m
            assert near(first['retry_at'] - time.time(), 60), first
            early = f.command('claude', 'manual')['week']['request']
            auto = f.command('claude')['week']['request']
            assert early['deferred_by'] == 'manual_floor' and near(early['deferred_until'], m['attempts'][-1]['completed_at'] + 60, .05), early
            assert not auto['attempted'] and auto['deferred_by'] is None, auto
            assert len(reqs(f)) == 1
            age_attempt(f)
            manual = f.command('claude', 'manual')['week']
            assert manual['request']['attempted'] and len(reqs(f)) == 2, (manual['request'], f.requests)
            taps = [f.command('claude', 'manual')['week']['request'] for _ in range(5)]
            assert len(reqs(f)) == 2 and all(t['deferred_by'] == 'manual_floor' for t in taps), taps
            m = meta(f)
            assert m['rate_limit_failures'] == 0 and m['recovery_successes'] == 1 and manual['request_interval_seconds'] == 60, m
            out[label] = {'first_retry_in': first['retry_at'] - time.time(), 'early_manual': early, 'manual': manual['request'], 'taps': taps}
        checks.append('Retry-After 0 / absent: no server_retry_at; automatic waits; manual inside the 60 s floor deferred (manual_floor); after the floor exactly one manual request; five rapid taps add none')

        # Escalation L1..L5 with cap, each step a real automatic 429 (spacing aged = metadata boundary).
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 0}] * 6
        levels = []
        slot = f.command('claude')['week']
        for i in range(6):
            m = meta(f); levels.append({'level': m['rate_limit_failures'], 'interval': slot['request_interval_seconds'], 'retry_in': slot['retry_at'] - time.time()})
            if i < 5: expire_gates(f); slot = f.command('claude')['week']
        assert [l['level'] for l in levels] == [1, 2, 3, 4, 5, 5], levels
        assert [l['interval'] for l in levels] == [60, 120, 240, 480, 900, 900], levels
        assert all(near(l['retry_in'], l['interval']) for l in levels), levels
        assert len(reqs(f)) == 6 and 'server_retry_at' not in meta(f)
        out['escalation'] = levels
        assert meta(f)['throttle_episodes'][-1]['refused'] == 6
        checks.append('automatic 429 escalation L1->L5 (60/120/240/480/900) with cap at 5; no server_retry_at; one episode tallies all 6 refusals')

        # A refused tap inside an episode neither escalates nor restarts the long spacing.
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 0}] * 3
        f.command('claude'); expire_gates(f); f.command('claude')
        due = meta(f)['recovery_next_at']; assert meta(f)['rate_limit_failures'] == 2 and near(due - time.time(), 120)
        age_attempt(f); slot = f.command('claude', 'manual')['week']; m = meta(f); now = time.time()
        assert slot['request']['attempted'] and m['rate_limit_failures'] == 2 and m['recovery_successes'] == 0, m
        assert near(slot['next_refresh_at'], max(due, now + 60), 2), (slot['next_refresh_at'] - now, due - now)
        ep = m['throttle_episodes'][-1]; assert (ep['refused'], ep['manual_refused'], ep.get('ended_at')) == (3, 1, None), ep
        expire_gates(f); f.sequence['claude'] = [{'status': 429, 'retry': 0}]; f.command('claude'); m = meta(f)
        assert m['rate_limit_failures'] == 3 and m['throttle_episodes'][-1]['refused'] == 4, m
        checks.append('refused tap inside an episode keeps level 2, resets successes, keeps the next request >=60 s away without restarting 120 s spacing; a later automatic 429 still escalates')
        f.reset(); f.command('claude'); seed(f, next_manual_at=time.time() - 1); f.sequence['claude'] = [{'status': 429, 'retry': 0}]
        f.command('claude', 'manual'); m = meta(f)
        assert m['rate_limit_failures'] == 1 and m['throttle_episodes'][-1]['manual_refused'] == 1, m
        checks.append('a 429 from a tap while healthy opens the episode at level 1')
        f.reset(); f.command('claude'); f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=0, recovery_successes=2, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1,
             throttle_episodes=[{'started_at': time.time() - 600, 'refused': 2, 'manual_refused': 0}])
        f.command('claude'); m = meta(f); ep = m['throttle_episodes'][-1]
        assert 'recovery_state' not in m and near(ep['duration_seconds'], 600) and ep['ended_at'] > 0, m
        seed(f, recovery_state='recovering', rate_limit_failures=3, recovery_successes=0, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1,
             throttle_episodes=[{'started_at': 1, 'ended_at': 2, 'refused': 1, 'manual_refused': 0}] * 120)
        f.sequence['claude'] = [{'status': 429, 'retry': 0}]; f.advance(age=1000); f.command('claude'); m = meta(f)
        assert len(m['throttle_episodes']) == 100 and m['throttle_episodes'][-1].get('started_before_tally') is True, m['throttle_episodes'][-1]
        checks.append('episode tally: exit closes the episode with duration; history bounded to 100; an episode already running before the tally is marked started_before_tally')
        # Slow refusals, pre-tally recovery and malformed tally rows.
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 0, 'delay': 1.2}]; f.command('claude'); f.sequence['claude'] = [{'status': 429, 'retry': 0}]
        d = meta(f); a = d['attempts'][-1]; assert a['completed_at'] - a['started_at'] >= 1.1, a
        # Start well past the floor, completion well inside it: the floor must count from completion.
        a['started_at'] -= 70; a['completed_at'] -= 50
        d['last_attempt_started_at'] -= 70; meta_path(f).write_text(json.dumps(d))
        q = f.command('claude', 'manual')['week']['request']; assert q['deferred_by'] == 'manual_floor' and near(q['deferred_until'], a['completed_at'] + 60, .05), q
        checks.append('the tap floor counts from the end of a slow refused request, never <60 s after a refusal')
        f.reset(); f.sequence['claude'] = []; f.command('claude'); f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=0, recovery_successes=2, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1)
        f.command('claude'); m = meta(f); ep = m['throttle_episodes'][-1]
        assert 'recovery_state' not in m and ep.get('started_before_tally') is True and ep['ended_at'] > 0 and 'duration_seconds' not in ep, m
        checks.append('a pre-tally recovery that exits without another 429 is still recorded (start unknown)')
        f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=0, recovery_successes=2, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1,
             throttle_episodes=[{}, 'x', {'started_at': -5, 'refused': 3}, {'started_at': time.time() + 500, 'ended_at': time.time(), 'refused': -4}]
                               + [{'started_at': 1, 'ended_at': 2, 'refused': 1}] * 120 + [{'started_at': time.time() - 300, 'refused': 2, 'manual_refused': -1}])
        f.command('claude'); rows = meta(f)['throttle_episodes']
        assert len(rows) == 100 and all(r['refused'] >= 0 and r['manual_refused'] >= 0 for r in rows), rows[-1]
        assert rows[-1]['manual_refused'] == 0 and near(rows[-1]['duration_seconds'], 300) and all(r.get('started_at', 1) > 0 for r in rows)
        checks.append('malformed tally rows dropped or normalized (no negative counts or durations); bound 100 enforced on close')
        f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=0, recovery_successes=2, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1,
             throttle_episodes=[{'started_at': time.time() + 1000, 'refused': 1}])
        f.command('claude'); ep = meta(f)['throttle_episodes'][-1]
        assert ep['ended_at'] > 0 and 'duration_seconds' not in ep, ep
        checks.append('closing an open row with a future start writes no negative duration')

        # Persisted-state migration from a real earlier shape {level 5, successes 1}.
        f.reset(); f.command('claude'); f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=5, recovery_successes=1, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1)
        before = f.command('claude', only=True)['week']
        assert before['recovery_state'] == 'recovering' and before['recovery_successes'] == 1 and before['request_interval_seconds'] == 900, before
        after = f.command('claude')['week']; m = meta(f)
        assert after['request']['attempted'] and m['rate_limit_failures'] == 4 and m['recovery_successes'] == 2, m
        assert after['request_interval_seconds'] == 480 and near(after['next_refresh_at'] - time.time(), 480), after
        out['migration'] = {'before_interval': before['request_interval_seconds'], 'after_level': 4, 'after_interval': 480}
        checks.append('live persisted shape {level 5, successes 1} loads and decays to level 4 (480 s) on one success')

        # A 429 mid-decay re-escalates from the current level.
        f.reset(); f.command('claude'); f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=3, recovery_successes=2, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1)
        f.sequence['claude'] = [{'status': 429, 'retry': 0}]
        slot = f.command('claude')['week']; m = meta(f)
        assert m['rate_limit_failures'] == 4 and m['recovery_successes'] == 0 and slot['request_interval_seconds'] == 480, m
        checks.append('429 at level 3 mid-decay re-escalates to level 4 (480 s) and resets successes')

        # Partial success keeps the level and resets successes; malformed metadata loads conservatively.
        f.reset(); f.command('claude'); f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=2, recovery_successes=1, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1)
        f.sequence['claude'] = [{'partial': 'seven_day'}]
        slot = f.command('claude')['week']; m = meta(f)
        assert m['rate_limit_failures'] == 2 and m['recovery_successes'] == 0 and slot['diagnostics']['current_failure'] == 'partial_response', m
        seed(f, recovery_successes=999, rate_limit_failures='bad')
        slot = f.command('claude', only=True)['week']
        assert slot['recovery_successes'] == 0 and slot['request_interval_seconds'] == 900 and slot['request']['reason'] == 'cache-only', slot
        seed(f, recovery_successes=2, rate_limit_failures=0)
        slot = f.command('claude', only=True)['week']; assert slot['recovery_state'] == 'recovering' and slot['request_interval_seconds'] == 60, slot
        checks.append('partial response keeps level and resets successes; malformed level/successes load as level 5 / 0; level 0 is valid')

        # Legacy metadata written by readers before the current throttle contract.
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 0}]; f.command('claude')
        d = meta(f); d.pop('last_attempt_started_at'); d['server_retry_at'] = time.time() + 830
        meta_path(f).write_text(json.dumps(d))
        q = f.command('claude', 'manual')['week']['request']
        assert q['deferred_by'] == 'manual_floor' and near(q['deferred_until'], d['attempts'][-1]['completed_at'] + 60, .05), q
        d = meta(f); d['attempts'][-1]['started_at'] -= 61; d['attempts'][-1]['completed_at'] -= 61; meta_path(f).write_text(json.dumps(d))
        q = f.command('claude', 'manual')['week']['request']
        assert q['attempted'] and 'server_retry_at' not in meta(f), (q, meta(f))
        checks.append('legacy server_retry_at written from local spacing (latest 429 asked Retry-After 0) is dropped; missing last_attempt_started_at falls back to attempt history for the 60 s floor')
        # Deadlines this reader marked are kept; legacy ones are rebuilt from the recorded Retry-After.
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 0}]; f.command('claude')
        d = meta(f); d.update(server_retry_at=time.time() + 300, server_retry_basis='retry_after'); d['attempts'][-1]['started_at'] -= 61
        d['last_attempt_started_at'] -= 61; meta_path(f).write_text(json.dumps(d))
        q = f.command('claude', 'manual')['week']['request']; assert q['deferred_by'] == 'server_retry' and len(reqs(f)) == 1, q
        for age, want in ((130, 'attempted'), (10, 'server_retry')):
            f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 120}]; f.command('claude')
            d = meta(f); a = d['attempts'][-1]; a['started_at'] -= age; a['completed_at'] -= age; d['last_attempt_started_at'] -= age
            d.pop('server_retry_basis'); d['server_retry_at'] = a['completed_at'] + 900; meta_path(f).write_text(json.dumps(d))
            q = f.command('claude', 'manual')['week']['request']
            if want == 'attempted': assert q['attempted'], q
            else: assert q['deferred_by'] == 'server_retry' and near(q['deferred_until'], a['completed_at'] + 120, .01), q
        checks.append('marked server deadlines are never rebuilt; a legacy deadline inflated to 900 s after Retry-After 120 is cut back to completion+120 (blocks at 10 s, allows at 130 s)')
        f.reset(); f.sequence['claude'] = [{'status': 429, 'retry': 10}]; f.command('claude')
        q = f.command('claude', 'manual')['week']['request']; m = meta(f)
        assert q['deferred_by'] == 'manual_floor' and near(q['deferred_until'], m['attempts'][-1]['completed_at'] + 60, .05), q
        checks.append('server Retry-After 10 inside the 60 s floor reports the later deadline (manual_floor) instead of premature eligibility')
        f.reset(); f.command('claude'); f.advance(age=1000)
        seed(f, recovery_state='recovering', rate_limit_failures=1, recovery_successes=6, recovery_next_at=time.time() - 1, next_attempt_at=time.time() - 1)
        assert f.command('claude', only=True)['week']['recovery_successes'] == 6
        f.command('claude'); m = meta(f); assert 'recovery_state' not in m and 'rate_limit_failures' not in m, m
        checks.append('migrated {level 5, successes 2} path: reachable count 6 at level 1 is kept and the next success exits recovery')

        # Codex: independent, same server/local split, no Claude recovery state.
        f.reset(); f.sequence['codex'] = [{'status': 429, 'retry': 0}]
        c = f.command('codex')['codex']; m = meta(f, 'codex')
        assert c['recovery_state'] == 'normal' and 'server_retry_at' not in m and near(c['retry_at'] - time.time(), 60), (c, m)
        q = f.command('codex', 'manual')['codex']['request']; assert q['deferred_by'] == 'manual_floor', q
        f.sequence['codex'] = [{'status': 429, 'retry': 120}]; age_attempt(f, 'codex')
        f.command('codex', 'manual'); m = meta(f, 'codex'); assert near(m['server_retry_at'] - time.time(), 120), m
        age_attempt(f, 'codex'); q = f.command('codex', 'manual')['codex']['request']
        assert q['deferred_by'] == 'server_retry' and len(reqs(f, 'codex')) == 2 and not reqs(f), (q, f.requests)
        checks.append('Codex: 429 Retry-After 0 is local 60 s (manual floor applies), Retry-After 120 is server authority; no Claude requests or recovery state')
        save(root / 'fast-trace.json', {'requests': f.requests, 'out': out})
    finally:
        f.close()
    return {'checks': checks}



if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--script', required=True); p.add_argument('--out', required=True); a = p.parse_args()
    SCRIPT = guard(a.script); OUT = guard(a.out)
    OUT.mkdir(parents=True, exist_ok=False)
    report = {'reader_sha256': sha(SCRIPT), 'limits': ['synthetic loopback fixtures; no live provider readiness claim']}
    code = 0
    try:
        report['checks'] = fast(OUT / 'fast'); report['result'] = 'pass'; print('throttle: pass', flush=True)
    except Exception as exc:
        report.update(result='fail', error=str(exc), traceback=traceback.format_exc()); code = 1; print(clean(report['traceback']), flush=True)
    finally:
        save(OUT / 'result.json', report)
    sys.exit(code)
