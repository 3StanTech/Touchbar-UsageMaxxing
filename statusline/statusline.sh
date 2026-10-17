#!/usr/bin/env python3
"""Shared status line for Grok Build, Claude Code, and the Usage Touch Bar.

Grok weekly percent is not on stdin. Fetch GET /v1/billing?format=credits
(with include=usage) on a cache miss, an expired week, or a refresh tick.
Claude 5h/7d prefer stdin rate_limits, then the OAuth usage API, then the
cache those writes share with the Touch Bar. Never print a token.
"""
from __future__ import annotations

import json
import math
import signal
import argparse
import ipaddress
import fcntl
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from contextlib import contextmanager
from email.utils import parsedate_to_datetime
from pathlib import Path

CACHE_TTL_S = 60
CLAUDE_CACHE_TTL_S = 60
BAR_WIDTH = 10
COMPACT_BAR_WIDTH = 8
DUAL_BAR_WIDTH = 4
FETCH_TIMEOUT_S = 2.5
CREDITS_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits&include=usage"
SUBS_URL = "https://grok.com/rest/subscriptions"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_BETA = "oauth-2025-04-20"
# Claude Code's own OAuth client, endpoint and Keychain item (CLI 2.1.299).
CLAUDE_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"
SECURITY_STDIN_LIMIT = 4032
# Renewal assumes each replacement token is at most this multiple of its current length,
# plus a fixed metadata allowance (JSON bytes).
RENEWAL_TOKEN_FACTOR = 2
RENEWAL_METADATA_BYTES = 256
ANSI_RGB = {
    "31": (255, 95, 87),
    "32": (48, 209, 88),
    "33": (255, 204, 0),
    "90": (152, 152, 152),
    "0": (230, 230, 230),
}


def grok_home() -> Path:
    home = os.environ.get("GROK_HOME")
    return Path(home) if home else Path.home() / ".grok"


def codex_home() -> Path:
    home = os.environ.get("CODEX_HOME")
    return Path(home) if home else Path.home() / ".codex"


def claude_home() -> Path:
    home = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(home) if home else Path.home() / ".claude"


def project_dir() -> Path:
    return Path(__file__).resolve().parent


TEST_CONFIG = None
REFRESH_REASON = "automatic"
REQUESTS: dict = {}  # per-provider outcome of this call's acquisition request
CACHE_ONLY = False
SELECTED_PROVIDER = "all"
OPERATION_END = None
ATTEMPT = {}


def cache_file(name: str) -> Path:
    if TEST_CONFIG is not None:
        return Path(TEST_CONFIG["cache_dir"]) / name
    return project_dir() / "cache" / name


def load_stdin() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def basename(path: str) -> str:
    path = path.rstrip("/")
    name = path.rsplit("/", 1)[-1] if path else ""
    return name or path or "?"


def fmt_cost(usd) -> str | None:
    if usd is None:
        return None
    try:
        val = float(usd)
    except (TypeError, ValueError):
        return None
    if val < 0.005:
        return None
    if val < 10:
        return f"${val:.2f}"
    return f"${val:.0f}"


def fmt_timer(started_ms) -> str | None:
    if started_ms is None:
        return None
    try:
        start = float(started_ms) / 1000.0
    except (TypeError, ValueError):
        return None
    elapsed = int(time.time() - start)
    if elapsed < 1:
        return None
    if elapsed < 60:
        return f"{elapsed}s"
    minutes, seconds = divmod(elapsed, 60)
    if minutes < 60:
        return f"{minutes}m{seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


def parse_expiry(raw) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        date = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return date if date.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None

def load_token(home: Path) -> str | None:
    path = home / "auth.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    best_token = None
    best_exp = None
    now = datetime.now(timezone.utc)
    for entry in data.values():
        if not isinstance(entry, dict):
            continue
        token = entry.get("key")
        if not isinstance(token, str) or not token:
            continue
        exp = parse_expiry(entry.get("expires_at"))
        if best_token is None:
            best_token, best_exp = token, exp
            continue
        if exp is None and best_exp is None:
            continue
        if exp is None:
            continue
        if best_exp is None or exp > best_exp:
            best_token, best_exp = token, exp
    if best_token and best_exp is not None and best_exp <= now - timedelta(hours=6):
        return None
    return best_token


def parse_period_end(cfg: dict) -> datetime | None:
    period = cfg.get("currentPeriod") if isinstance(cfg.get("currentPeriod"), dict) else {}
    raw = period.get("end") or cfg.get("billingPeriodEnd")
    return parse_expiry(raw)


def usage_percent(cfg: dict) -> float | None:
    pct = cfg.get("creditUsagePercent")
    if pct is None:
        products = cfg.get("productUsage")
        if isinstance(products, list) and products:
            total = 0.0
            found = False
            for row in products:
                if not isinstance(row, dict):
                    continue
                raw = row.get("usagePercent")
                if raw is None:
                    continue
                try:
                    total += float(raw)
                    found = True
                except (TypeError, ValueError):
                    continue
            if found:
                pct = total
    if pct is None:
        if parse_period_end(cfg) is not None:
            return 0.0
        return None
    try:
        return max(0.0, min(100.0, float(pct)))
    except (TypeError, ValueError):
        return None


def grok_headers(token: str) -> dict:
    return {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
        "User-Agent": "grok-cli",
        "x-grok-client-version": "1.0.25",
        "X-XAI-Token-Auth": "xai-grok-cli",
    }


def fetch_json(url: str, token: str) -> dict | None:
    req = urllib.request.Request(url, headers=grok_headers(token))
    try:
        payload = request_json(req)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, ValueError, OSError):
        return None
    return payload if isinstance(payload, dict) else None


def unwrap_time(raw) -> datetime | None:
    if isinstance(raw, dict):
        raw = raw.get("end") or raw.get("at") or raw.get("date")
    return parse_expiry(raw) if isinstance(raw, str) else None


def cfg_of(payload: dict | None) -> dict:
    if not isinstance(payload, dict):
        return {}
    inner = payload.get("config")
    return inner if isinstance(inner, dict) else payload


def first_subscription(payload: dict | None) -> dict:
    if not isinstance(payload, dict):
        return {}
    rows = payload.get("subscriptions")
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict):
                return row
    row = payload.get("subscription")
    return row if isinstance(row, dict) else payload


def parse_account(subs_payload: dict | None) -> dict:
    sub = first_subscription(subs_payload)
    stripe = sub.get("stripe") if isinstance(sub.get("stripe"), dict) else {}
    offer = sub.get("activeOffer") if isinstance(sub.get("activeOffer"), dict) else {}
    trial = offer.get("freeTrial") if isinstance(offer.get("freeTrial"), dict) else {}
    trial_days = trial.get("trialDays")
    try:
        trial_days_n = int(trial_days) if trial_days is not None else 0
    except (TypeError, ValueError):
        trial_days_n = 0
    trial_end = (
        unwrap_time(offer.get("offerEnd"))
        or unwrap_time(sub.get("billingPeriodEnd"))
        or unwrap_time(stripe.get("currentPeriodEnd"))
    )
    trial_start = unwrap_time(offer.get("offerStart")) or unwrap_time(sub.get("billingPeriodStart"))
    is_trial = bool(trial) or trial_days_n > 0
    if not is_trial and trial_start and trial_end:
        span = (trial_end - trial_start).total_seconds()
        if 0 < span <= 4 * 86400:
            is_trial = True
    renew_at = unwrap_time(sub.get("billingPeriodEnd")) or unwrap_time(stripe.get("currentPeriodEnd"))
    return {
        "tier": sub.get("tier") if isinstance(sub.get("tier"), str) else None,
        "is_trial": is_trial,
        "trial_end": trial_end.isoformat() if (is_trial and trial_end) else None,
        "trial_start": trial_start.isoformat() if (is_trial and trial_start) else None,
        "renew_at": None if is_trial else (renew_at.isoformat() if renew_at else None),
    }


def fetch_weekly(token: str) -> dict | None:
    credits = fetch_json(CREDITS_URL, token)
    if not credits:
        return None
    subs = fetch_json(SUBS_URL, token)
    cfg = cfg_of(credits)
    pct = usage_percent(cfg)
    if pct is None:
        return None
    end = parse_period_end(cfg)
    account = parse_account(subs)
    return {
        "percent": pct,
        "period_end": end.isoformat() if end else None,
        "fetched_at": time.time(),
        **account,
    }


def read_cache(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict) or "percent" not in data:
        return None
    return data


def write_cache(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Each writer needs its own temporary file: the app and CLI run concurrently.
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=path.name + ".", delete=False) as handle:
            tmp = Path(handle.name)
            json.dump(data, handle)
        tmp.replace(path)
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


@contextmanager
def cache_lock(path: Path, *, blocking: bool = True):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(fd)


def cache_stale(data: dict | None, *, ttl: int = CACHE_TTL_S) -> bool:
    if not data:
        return True
    try:
        fetched = float(data.get("fetched_at") or 0)
    except (TypeError, ValueError):
        return True
    if (time.time() - fetched) >= ttl:
        return True
    now = datetime.now(timezone.utc)
    for key in ("period_end", "five_hour_end"):
        end = parse_expiry(data.get(key))
        if end is not None and end <= now:
            return True
    return False


def weekly_snapshot(home: Path, trigger: str) -> dict | None:
    cache_path = cache_file("statusline-weekly.json")
    cached = read_cache(cache_path)
    should_fetch = trigger == "refresh_interval" or cache_stale(cached)
    if should_fetch:
        token = load_token(home)
        if token:
            fresh = fetch_weekly(token)
            if fresh:
                write_cache(cache_path, fresh)
                return fresh
    return cached


def load_codex_auth() -> tuple[str, str] | None:
    if TEST_CONFIG is not None:
        auth = TEST_CONFIG.get("codex_auth")
        return (auth["access_token"], auth.get("account_id", "")) if auth else None
    path = codex_home() / "auth.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None
    access = tokens.get("access_token")
    account = tokens.get("account_id")
    if not isinstance(access, str) or not access:
        return None
    if not isinstance(account, str):
        account = ""
    return access, account


def window_seconds(window: dict) -> int:
    raw = window.get("limit_window_seconds")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 0


def codex_windows(payload: dict) -> list[dict]:
    limits = payload.get("rate_limit")
    if not isinstance(limits, dict):
        return []
    windows: list[dict] = []
    for key in ("primary_window", "secondary_window"):
        window = limits.get(key)
        if isinstance(window, dict) and window.get("used_percent") is not None:
            windows.append(window)
    return windows


def split_codex_windows(payload: dict) -> tuple[dict | None, dict | None]:
    windows = codex_windows(payload)
    if not windows:
        return None, None

    def closest(target: int) -> dict:
        return min(windows, key=lambda window: abs(window_seconds(window) - target))

    weekly = closest(604800)
    five = closest(18000)
    if five is weekly:
        if abs(window_seconds(weekly) - 604800) <= abs(window_seconds(weekly) - 18000):
            return None, weekly
        return weekly, None
    return five, weekly


def codex_window_fields(window: dict | None) -> tuple[float | None, str | None]:
    if not isinstance(window, dict): return None, None
    pct = number(window.get("used_percent"), None)
    if pct is None or isinstance(window.get("used_percent"), bool) or not 0 <= pct <= 100: return None, None
    return pct, period_end_iso(window.get("reset_at"))


def record_fetch_error(path: Path, error: str, wait: int, started_at: float, server: int = 0) -> None:
    ATTEMPT.setdefault("outcome", error)
    # The fetch lock serializes provider metadata. Error reporting must not
    # block on the cache lock that may have exhausted this acquisition's budget.
    meta_path = path.with_name(path.name + ".refresh.json")
    meta = read_json(meta_path) or {}
    current = read_json(path) or {}
    if error == "rate_limited" and path.name == "statusline-claude-weekly.json":
        manual = REFRESH_REASON == "manual"
        tally_throttle(meta, manual)
        if manual and recovering(meta):
            # D22: a refused tap inside an episode does not raise the level or
            # restart the long spacing; it breaks the success run and keeps the
            # next request at least 60 s away, like the normal cadence.
            meta["recovery_successes"] = 0
            wait = max(wait, 60)
        else:
            failures = min(5, max(0, int(number(meta.get("rate_limit_failures")))) + 1)
            meta.update(recovery_state="recovering", recovery_successes=0, rate_limit_failures=failures)
            wait = max(wait, recovery_spacing(failures))
    deadline = max(number(current.get("retry_at")), number(meta.get("server_retry_at")), time.time() + max(1, wait))
    meta["next_attempt_at"] = max(number(meta.get("next_attempt_at")), deadline)
    meta["current_failure"] = ATTEMPT["outcome"]
    # Only a real Retry-After > 0 is server authority. Reader-chosen spacing
    # stays in retry_at/recovery_next_at, which a manual refresh may bypass.
    if server > 0:
        meta.update(server_retry_at=max(number(meta.get("server_retry_at")), time.time() + server), server_retry_basis="retry_after")
    write_cache(meta_path, meta)
    with cache_lock(path, blocking=False) as acquired:
        if not acquired: return
        current = read_json(path) or {}
        current.update(error=error, error_at=time.time(), retry_at=max(number(current.get("retry_at")), deadline))
        write_cache(path, current)


def throttle_episodes(meta):
    """Normalized tally rows: known start or a pre-tally marker, non-negative counts."""
    rows = meta.get("throttle_episodes")
    clean = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict): continue
        start, end = number(r.get("started_at"), None), number(r.get("ended_at"), None)
        if (start is None or start <= 0) and r.get("started_before_tally") is not True: continue
        row = {"refused": max(0, int(number(r.get("refused")))), "manual_refused": max(0, int(number(r.get("manual_refused"))))}
        if start and start > 0: row["started_at"] = start
        if r.get("started_before_tally") is True: row["started_before_tally"] = True
        if number(r.get("last_refused_at")) > 0: row["last_refused_at"] = number(r.get("last_refused_at"))
        if end and end > 0:
            row["ended_at"] = end
            if row.get("started_at") and end >= row["started_at"]: row["duration_seconds"] = round(end - row["started_at"], 1)
        clean.append(row)
    return clean[-100:]


def tally_throttle(meta, manual):
    """Durable Claude 429 record: one row per episode, last 100 kept (D22)."""
    rows = throttle_episodes(meta)
    if not rows or rows[-1].get("ended_at") is not None:
        row = {"started_at": time.time(), "refused": 0, "manual_refused": 0}
        if recovering(meta): row["started_before_tally"] = True
        rows.append(row)
    row = rows[-1]
    row["refused"] = int(number(row.get("refused"))) + 1
    if manual: row["manual_refused"] = int(number(row.get("manual_refused"))) + 1
    row["last_refused_at"] = time.time()
    meta["throttle_episodes"] = rows[-100:]


def close_throttle(meta):
    rows = throttle_episodes(meta)
    if not rows or rows[-1].get("ended_at") is not None:
        # Recovery that began before the tally (or its 429 rows) ends here: record it, start unknown.
        rows.append({"started_before_tally": True, "refused": 0, "manual_refused": 0})
    row = rows[-1]
    row["ended_at"] = time.time()
    if row.get("started_at") and row["ended_at"] >= row["started_at"]:
        row["duration_seconds"] = round(row["ended_at"] - row["started_at"], 1)
    meta["throttle_episodes"] = rows[-100:]


def retry_seconds(raw: str | None) -> int:
    """Seconds the server asked to wait: 0 when absent, zero, past or unparseable."""
    if not raw: return 0
    try:
        seconds = float(raw)
    except (TypeError, ValueError):
        try:
            seconds = parsedate_to_datetime(raw).timestamp() - time.time()
        except (TypeError, ValueError, OverflowError):
            return 0
    return max(0, math.ceil(seconds)) if math.isfinite(seconds) else 0


class NoTestRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class OperationBudget(TimeoutError):
    pass


@contextmanager
def bounded_operation(seconds):
    # Unix main-thread real-time timer bounds DNS/connect AND the entire body,
    # even a peer dripping bytes faster than a socket's inactivity timeout.
    def expired(signum, frame):
        raise OperationBudget("deadline")
    previous = signal.signal(signal.SIGALRM, expired)
    old = signal.setitimer(signal.ITIMER_REAL, max(.001, seconds))
    began = time.monotonic()
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if old[0] > 0:
            signal.setitimer(signal.ITIMER_REAL, max(.001, old[0] - (time.monotonic() - began)), old[1])


def remaining_budget():
    return max(0, OPERATION_END - time.monotonic()) if OPERATION_END else 75


def request_json(req, timeout=FETCH_TIMEOUT_S):
    seconds = min(timeout, remaining_budget())
    if seconds <= 0: raise OperationBudget("operation budget")
    with bounded_operation(seconds):
        opener = urllib.request.build_opener(NoTestRedirect)
        with opener.open(req, timeout=seconds) as resp:
            ATTEMPT["http_status"] = resp.status
            raw = resp.read(65537)
            if len(raw) > 65536: raise ValueError("response size")
            data = json.loads(raw)
            if not isinstance(data, dict): raise ValueError("response shape")
            return data


def transport_outcome(exc):
    reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    if isinstance(reason, OperationBudget) and remaining_budget() <= .05: return "operation_timeout"
    if isinstance(reason, TimeoutError): return "transport_timeout"
    if isinstance(exc, (urllib.error.URLError, OSError)): return "network_error"
    return "malformed_response"


def note_http(exc):
    ATTEMPT["http_status"] = exc.code
    raw = exc.headers.get("Retry-After") if exc.headers else None
    # Only numeric or parseable HTTP-date input, never arbitrary server text.
    try:
        numeric = float(raw)
        if math.isfinite(numeric): ATTEMPT["retry_after"] = {"seconds": numeric}
    except (ValueError, TypeError):
        try: ATTEMPT["retry_after"] = {"date": parsedate_to_datetime(raw).timestamp()}
        except (ValueError, TypeError, OverflowError): pass


def fetch_codex_weekly(access: str, account: str) -> dict | None:
    started_at = time.time()
    path = cache_file("statusline-codex-weekly.json")
    headers = {
        "Authorization": "Bearer " + access,
        "Accept": "application/json",
        "User-Agent": "grok-cli",
    }
    if account:
        headers["ChatGPT-Account-Id"] = account
    req = urllib.request.Request(CODEX_USAGE_URL, headers=headers)
    try:
        payload = request_json(req)
    except urllib.error.HTTPError as exc:
        note_http(exc)
        error = {401: "sign_in_expired", 403: "access_denied", 429: "rate_limited"}.get(exc.code, "usage_unavailable")
        server = retry_seconds(exc.headers.get("Retry-After") if exc.headers else None) if exc.code == 429 else 0
        record_fetch_error(path, error, (server or 60) if exc.code == 429 else 120, started_at, server)
        exc.close()
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError) as exc:
        ATTEMPT["outcome"] = transport_outcome(exc)
        record_fetch_error(path, "network_error", 60, started_at)
        return None
    if not isinstance(payload, dict):
        record_fetch_error(path, "usage_unavailable", 60, started_at)
        return None
    five, weekly = split_codex_windows(payload)
    if five is None and weekly is None:
        record_fetch_error(path, "usage_unavailable", 60, started_at)
        return None
    five_pct, five_end = codex_window_fields(five)
    week_pct, week_end = codex_window_fields(weekly)
    if five_pct is None and week_pct is None:
        record_fetch_error(path, "usage_unavailable", 60, started_at)
        return None
    plan = payload.get("plan_type")
    return {
        "percent": week_pct,
        "period_end": week_end,
        "five_hour_percent": five_pct,
        "five_hour_end": five_end,
        "fetched_at": time.time(),
        "plan": plan if isinstance(plan, str) else None,
    }


WINDOW_FIELDS = (("seven_day", "percent", "period_end"), ("five_hour", "five_hour_percent", "five_hour_end"))


def number(raw, default=0.0):
    try:
        n = float(raw)
        return n if math.isfinite(n) else default
    except (ValueError, TypeError): return default


def window_fresh(snap, window, interval, now=None):
    now = time.time() if now is None else now
    _, pct_key, end_key = next(row for row in WINDOW_FIELDS if row[0] == window)
    stamp = number(snap.get(window + "_fetched_at"))
    end = parse_expiry(snap.get(end_key))
    pct = number(snap.get(pct_key), None)
    return (pct is not None and not isinstance(snap.get(pct_key), bool) and 0 <= pct <= 100 and snap.get(window + "_freshness_basis") == "api_acquisition"
            and stamp > 0 and 0 <= now - stamp <= interval + 5
            and end is not None and end.timestamp() > now)


def poll_interval(snap, meta=None):
    meta = meta or {}
    now = time.time()
    known = []
    high = False
    for window, pct_key, _ in WINDOW_FIELDS:
        fresh = window_fresh(snap, window, 30 if meta.get("poll_interval_seconds") == 30 else 60, now)
        known.append(fresh)
        if fresh and number(snap.get(pct_key)) >= (88 if window == "five_hour" else 97): high = True
    if high: return 30
    if all(known): return 60
    return 30 if meta.get("poll_interval_seconds") == 30 else 60


def provider_deadline(snap, meta, interval):
    # Budget covers automatic callers even with partial/unknown native windows.
    due = number(meta.get("next_attempt_at"))
    valid = [number(snap.get(w + "_fetched_at")) for w, _, _ in WINDOW_FIELDS
             if snap.get(w + "_freshness_basis") == "api_acquisition" and 0 < number(snap.get(w + "_fetched_at")) <= time.time()]
    has_error = bool(snap.get("error") or meta.get("current_failure"))
    if valid and not has_error:
        due = max(due, min(valid) + interval)
    now = time.time()
    if not has_error and any(number(snap.get("fetched_at")) < end.timestamp() <= now for _, _, e in WINDOW_FIELDS if (end := parse_expiry(snap.get(e))) is not None):
        # A reset invalidates the normal freshness deadline, never a backoff.
        due = min(due, now)
    return max(due, number(snap.get("retry_at")), number(meta.get("server_retry_at")), number(meta.get("recovery_next_at")))


def merge_acquisition(path, fresh, started):
    with cache_lock(path):
        current = read_json(path) or {}
        for window, pct_key, end_key in WINDOW_FIELDS:
            if fresh.get(pct_key) is None: continue
            # A report arriving during HTTP wins only its own window.
            if current.get(window + "_reading_source") == "claude_native" and number(current.get(window + "_observed_at")) >= started:
                continue
            for key in (pct_key, end_key, window + "_fetched_at", window + "_observed_at", window + "_freshness_basis", window + "_reading_source"):
                current[key] = fresh.get(key)
        current.update({k:v for k,v in fresh.items() if k in ("source", "credential_source", "plan", "fetched_at")})
        for key in ("error", "error_at", "retry_at"): current.pop(key, None)
        write_cache(path, current)
    return current


def recovering(meta):
    return meta.get("recovery_state") == "recovering" or number(meta.get("rate_limit_failures")) > 0


def normalize_recovery(meta, cached):
    meta = dict(meta)
    active = (cached.get("error") == "rate_limited" or recovering(meta)
              or meta.get("recovery_state") not in (None, "normal")
              or ("rate_limit_failures" in meta and meta["rate_limit_failures"] != 0))
    if not active: return meta
    level = meta.get("rate_limit_failures", 1)
    if type(level) is not int or not 0 <= level <= 5: level = 5
    successes = meta.get("recovery_successes", 0)
    # Reachable counts stay below 7 (5 decay steps plus 2 carried from the
    # pre-decay rule); anything larger is malformed.
    if type(successes) is not int or not 0 <= successes <= 6: successes = 0
    meta.update(recovery_state="recovering", rate_limit_failures=level, recovery_successes=successes)
    # Reconstruct from real persisted evidence, never from each cache read's time.
    evidence = max(number(cached.get("error_at")), number(cached.get("fetched_at")))
    if cached.get("error") != "rate_limited":
        meta["recovery_next_at"] = max(number(meta.get("recovery_next_at")), evidence + recovery_spacing(level))
    return meta


def recovery_spacing(level):
    # Level 0 is still proving sustained success at the normal 60 s target.
    return 60 if level <= 0 else min(900, 60 * 2 ** (level - 1))


def recovery_interval(meta):
    return recovery_spacing(max(0, min(5, int(number(meta.get("rate_limit_failures"), 1)))))


def trusted_server_retry(meta):
    """Rebuild a server_retry_at the pre-2026-10-17 reader wrote from its own spacing.

    This reader marks real deadlines with server_retry_basis. An unmarked one is
    legacy: keep only what the latest HTTP 429's recorded Retry-After asked for.
    """
    if "server_retry_at" not in meta or meta.get("server_retry_basis") == "retry_after": return meta
    limited = [a for a in meta.get("attempts") or [] if isinstance(a, dict) and a.get("http_status") == 429]
    if not limited: return meta
    asked = limited[-1].get("retry_after") or {}
    until = (number(limited[-1].get("completed_at")) + number(asked.get("seconds")) if "seconds" in asked
             else number(asked.get("date")))
    meta = dict(meta)
    if until > time.time(): meta.update(server_retry_at=until, server_retry_basis="retry_after")
    else: meta.pop("server_retry_at", None)
    return meta


def last_attempt_start(meta):
    # Latest start or finish, so the floor is never shorter than 60 s after a refusal (D22).
    history = [max(number(a.get("started_at")), number(a.get("completed_at"))) for a in meta.get("attempts") or [] if isinstance(a, dict)]
    return max([number(meta.get("last_attempt_started_at"))] + history)


def note_request(name, attempted, deferred_by=None, deferred_until=None):
    REQUESTS[name] = {"reason": "cache-only" if CACHE_ONLY else REFRESH_REASON, "attempted": attempted,
                      "deferred_by": deferred_by, "deferred_until": deferred_until}


def provider_snapshot(name: str, fetch, *, force: bool = False) -> dict | None:
    global OPERATION_END, ATTEMPT
    path = cache_file("statusline-" + name + "-weekly.json")
    note_request(name, False)
    if CACHE_ONLY: return read_json(path)
    with cache_lock(path.with_name(path.name + ".fetch"), blocking=False) as acquired:
        if not acquired:
            note_request(name, False, "fetch_in_progress")
            return read_json(path)
        cached = read_json(path) or {}
        meta_path = path.with_name(path.name + ".refresh.json")
        meta = trusted_server_retry(read_json(meta_path) or {})
        if name == "claude": meta = normalize_recovery(meta, cached)
        now = time.time()
        interval = poll_interval(cached, meta)
        error = cached.get("error") or meta.get("current_failure")
        server = number(meta.get("server_retry_at"))
        if REFRESH_REASON == "manual":
            # Manual honours real server backoff and, while recovering or
            # failing, a 60 s floor since the last attempt; it bypasses the
            # reader's own spacing. Healthy keeps the 5 s manual gate.
            floor = (last_attempt_start(meta) + 60 if error or (name == "claude" and recovering(meta))
                     else number(meta.get("next_manual_at")))
            deadline = max(server, floor)
            deferred_by = "server_retry" if server >= floor else "manual_floor"
        else:
            hard = max(number(cached.get("retry_at")), server, number(meta.get("recovery_next_at")))
            deadline = max(hard, provider_deadline(cached, meta, interval))
            deferred_by = "server_retry" if server >= deadline else None
        if now < deadline:
            note_request(name, False, deferred_by, deadline)
            return cached or None
        note_request(name, True)
        meta["last_attempt_started_at"] = now
        meta["next_attempt_at"] = now + (30 if error else 5)
        if REFRESH_REASON == "manual": meta["next_manual_at"] = now + 5
        write_cache(meta_path, meta)
        began = time.monotonic()
        OPERATION_END = began + 75
        ATTEMPT = {"started_at": now}
        try:
            with bounded_operation(75): fresh = fetch()
        except OperationBudget:
            ATTEMPT["outcome"] = "operation_timeout"
            record_fetch_error(path, "budget_timeout", 60, now)
            fresh = None
        finally:
            OPERATION_END = None
        current = read_json(path) or {}
        meta = read_json(meta_path) or meta
        if name == "claude": meta = normalize_recovery(meta, current)
        if fresh:
            interval = poll_interval(current, meta)
            meta["poll_interval_seconds"] = interval
            meta["next_attempt_at"] = time.time() + interval
            complete = ATTEMPT.get("complete_acquisition", False)
            if name == "claude" and recovering(meta):
                # Each complete success steps spacing down one level
                # (900→480→240→120→60); exit needs level 0 and 3 successes.
                level = meta.get("rate_limit_failures", 1)
                successes = meta.get("recovery_successes", 0) + 1 if complete else 0
                if complete: level = max(0, level - 1)
                meta.update(rate_limit_failures=level, recovery_successes=successes)
                if level == 0 and successes >= 3:
                    for k in ("rate_limit_failures", "recovery_next_at", "recovery_successes", "recovery_state"): meta.pop(k, None)
                    close_throttle(meta)
                else:
                    meta["recovery_state"] = "recovering"
                    meta["recovery_next_at"] = time.time() + recovery_interval(meta)
                    meta["next_attempt_at"] = max(meta["next_attempt_at"], meta["recovery_next_at"])
            elif name != "claude": meta.pop("rate_limit_failures", None)
            if number(meta.get("server_retry_at")) <= time.time():
                for k in ("server_retry_at", "server_retry_basis"): meta.pop(k, None)
            ATTEMPT["outcome"] = "success" if complete else "partial_response"
            if complete:
                meta.pop("current_failure", None)
            else:
                meta["current_failure"] = "partial_response"
                meta["last_failure"] = {"outcome": "partial_response", "at": time.time()}
        else:
            if name == "claude" and recovering(meta):
                meta["recovery_successes"] = 0
                meta["recovery_next_at"] = max(number(meta.get("recovery_next_at")), number(current.get("retry_at")))
            meta["next_attempt_at"] = max(number(meta.get("next_attempt_at")), number(current.get("retry_at")), number(meta.get("recovery_next_at")))
            meta["current_failure"] = ATTEMPT.get("outcome", current.get("error") or "unusable_response")
            meta["last_failure"] = {"outcome": meta["current_failure"], "at": time.time()}
        ATTEMPT.update(completed_at=time.time(), elapsed_seconds=time.monotonic()-began,
                       outcome=ATTEMPT.get("outcome", "unusable_response"),
                       credential_source=ATTEMPT.get("credential_source", "unavailable"),
                       next_attempt_at=provider_deadline(current, meta, interval),
                       recovery_state="recovering" if name == "claude" and recovering(meta) else "normal")
        history = meta.get("attempts")
        meta["attempts"] = (history if isinstance(history, list) else [])[-19:] + [ATTEMPT]
        write_cache(meta_path, meta)
        return current or None

def codex_weekly_snapshot(home: Path, trigger: str) -> dict | None:
    def fetch():
        path = cache_file("statusline-codex-weekly.json")
        started = time.time()
        auth = load_codex_auth()
        if not auth:
            record_fetch_error(path, "sign_in_required", 120, started)
            return None
        ATTEMPT["credential_source"] = "fixture" if TEST_CONFIG is not None else "codex_auth_file"
        fresh = fetch_codex_weekly(*auth)
        if fresh:
            for window, pct_key, _ in WINDOW_FIELDS:
                if fresh.get(pct_key) is not None:
                    fresh.update({window + "_fetched_at": fresh["fetched_at"], window + "_observed_at": fresh["fetched_at"],
                                  window + "_freshness_basis": "api_acquisition", window + "_reading_source": "usage_api"})
            ATTEMPT["complete_acquisition"] = all(window_fresh(fresh, w, 60) for w, _, _ in WINDOW_FIELDS)
            fresh["source"] = "usage_api"
            return merge_acquisition(path, fresh, started)
        return None
    return provider_snapshot("codex", fetch)

def read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def claude_file_oauth() -> dict | None:
    oauth = (read_json(claude_home() / ".credentials.json") or {}).get("claudeAiOauth")
    return oauth if isinstance(oauth, dict) else None


def claude_keychain_blob() -> dict | None:
    if TEST_CONFIG is not None:
        store = TEST_CONFIG.get("claude_store_file")
        return read_json(Path(store)) if store else None
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=1,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def claude_desktop_oauth() -> list[dict]:
    """Read the running desktop session's token in memory; never save or renew it.

    Desktop Claude supplies its children with host-managed OAuth credentials,
    independently of the terminal Keychain login. Only inspect this user's
    bundled Claude processes, and never expose environment text or tokens.
    """
    found = []
    prefix = str(Path.home() / "Library/Application Support/Claude/claude-code") + "/"
    try:
        rows = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,uid=,comm="], text=True,
            stderr=subprocess.DEVNULL, timeout=1,
        )
        pids = []
        for row in rows.splitlines():
            fields = row.strip().split(None, 2)
            if len(fields) == 3 and fields[1] == str(os.getuid()) and fields[2].startswith(prefix):
                pids.append(int(fields[0]))
        for pid in sorted(pids, reverse=True)[:4]:
            try:
                env = subprocess.check_output(
                    ["/bin/ps", "eww", "-p", str(pid), "-o", "command="],
                    text=True, stderr=subprocess.DEVNULL, timeout=1,
                )
            except subprocess.SubprocessError:
                continue
            if not re.search(r"(?:^|\s)CLAUDE_CODE_ENTRYPOINT=claude-desktop(?:\s|$)", env):
                continue
            match = re.search(r"(?:^|\s)CLAUDE_CODE_OAUTH_TOKEN=([^\s]+)", env)
            if match:
                found.append({"accessToken": match.group(1)})
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return found


def oauth_access(oauth: dict | None) -> str | None:
    if not isinstance(oauth, dict):
        return None
    token = oauth.get("accessToken")
    return token if isinstance(token, str) and token else None


def oauth_expired(oauth: dict | None) -> bool:
    if not isinstance(oauth, dict):
        return True
    try:
        exp = float(oauth.get("expiresAt") or 0)
    except (TypeError, ValueError):
        return False
    if exp <= 0:
        return False
    return exp <= (time.time() * 1000) + 60_000


def claude_candidates():
    if TEST_CONFIG is not None:
        rows = [("fixture", row) for row in TEST_CONFIG.get("claude_credentials", [])]
        if TEST_CONFIG.get("claude_store_file"):
            rows.insert(0, ("keychain", (claude_keychain_blob() or {}).get("claudeAiOauth")))
    else:
        keychain = claude_keychain_blob() or {}
        rows = [("keychain", keychain.get("claudeAiOauth")), ("file", claude_file_oauth())]
    seen = set()
    for source, oauth in rows:
        token = oauth_access(oauth)
        if token and token not in seen and not oauth_expired(oauth):
            seen.add(token)
            yield oauth, source
    if TEST_CONFIG is None:
        for desktop in claude_desktop_oauth():
            token = oauth_access(desktop)
            if token and token not in seen:
                seen.add(token)
                yield desktop, "desktop_session"
    if not seen:
        for source, oauth in rows:
            if oauth_access(oauth):
                yield oauth, source
                break


def claude_store_command(blob: dict) -> str:
    """The `security -i` command that replaces the terminal sign-in, as Claude Code does."""
    hexed = json.dumps(blob, separators=(",", ":")).encode("utf-8").hex()
    user = os.environ.get("USER") or ""
    account = user if re.fullmatch(r"[A-Za-z0-9._-]+", user) else "claude-code-user"
    return f'add-generic-password -U -a "{account}" -s "{CLAUDE_KEYCHAIN_SERVICE}" -X "{hexed}"\n'


def claude_store_fits(blob: dict) -> bool:
    """Whether a renewed sign-in could still be written. Renewal rotates the refresh
    token, so it must not start when the replacement cannot be saved."""
    if TEST_CONFIG is not None:
        return True
    oauth = blob.get("claudeAiOauth") if isinstance(blob.get("claudeAiOauth"), dict) else {}
    tokens = sum(len(str(oauth.get(k) or "")) for k in ("accessToken", "refreshToken"))
    growth = (RENEWAL_TOKEN_FACTOR - 1) * tokens + RENEWAL_METADATA_BYTES  # the current tokens are already counted
    return len(claude_store_command(blob)) + 2 * growth <= SECURITY_STDIN_LIMIT  # hex doubles each byte


def claude_store_write(blob: dict) -> bool:
    """Replace the terminal sign-in exactly as Claude Code does (`security -i` on stdin).
    Credentials never go in process arguments, so an oversized item is refused."""
    if TEST_CONFIG is not None:
        write_cache(Path(TEST_CONFIG["claude_store_file"]), blob)
        return True
    command = claude_store_command(blob)
    if len(command) > SECURITY_STDIN_LIMIT:
        return False
    try:
        done = subprocess.run(["security", "-i"], input=command, text=True,
                              capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0


@contextmanager
def claude_refresh_lock():
    """Hold Claude Code's own refresh locks (proper-lockfile directories).

    Claude Code re-reads the sign-in inside these locks and adopts a token
    renewed by another process, so renewing here cannot race its rotation.
    """
    home = Path(TEST_CONFIG["claude_home"]) if TEST_CONFIG is not None else claude_home()
    paths = [home / ".oauth_refresh.lock", Path(str(home.resolve()) + ".lock")]
    held = []
    try:
        for path in paths:
            try:
                path.mkdir()
            except FileExistsError:
                try:
                    # Holders touch the lock every 5 s; Claude treats 60 s as stale.
                    stale = time.time() - path.stat().st_mtime > 120
                    if stale:
                        path.rmdir()
                        path.mkdir()
                    else:
                        yield False
                        return
                except OSError:
                    yield False
                    return
            except OSError:
                yield False
                return
            held.append(path)
        yield True
    finally:
        for path in reversed(held):
            try:
                path.rmdir()
            except OSError:
                pass


def renew_claude_terminal() -> str:
    """Renew an expired terminal sign-in so the reader never depends on an
    open Claude Code session. Returns a non-secret outcome for diagnostics."""
    if TEST_CONFIG is not None and not TEST_CONFIG.get("claude_store_file"):
        return "skipped"
    # Renewal rewrites Claude Code's Keychain item, so outside test mode it is opt-in.
    if TEST_CONFIG is None and not (Path.home() / "Library/Application Support/UsageTouchBar/renew-claude-signin").exists():
        return "disabled"
    oauth = (claude_keychain_blob() or {}).get("claudeAiOauth")
    if not isinstance(oauth, dict) or not oauth.get("refreshToken") or not oauth_expired(oauth):
        return "not_needed"
    meta_path = cache_file("statusline-claude-renewal.json")
    meta = read_json(meta_path) or {}
    now = time.time()
    if now < float(meta.get("next_attempt_at") or 0):
        return "cooldown"
    # A rejected refresh token stays rejected until Claude signs in again.
    if meta.get("rejected_expires_at") is not None and meta.get("rejected_expires_at") == oauth.get("expiresAt"):
        return "rejected"
    result, wait, rejected = "failed", 300, None
    with claude_refresh_lock() as held:
        if not held:
            return "lock_busy"
        blob = claude_keychain_blob() or {}
        oauth = blob.get("claudeAiOauth")
        if not isinstance(oauth, dict) or not oauth.get("refreshToken"):
            return "not_needed"
        if not oauth_expired(oauth):
            result, wait = "adopted", 0
        elif not claude_store_fits(blob):
            # The rotated tokens could not be saved; leave the sign-in as it is.
            result, wait = "store_too_large", 3600
        elif not claude_store_write(blob):
            # Prove the item is writable before the server rotates the token;
            # a refused write afterwards would sign terminal Claude Code out.
            result, wait = "store_unwritable", 3600
        else:
            scopes = oauth.get("scopes") if isinstance(oauth.get("scopes"), list) else []
            body = {"grant_type": "refresh_token", "refresh_token": oauth["refreshToken"],
                    "client_id": oauth.get("clientId") or CLAUDE_CLIENT_ID, "scope": " ".join(scopes)}
            req = urllib.request.Request(TEST_CONFIG["claude_token_url"] if TEST_CONFIG is not None else CLAUDE_TOKEN_URL,
                                         data=json.dumps(body).encode(), method="POST",
                                         headers={"Content-Type": "application/json", "User-Agent": "claude-cli"})
            try:
                if remaining_budget() < 30: raise OperationBudget("renewal reserve")
                reply = request_json(req, timeout=15)
                access, expires_in = reply.get("access_token"), float(reply.get("expires_in"))
                if not isinstance(access, str) or not access or not math.isfinite(expires_in) or expires_in <= 0:
                    raise ValueError("malformed token response")
                renewed = dict(oauth)
                renewed["accessToken"] = access
                renewed["refreshToken"] = reply.get("refresh_token") or oauth["refreshToken"]
                renewed["expiresAt"] = int(time.time() * 1000 + expires_in * 1000)
                if isinstance(reply.get("refresh_token_expires_in"), (int, float)):
                    renewed["refreshTokenExpiresAt"] = int(time.time() * 1000 + reply["refresh_token_expires_in"] * 1000)
                if isinstance(reply.get("scope"), str) and reply["scope"].split():
                    renewed["scopes"] = reply["scope"].split()
                updated = dict(blob)
                updated["claudeAiOauth"] = renewed
                # One retry: the server already rotated the refresh token.
                if (claude_store_write(updated) or claude_store_write(updated)) and \
                        oauth_access((claude_keychain_blob() or {}).get("claudeAiOauth")) == access:
                    result, wait = "renewed", 0
                else:
                    result = "store_failed"
            except urllib.error.HTTPError as exc:
                note_http(exc)
                if exc.code == 429:
                    result, wait = "rate_limited", max(300, retry_seconds(exc.headers.get("Retry-After") if exc.headers else None))
                elif exc.code in (400, 401, 403):
                    result, wait, rejected = "rejected", 0, oauth.get("expiresAt")
                exc.close()
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, TypeError, OSError) as exc:
                result = transport_outcome(exc)
                ATTEMPT["outcome"] = "renewal_" + result
    write_cache(meta_path, {"last_result": result, "last_at": time.time(),
                            "next_attempt_at": time.time() + wait, "rejected_expires_at": rejected})
    return result


def choose_claude_oauth() -> tuple[dict | None, str]:
    return next(claude_candidates(), (None, ""))


def claude_api_get(token: str) -> tuple[dict | None, int | None, int]:
    req = urllib.request.Request(
        CLAUDE_USAGE_URL,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "anthropic-beta": CLAUDE_BETA,
            "User-Agent": "claude-cli",
        },
    )
    try:
        payload = request_json(req)
    except urllib.error.HTTPError as exc:
        note_http(exc)
        server = retry_seconds(exc.headers.get("Retry-After") if exc.headers else None) if exc.code == 429 else 0
        exc.close()
        return None, exc.code, server
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError) as exc:
        ATTEMPT["outcome"] = transport_outcome(exc)
        return None, None, 0
    return (payload if isinstance(payload, dict) else None), 200, 0


def period_end_iso(raw) -> str | None:
    try:
        if isinstance(raw, (int, float)) and math.isfinite(raw):
            val = float(raw)
            if val > 1e12: val /= 1000.0
            return datetime.fromtimestamp(val, tz=timezone.utc).isoformat()
        end = parse_expiry(raw)
        return end.isoformat() if end else None
    except (ValueError, OverflowError, OSError):
        return None

def usage_window_percent(window) -> float | None:
    if not isinstance(window, dict):
        return None
    raw = window.get("used_percentage")
    if raw is None:
        raw = window.get("utilization")
    if raw is None:
        return None
    try:
        pct = float(raw)
        return pct if not isinstance(raw, bool) and math.isfinite(pct) and 0 <= pct <= 100 else None
    except (TypeError, ValueError):
        return None


def claude_windows_snapshot(limits: dict, *, trusted: bool = False) -> dict | None:
    if not isinstance(limits, dict): return None
    now = time.time()
    snap = {}
    for src, pct_key, end_key in WINDOW_FIELDS:
        window = limits.get(src)
        pct = usage_window_percent(window)
        if pct is None or not isinstance(window, dict): continue
        snap[pct_key] = pct
        snap[end_key] = period_end_iso(window.get("resets_at") or window.get("resetsAt"))
        snap[src + "_fetched_at"] = now if trusted else None
        snap[src + "_observed_at"] = now
        snap[src + "_freshness_basis"] = "api_acquisition" if trusted else "unverified_native_receipt"
        snap[src + "_reading_source"] = "usage_api" if trusted else "claude_native"
    if not snap: return None
    if trusted: snap["fetched_at"] = now
    return snap

def remember_claude_limits(limits: dict, payload: dict | None = None) -> None:
    # No native measurement timestamp has been validated. Replayed receipts
    # may supply values, but never renew acquisition age or the API budget.
    snap = claude_windows_snapshot(limits)
    if not snap: return
    path = cache_file("statusline-claude-weekly.json")
    with cache_lock(path):
        current = read_json(path) or {}
        for src, pct_key, end_key in WINDOW_FIELDS:
            if pct_key not in snap: continue
            # Unchanged native replay must not erase a trusted API acquisition.
            if current.get(pct_key) == snap[pct_key] and current.get(end_key) == snap[end_key]:
                current[src + "_observed_at"] = snap[src + "_observed_at"]
                continue
            for key in (pct_key, end_key, src + "_fetched_at", src + "_observed_at", src + "_freshness_basis", src + "_reading_source"):
                current[key] = snap[key]
        current.setdefault("source", "claude_code")
        write_cache(path, current)

def fetch_claude_weekly() -> dict | None:
    started_at = time.time()
    path = cache_file("statusline-claude-weekly.json")
    # Renew an expired terminal sign-in under Claude Code's own refresh lock
    # (owner-authorized 2026-10-15); desktop session tokens are never written.
    renewal = renew_claude_terminal()
    ATTEMPT["renewal"] = renewal
    candidates = claude_candidates()
    oauth, source = next(candidates, (None, ""))
    ATTEMPT["credential_source"] = source or "unavailable"
    token = oauth_access(oauth)
    if not token:
        record_fetch_error(path, "sign_in_required", 120, started_at)
        return None
    if oauth_expired(oauth):
        record_fetch_error(path, "sign_in_expired", 120, started_at)
        return None
    payload, code, server = claude_api_get(token)
    if code == 401:
        for alternate, alternate_source in candidates:
            if oauth_expired(alternate):
                continue
            source = alternate_source
            ATTEMPT["credential_source"] = source
            payload, code, server = claude_api_get(oauth_access(alternate))
            if code != 401:
                break
    if code in (401, 403, 429):
        error = "rate_limited" if code == 429 else ("sign_in_expired" if code == 401 else "access_denied")
        record_fetch_error(path, error, server if code == 429 else 120, started_at, server)
        return None
    snap = claude_windows_snapshot(payload or {}, trusted=True)
    if not snap:
        record_fetch_error(path, "network_error" if code is None else "usage_unavailable", 60, started_at)
        return None
    ATTEMPT["complete_acquisition"] = all(window_fresh(snap, w, 60) for w, _, _ in WINDOW_FIELDS)
    snap["source"] = "usage_api"
    snap["credential_source"] = source
    return merge_acquisition(path, snap, started_at)


def claude_weekly_snapshot(trigger: str) -> dict | None:
    # A status-line clock tick must obey the same usage polling budget as the
    # Touch Bar. Explicit manual refresh already has its own bounded path.
    return provider_snapshot("claude", fetch_claude_weekly)


PARTIAL = " ▏▎▍▌▋▊▉█"


def bar(pct: float, width: int = BAR_WIDTH) -> str:
    eighths = max(0.0, min(100.0, pct)) * width * 8.0 / 100.0
    full = int(eighths) // 8
    rem = int(eighths) % 8
    full = min(width, full)
    cells = ["█"] * full
    if rem and full < width:
        cells.append(PARTIAL[rem])
    cells.extend(["░"] * (width - len(cells)))
    return "".join(cells)


def bar_color(pct: float) -> str:
    """Usage remaining-to-limit: high used is bad (red), low is good (green)."""
    if pct >= 80:
        return "31"
    if pct >= 50:
        return "33"
    return "32"


def remaining_bar_color(pct: float) -> str:
    """Time remaining: full is good (green), empty is bad (red)."""
    if pct >= 80:
        return "32"
    if pct >= 50:
        return "33"
    return "31"


def fmt_reset_seconds(remaining: int) -> str:
    if remaining <= 0:
        return "now"
    days, rem = divmod(remaining, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d{hours}h"
    if hours:
        return f"{hours}h{minutes}m"
    return f"{minutes}m"


# Reset clocks are shown in the Mac's own time zone.
def fmt_local_clock(end: datetime) -> str:
    local = end.astimezone()
    return local.strftime("%-d %b %-I:%M%p").replace("AM", "am").replace("PM", "pm")


DAYS = ("Mon", "Tue", "Wed", "Thur", "Fri", "Sat", "Sun")


def fmt_local_hm(end: datetime) -> str:
    local = end.astimezone()
    hour = int(local.strftime("%I"))
    minute = local.strftime("%M")
    suffix = "am" if local.hour < 12 else "pm"
    return f"{hour}:{minute}{suffix}"


def fmt_local_day_hm(end: datetime) -> str:
    local = end.astimezone()
    return f"{DAYS[local.weekday()]} {fmt_local_hm(end)}"


def fmt_reset(end_raw) -> str | None:
    end = None
    remaining = None
    if isinstance(end_raw, (int, float)):
        remaining = int(end_raw - time.time())
        end = datetime.fromtimestamp(float(end_raw), tz=timezone.utc)
    elif isinstance(end_raw, str) and end_raw:
        end = parse_expiry(end_raw)
        if end is not None:
            remaining = int((end - datetime.now(timezone.utc)).total_seconds())
    if remaining is None:
        return None
    clock = fmt_local_clock(end) if end is not None else None
    left = fmt_reset_seconds(remaining)
    if clock:
        return f"{left} · {clock}"
    return left


def usage_bar_text(
    label: str,
    pct: float | None,
    reset: str | None,
    remaining: bool = False,
) -> str:
    if pct is None:
        return f"{label} —"
    color = remaining_bar_color(pct) if remaining else bar_color(pct)
    shown = f"{pct:.0f}" if pct >= 10 else f"{pct:.1f}"
    parts = [
        f"\033[{color}m{bar(pct)}\033[0m",
        f"\033[{color}m{shown}%\033[0m",
    ]
    if reset:
        parts.append(reset)
    return f"{label} " + " ".join(parts)


def weekly_segment(snap: dict | None) -> str:
    if not snap:
        return usage_bar_text("week", None, None)
    try:
        pct = float(snap["percent"])
    except (KeyError, TypeError, ValueError):
        return usage_bar_text("week", None, None)
    return usage_bar_text("week", pct, fmt_reset(snap.get("period_end")))


def fmt_local_date(end: datetime) -> str:
    return end.astimezone().strftime("%-d %b")


def trial_remaining_pct(snap: dict, end: datetime) -> float | None:
    start = parse_expiry(snap.get("trial_start"))
    if start is None:
        return None
    total = (end - start).total_seconds()
    if total <= 0:
        return 0.0
    left = (end - datetime.now(timezone.utc)).total_seconds()
    return max(0.0, min(100.0, left * 100.0 / total))


def account_segment(snap: dict | None) -> str | None:
    if not snap:
        return None
    if snap.get("is_trial"):
        end = parse_expiry(snap.get("trial_end"))
        if end is None:
            return None
        remaining = int((end - datetime.now(timezone.utc)).total_seconds())
        left = fmt_reset_seconds(remaining)
        clock = fmt_local_clock(end)
        pct = trial_remaining_pct(snap, end)
        if remaining <= 0:
            color = "31"
            body = "ended"
        elif pct is not None:
            color = remaining_bar_color(pct)
            body = f"{left} · {clock}"
        elif remaining <= 12 * 3600:
            color = "31"
            body = f"{left} · {clock}"
        elif remaining <= 36 * 3600:
            color = "33"
            body = f"{left} · {clock}"
        else:
            color = "32"
            body = f"{left} · {clock}"
        if pct is None:
            return f"\033[{color}mtrial\033[0m {body}"
        return f"\033[{color}mtrial\033[0m {usage_bar_text('', pct, None, remaining=True).strip()} {body}"
    end = parse_expiry(snap.get("renew_at"))
    if end is None:
        return None
    return f"renew {fmt_local_date(end)}"


def claude_bar(label: str, pct, end_raw) -> str:
    try:
        shown = float(pct) if pct is not None else None
    except (TypeError, ValueError):
        shown = None
    return usage_bar_text(label, shown, fmt_reset(end_raw))


def claude_usage_segments(payload: dict) -> list[str]:
    limits = payload.get("rate_limits") if isinstance(payload.get("rate_limits"), dict) else {}
    remember_claude_limits(limits, payload)
    bits = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        pct = usage_window_percent(window)
        reset = fmt_reset(window.get("resets_at") or window.get("resetsAt"))
        bits.append(usage_bar_text(label, pct, reset))
    return bits


def claude_snapshot_segments(trigger: str) -> list[str]:
    snap = claude_weekly_snapshot(trigger) or {}
    return [
        claude_bar("5h", snap.get("five_hour_percent"), snap.get("five_hour_end")),
        claude_bar("7d", snap.get("percent"), snap.get("period_end")),
    ]


def looks_like_claude(payload: dict) -> bool:
    if isinstance(payload.get("rate_limits"), dict):
        return True
    model = payload.get("model") if isinstance(payload.get("model"), dict) else {}
    mid = str(model.get("id") or model.get("display_name") or "")
    return "claude" in mid.lower() or "opus" in mid.lower() or "sonnet" in mid.lower() or "haiku" in mid.lower()


def looks_like_grok(payload: dict) -> bool:
    if payload.get("trigger") in ("state", "refresh_interval"):
        return True
    ctx = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    if "context_tokens" in ctx or "session_input_tokens" in ctx:
        return True
    model = payload.get("model") if isinstance(payload.get("model"), dict) else {}
    mid = str(model.get("id") or model.get("display_name") or "")
    return "grok" in mid.lower()


def usage_segments(payload: dict, home: Path, trigger: str) -> list[str]:
    claude_bits = claude_usage_segments(payload)
    if claude_bits:
        return claude_bits
    if looks_like_claude(payload):
        return claude_snapshot_segments(trigger)
    if looks_like_grok(payload):
        snap = weekly_snapshot(home, trigger)
        bits = [weekly_segment(snap)]
        account = account_segment(snap)
        if account:
            bits.append(account)
        return bits
    return []


def session_segments(payload: dict) -> list[str]:
    workspace = payload.get("workspace") if isinstance(payload.get("workspace"), dict) else {}
    ctx = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    cost = payload.get("cost") if isinstance(payload.get("cost"), dict) else {}
    turn = payload.get("turn") if isinstance(payload.get("turn"), dict) else {}

    cwd = workspace.get("current_dir") or payload.get("cwd") or ""
    parts = [basename(str(cwd)) if cwd else "?"]

    pct = ctx.get("used_percentage")
    if pct is not None:
        try:
            parts.append(f"{int(float(pct))}% ctx")
        except (TypeError, ValueError):
            pass

    cost_s = fmt_cost(cost.get("total_cost_usd"))
    if cost_s:
        parts.append(cost_s)

    timer = fmt_timer(turn.get("started_at_ms"))
    if timer:
        parts.append(timer)

    session = payload.get("session_name")
    if isinstance(session, str) and session.strip():
        parts.append(session.strip()[:40])

    return parts


def parse_cli(argv: list[str]) -> tuple[str, str]:
    fmt = "tui"
    slot = "all"
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--format", "-f") and i + 1 < len(argv):
            fmt = argv[i + 1].strip().lower()
            i += 2
            continue
        if arg.startswith("--format="):
            fmt = arg.split("=", 1)[1].strip().lower()
            i += 1
            continue
        if arg in ("--slot", "-s") and i + 1 < len(argv):
            slot = argv[i + 1].strip().lower()
            i += 2
            continue
        if arg.startswith("--slot="):
            slot = arg.split("=", 1)[1].strip().lower()
            i += 1
            continue
        if arg == "--btt":
            fmt = "btt"
            i += 1
            continue
        if arg in ("--touchbar", "--mtmr"):
            fmt = "touchbar"
            i += 1
            continue
        if arg == "--plain":
            fmt = "plain"
            i += 1
            continue
        i += 1
    fmt = {"tb": "touchbar", "mtmr": "touchbar", "json": "btt", "text": "plain"}.get(fmt, fmt)
    if fmt not in ("tui", "plain", "touchbar", "btt", "slots"):
        fmt = "tui"
    if slot in ("account", "renew"):
        slot = "trial"
    if slot == "trial":
        slot = "codex"
    if slot == "claude":
        slot = "week"
    if slot not in ("all", "week", "codex", "session"):
        slot = "all"
    return fmt, slot


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def live_session_cwd(home: Path) -> str | None:
    path = home / "active_sessions.json"
    try:
        rows = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(rows, list):
        return None
    best = None
    best_at = ""
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            pid_n = int(row.get("pid"))
        except (TypeError, ValueError):
            continue
        if not pid_alive(pid_n):
            continue
        opened = str(row.get("opened_at") or "")
        if best is None or opened >= best_at:
            best = row
            best_at = opened
    if not best:
        return None
    cwd = best.get("cwd")
    return basename(str(cwd)) if cwd else None


def reset_remaining(end_raw) -> int | None:
    if isinstance(end_raw, (int, float)):
        return int(end_raw - time.time())
    if isinstance(end_raw, str) and end_raw:
        end = parse_expiry(end_raw)
        if end is not None:
            return int((end - datetime.now(timezone.utc)).total_seconds())
    return None


def compact_reset(end_raw) -> str | None:
    remaining = reset_remaining(end_raw)
    if remaining is None:
        return None
    return fmt_reset_seconds(remaining)


def compact_reset_short(end_raw) -> str | None:
    """One unit so two provider buttons still fit on the Touch Bar."""
    remaining = reset_remaining(end_raw)
    if remaining is None:
        return None
    if remaining <= 0:
        return "0m"
    days, rem = divmod(remaining, 86400)
    hours, rem = divmod(rem, 3600)
    if days:
        return f"{days}d"
    if hours:
        return f"{hours}h"
    return f"{rem // 60}m"


def compact_bar(pct: float, width: int = COMPACT_BAR_WIDTH) -> str:
    """Full/empty blocks only. Partial shades do not render on the Touch Bar."""
    clamped = max(0.0, min(100.0, pct))
    filled = int(round(clamped * width / 100.0))
    if clamped > 0 and filled == 0:
        filled = 1
    filled = min(width, max(0, filled))
    return "█" * filled + "·" * (width - filled)


def snapshot_has_usage(snap: dict | None) -> bool:
    if not isinstance(snap, dict):
        return False
    for key in ("percent", "five_hour_percent"):
        if snap.get(key) is not None:
            return True
    return False


# Worst case is "Claude 5h ████ 100% 23h 7d ████ 100% 23h" (43).
# The Touch Bar strip refuses anything longer by dropping the reset times.
TOUCH_PAIR_MAX = 44


def compact_window(
    label: str,
    pct,
    end_raw,
    width: int = DUAL_BAR_WIDTH,
    *,
    reset: bool = True,
) -> tuple[str, str]:
    try:
        value = float(pct)
    except (TypeError, ValueError):
        return f"{label} —", "90"
    shown = f"{value:.0f}%"
    parts = [label, compact_bar(value, width), shown]
    if reset:
        short = compact_reset_short(end_raw)
        if short:
            parts.append(short)
    return " ".join(parts), bar_color(value)


def compact_pair(name: str, snap: dict | None) -> tuple[str, str]:
    five_pct = None if not snap else snap.get("five_hour_percent")
    five_end = None if not snap else snap.get("five_hour_end")
    week_pct = None if not snap else snap.get("percent")
    week_end = None if not snap else snap.get("period_end")
    five_text, five_color = compact_window("5h", five_pct, five_end)
    week_text, week_color = compact_window("7d", week_pct, week_end)
    text = f"{name} {five_text} {week_text}"
    if len(text) > TOUCH_PAIR_MAX:
        five_text, five_color = compact_window("5h", five_pct, five_end, reset=False)
        week_text, week_color = compact_window("7d", week_pct, week_end, reset=False)
        text = f"{name} {five_text} {week_text}"
    return text, worse_color([five_color, week_color])


def compact_usage(label: str, snap: dict | None) -> tuple[str, str] | None:
    if not snap:
        return f"{label} —", "90"
    try:
        pct = float(snap["percent"])
    except (KeyError, TypeError, ValueError):
        return f"{label} —", "90"
    shown = f"{pct:.0f}" if pct >= 10 else f"{pct:.1f}"
    parts = [label, compact_bar(pct), f"{shown}%"]
    reset = compact_reset(snap.get("period_end"))
    if reset:
        parts.append(reset)
    return " ".join(parts), bar_color(pct)


def compact_account(snap: dict | None) -> tuple[str, str] | None:
    if not snap:
        return None
    if snap.get("is_trial"):
        end = parse_expiry(snap.get("trial_end"))
        if end is None:
            return None
        remaining = int((end - datetime.now(timezone.utc)).total_seconds())
        left = fmt_reset_seconds(remaining)
        pct = trial_remaining_pct(snap, end)
        if remaining <= 0:
            return "trial ended", "31"
        if pct is not None:
            shown = f"{pct:.0f}" if pct >= 10 else f"{pct:.1f}"
            return (
                f"trial {compact_bar(pct)} {shown}% {left}",
                remaining_bar_color(pct),
            )
        if remaining <= 12 * 3600:
            color = "31"
        elif remaining <= 36 * 3600:
            color = "33"
        else:
            color = "32"
        return f"trial {left}", color
    end = parse_expiry(snap.get("renew_at"))
    if end is None:
        return None
    return f"renew {fmt_local_date(end)}", "90"


def touch_basename(path: str) -> str:
    name = basename(path)
    if len(name) <= 18:
        return name
    return name[:17] + "…"


def compact_session(payload: dict, home: Path) -> tuple[str, str] | None:
    workspace = payload.get("workspace") if isinstance(payload.get("workspace"), dict) else {}
    cwd = workspace.get("current_dir") or payload.get("cwd") or ""
    ctx = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    parts: list[str] = []
    if cwd:
        parts.append(touch_basename(str(cwd)))
    else:
        live = live_session_cwd(home)
        if live:
            parts.append(touch_basename(live))
    pct = ctx.get("used_percentage")
    if pct is not None:
        try:
            parts.append(f"{int(float(pct))}%")
        except (TypeError, ValueError):
            pass
    if not parts:
        return None
    return " ".join(parts), "90"


def collect_compact(payload: dict, home: Path, trigger: str) -> list[tuple[str, str, str]]:
    remember_claude_limits(payload.get("rate_limits"), payload)
    claude_snap = claude_weekly_snapshot(trigger)
    codex_snap = codex_weekly_snapshot(home, trigger)
    items: list[tuple[str, str, str]] = []
    week = compact_pair("Claude", claude_snap)
    if week:
        items.append(("week",) + week)
    codex = compact_pair("Codex", codex_snap)
    if codex:
        items.append(("codex",) + codex)
    session = compact_session(payload, home)
    if session:
        items.append(("session",) + session)
    return items


def worse_color(colors: list[str]) -> str:
    rank = {"31": 3, "33": 2, "32": 1, "90": 0, "0": 0}
    best = "90"
    best_n = -1
    for color in colors:
        n = rank.get(color, 0)
        if n > best_n:
            best, best_n = color, n
    return best


def ansi_wrap(text: str, color: str) -> str:
    return f"\033[{color}m{text}\033[0m"


def btt_rgba(color: str, *, background: bool = False) -> str:
    r, g, b = ANSI_RGB.get(color, ANSI_RGB["0"])
    if background:
        return f"{max(0, r // 6)},{max(0, g // 6)},{max(0, b // 6)},255"
    return f"{r},{g},{b},255"


def touch_meter(pct_raw, end_raw, *, when: str) -> dict:
    """when is clock, day, or none. An ended window is blank until the next fetch."""
    end = parse_expiry(end_raw) if isinstance(end_raw, str) else None
    try:
        pct = number(pct_raw, None)
    except (TypeError, ValueError):
        pct = None
    now = datetime.now(timezone.utc)
    if end is not None and end <= now:
        pct = None
        end = None
    label = ""
    resets_at = None
    if end is not None:
        resets_at = int(end.timestamp())
        if when == "clock":
            label = fmt_local_hm(end)
        elif when == "day":
            label = fmt_local_day_hm(end)
    if pct is None:
        color = "90"
    else:
        pct = max(0.0, min(100.0, pct))
        color = bar_color(pct)
    return {"pct": pct, "end": label, "resets_at": resets_at, "color": btt_rgba(color)}


def touch_card(name: str, snap: dict | None, *, weekly_when: str) -> dict:
    snap = snap or {}
    error = snap.get("error")
    # Reader renewal does not establish the desktop app's login state. An endpoint throttle also says nothing about inference capacity.
    # Keep the exact fetch failure available, but describe this as unavailable
    # usage in the installed UI instead of asking the user to sign out/in.
    fetch_error = error if name == "Claude" else None
    if name == "Claude" and error in ("sign_in_required", "sign_in_expired", "rate_limited"):
        error = "usage_unavailable"
    card = {
        "name": name,
        "fetched_at": snap.get("fetched_at"),
        "error": error,
        "fetch_error": fetch_error,
        "retry_at": snap.get("retry_at"),
        "source": snap.get("credential_source") or snap.get("source"),
        "five_hour": touch_meter(snap.get("five_hour_percent"), snap.get("five_hour_end"), when="clock"),
        "seven_day": touch_meter(snap.get("percent"), snap.get("period_end"), when=weekly_when),
    }
    provider = "claude" if name == "Claude" else "codex"
    path = cache_file("statusline-" + provider + "-weekly.json")
    meta = trusted_server_retry(read_json(path.with_name(path.name + ".refresh.json")) or {})
    if provider == "claude": meta = normalize_recovery(meta, snap)
    interval = poll_interval(snap, meta)
    card["recovery_state"] = "recovering" if provider == "claude" and recovering(meta) else "normal"
    card["recovery_successes"] = int(number(meta.get("recovery_successes")))
    card["request_interval_seconds"] = recovery_interval(meta) if card["recovery_state"] == "recovering" else interval
    card["diagnostics"] = {k: meta[k] for k in ("current_failure", "last_failure", "attempts") if k in meta}
    card["poll_interval_seconds"] = interval
    card["next_refresh_at"] = provider_deadline(snap, meta, interval)
    card["request"] = REQUESTS.get(provider) or {"reason": "cache-only" if CACHE_ONLY else REFRESH_REASON,
                                                  "attempted": False, "deferred_by": None, "deferred_until": None}
    sources = set()
    for window in ("five_hour", "seven_day"):
        card[window]["fetched_at"] = snap.get(window + "_fetched_at")
        card[window]["observed_at"] = snap.get(window + "_observed_at")
        card[window]["freshness_basis"] = snap.get(window + "_freshness_basis", "unknown")
        card[window]["reading_source"] = snap.get(window + "_reading_source", "cache")
        card[window]["is_fresh"] = window_fresh(snap, window, interval)
        sources.add(card[window]["reading_source"])
    card["reading_source"] = next(iter(sources)) if len(sources) == 1 else "mixed"
    return card


def render_slots(payload: dict, home: Path, trigger: str) -> None:
    """Selected providers retain the original top-level slot keys."""
    if not CACHE_ONLY:
        remember_claude_limits(payload.get("rate_limits"), payload)
    cards = {}
    if SELECTED_PROVIDER in ("all", "claude"):
        cards["week"] = touch_card("Claude", claude_weekly_snapshot(trigger), weekly_when="none")
    if SELECTED_PROVIDER in ("all", "codex"):
        cards["codex"] = touch_card("Codex", codex_weekly_snapshot(home, trigger), weekly_when="day")
    print(json.dumps(cards, ensure_ascii=False))


def configure_refresh(argv):
    global TEST_CONFIG, REFRESH_REASON, CACHE_ONLY, SELECTED_PROVIDER
    global CLAUDE_USAGE_URL, CODEX_USAGE_URL
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--provider", choices=["all", "claude", "codex"], default="all")
    parser.add_argument("--cache-only", action="store_true")
    parser.add_argument("--refresh-reason", choices=["automatic", "manual", "provider-start", "wake"], default="automatic")
    parser.add_argument("--test-config")
    opts, rest = parser.parse_known_args(argv)
    if not opts.test_config and any(name.startswith("USAGE_TEST_") for name in os.environ):
        raise SystemExit("USAGE_TEST_* variables are set; they are only valid with --test-config")
    REFRESH_REASON, CACHE_ONLY, SELECTED_PROVIDER = opts.refresh_reason, opts.cache_only, opts.provider
    if opts.test_config:
        from urllib.parse import urlparse
        if not os.environ.get("USAGE_TEST_ROOT", "").startswith("/"):
            raise ValueError("Test mode needs USAGE_TEST_ROOT set to an absolute path")
        work = Path(os.environ["USAGE_TEST_ROOT"]).resolve()

        def isolated(raw, label):
            """An absolute path that resolves strictly under USAGE_TEST_ROOT."""
            if not isinstance(raw, str) or not Path(raw).is_absolute():
                raise ValueError(f"Test {label} must be an absolute path")
            resolved = Path(raw).resolve()
            if resolved == work or not resolved.is_relative_to(work):
                raise ValueError(f"Test {label} must be isolated under USAGE_TEST_ROOT")
            return resolved

        isolated(opts.test_config, "config file")
        TEST_CONFIG = json.loads(Path(opts.test_config).read_text())
        for name in ("claude_url", "codex_url") + (("claude_token_url",) if TEST_CONFIG.get("claude_store_file") else ()):
            url = TEST_CONFIG[name]
            parsed = urlparse(url)
            if parsed.scheme != "http" or not ipaddress.ip_address(parsed.hostname).is_loopback:
                raise ValueError("Test endpoints must be literal HTTP loopback addresses")
        if isolated(TEST_CONFIG.get("cache_dir"), "cache") == (project_dir() / "cache").resolve():
            raise ValueError("Test cache must be isolated and absolute")
        if TEST_CONFIG.get("claude_store_file"):
            isolated(TEST_CONFIG["claude_store_file"], "sign-in store")
            home = isolated(TEST_CONFIG.get("claude_home"), "Claude home")
            # Renewal also locks <claude_home>.lock beside the home.
            isolated(str(home) + ".lock", "refresh lock")
            isolated(str(home / ".oauth_refresh.lock"), "refresh lock")
        CLAUDE_USAGE_URL, CODEX_USAGE_URL = TEST_CONFIG["claude_url"], TEST_CONFIG["codex_url"]
    return rest


def render_compact(payload: dict, home: Path, trigger: str, fmt: str, slot: str) -> None:
    items = collect_compact(payload, home, trigger)
    if slot != "all":
        items = [item for item in items if item[0] == slot]
    if fmt == "btt":
        if not items:
            print(json.dumps({"text": "", "font_color": "0,0,0,0", "background_color": "0,0,0,0"}))
            return
        text = "  |  ".join(item[1] for item in items)
        color = worse_color([item[2] for item in items])
        print(
            json.dumps(
                {
                    "text": text,
                    "font_color": btt_rgba(color),
                    "font_size": 13,
                    "background_color": btt_rgba(color, background=True),
                },
                ensure_ascii=False,
            )
        )
        return
    if not items:
        return
    if fmt == "plain":
        print(" │ ".join(item[1] for item in items))
        return
    sep = " \033[90m│\033[0m "
    print(sep.join(ansi_wrap(item[1], item[2]) for item in items))


def main() -> None:
    fmt, slot = parse_cli(configure_refresh(sys.argv[1:]))
    if fmt != "slots" and any(arg.split("=", 1)[0] in ("--provider", "--cache-only", "--refresh-reason", "--test-config") for arg in sys.argv[1:]):
        raise SystemExit("Provider/cache/test options require --format slots")
    payload = load_stdin()
    trigger = payload.get("trigger") if isinstance(payload.get("trigger"), str) else "state"
    home = grok_home()
    if fmt == "slots":
        render_slots(payload, home, trigger)
        return
    if fmt != "tui":
        render_compact(payload, home, trigger, fmt, slot)
        return
    sep = " \033[90m│\033[0m "
    bits = usage_segments(payload, home, trigger) + session_segments(payload)
    print(sep.join(bits))


if __name__ == "__main__":
    main()
