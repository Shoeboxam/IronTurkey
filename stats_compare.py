#!/usr/bin/env python3

import argparse
import datetime as dt
import json
import math
import os
import re
import sqlite3
import sys
from dataclasses import dataclass
from typing import Any, Iterable, Optional, Set, Tuple

from policy_compare import load_settings_json

DEFAULT_POLICY_DB = "/Library/Application Support/Cold Turkey/data-app.db"
DEFAULT_GOLD_BROWSER_DB = "/Library/Application Support/IronTurkeyLocker/gold/data-browser.db"
DEFAULT_LIVE_BROWSER_DB = "/Library/Application Support/Cold Turkey/data-browser.db"
DEFAULT_GOLD_HELPER_DB = "/Library/Application Support/IronTurkeyLocker/gold/data-helper.db"
DEFAULT_LIVE_HELPER_DB = "/Library/Application Support/Cold Turkey/data-helper.db"

# These tables appear to be usage / blocked-event statistics rather than policy.
# They are monotone if baseline rows in the active policy window still exist, and
# any counters have stayed the same or increased. New rows are allowed.
BROWSER_TABLES = (
    ("stats", ("date", "domain"), ("user",), ("seconds",)),
    ("statsBlocked", ("date", "domain"), ("user",), ()),
    ("statsStrict", ("date", "domain"), ("user",), ("seconds",)),
    ("statsTitle", ("date", "title"), ("user",), ("seconds",)),
    ("statsTitleStrict", ("date", "title"), ("user",), ("seconds",)),
)

HELPER_TABLES = (
    ("statsApp", ("date", "file"), ("user",), ("seconds",)),
    ("statsAppStrict", ("date", "file"), ("user",), ("seconds",)),
    ("statsBlocked", ("date", "file"), ("user",), ()),
    ("statsBlockedTime", ("date", "break"), (), ("seconds",)),
    ("statsTitle", ("date", "title"), ("user",), ("seconds",)),
    ("statsTitleStrict", ("date", "title"), ("user",), ("seconds",)),
)

EXPECTED_BROWSER_SCHEMAS = {
    "stats": ("date", "domain", "seconds", "user"),
    "statsBlocked": ("date", "domain", "user"),
    "statsStrict": ("date", "domain", "seconds", "user"),
    "statsTitle": ("date", "title", "seconds", "user"),
    "statsTitleStrict": ("date", "title", "seconds", "user"),
}

EXPECTED_HELPER_SCHEMAS = {
    "statsApp": ("date", "file", "seconds", "user"),
    "statsAppStrict": ("date", "file", "seconds", "user"),
    "statsBlocked": ("date", "file", "user"),
    "statsBlockedTime": ("date", "break", "seconds", "user"),
    "statsTitle": ("date", "title", "seconds", "user"),
    "statsTitleStrict": ("date", "title", "seconds", "user"),
}

SCHEDULE_START_KEYS = ("start", "startTime", "start_time", "from", "begin", "beginTime")
SCHEDULE_END_KEYS = ("end", "endTime", "end_time", "to", "finish", "finishTime")
SCHEDULE_DAY_KEYS = ("day", "days", "weekday", "weekdays")
DAY_NAMES = {
    "mon": 0,
    "monday": 0,
    "tue": 1,
    "tues": 1,
    "tuesday": 1,
    "wed": 2,
    "wednesday": 2,
    "thu": 3,
    "thur": 3,
    "thurs": 3,
    "thursday": 3,
    "fri": 4,
    "friday": 4,
    "sat": 5,
    "saturday": 5,
    "sun": 6,
    "sunday": 6,
}


@dataclass
class StatsResult:
    relation: str
    reasons: list[str]
    cutoff_epoch: float
    cutoff_source: str

    @property
    def ok(self) -> bool:
        return self.relation != "weaker"


def truthy_enabled(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() not in {"", "0", "false", "no", "off", "none"}
    return bool(value)


def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def local_now(ts: Optional[float] = None) -> dt.datetime:
    if ts is None:
        ts = dt.datetime.now().timestamp()
    return dt.datetime.fromtimestamp(ts)


def start_of_day_epoch(now_epoch: float) -> float:
    now = local_now(now_epoch)
    return now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def parse_epoch_like(value: Any) -> Optional[float]:
    if value in (None, ""):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        if isinstance(value, str):
            text = value.strip()
            try:
                return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
            except ValueError:
                return None
        return None

    # Unix milliseconds.
    if number > 10_000_000_000:
        return number / 1000.0
    # Unix seconds, including modern timestamps.
    if number > 1_000_000_000:
        return number
    return None


def parse_time_of_day_seconds(value: Any) -> Optional[int]:
    if value in (None, ""):
        return None
    if isinstance(value, str):
        text = value.strip()
        match = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?", text)
        if match:
            hours = int(match.group(1))
            minutes = int(match.group(2) or 0)
            seconds = int(match.group(3) or 0)
            if 0 <= hours <= 24 and 0 <= minutes < 60 and 0 <= seconds < 60:
                total = hours * 3600 + minutes * 60 + seconds
                if 0 <= total <= 86400:
                    return total
        try:
            value = float(text)
        except ValueError:
            return None

    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        number = float(value)
        if 0 <= number <= 24:
            # Small integers usually mean hours.
            return int(number * 3600)
        if 0 <= number <= 1440:
            # Cold Turkey-style schedules commonly encode minutes after midnight.
            return int(number * 60)
        if 0 <= number <= 86400:
            return int(number)
    return None


def first_present(mapping: dict[str, Any], keys: Iterable[str]) -> Any:
    for key in keys:
        if key in mapping:
            return mapping[key]
    return None


def normalize_day_value(value: Any) -> Optional[Set[int]]:
    if value in (None, ""):
        return None
    if isinstance(value, str):
        text = value.strip().lower()
        if text in {"all", "every", "daily", "everyday", "week"}:
            return None
        if text in DAY_NAMES:
            return {DAY_NAMES[text]}
        if "," in text:
            out: Set[int] = set()
            for part in text.split(","):
                parsed = normalize_day_value(part.strip())
                if parsed is None:
                    return None
                out |= parsed
            return out
        try:
            value = int(text)
        except ValueError:
            return set()
    if isinstance(value, (list, tuple, set)):
        out: Set[int] = set()
        for item in value:
            parsed = normalize_day_value(item)
            if parsed is None:
                return None
            out |= parsed
        return out
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        number = int(value)
        # Accept both common conventions: Monday=0 and Sunday=0/7.
        if 0 <= number <= 6:
            return {number, (number - 1) % 7}
        if 1 <= number <= 7:
            return {(number - 1) % 7, number % 7}
    return set()


def schedule_entry_active_start(entry: Any, now_epoch: float) -> Tuple[Optional[float], bool]:
    """Return (active_start_epoch, recognized).

    This intentionally recognizes several simple schedule shapes. If an entry has
    an unknown shape, recognized=False makes the caller fall back to a rolling
    recent window rather than silently trusting an incomplete parser.
    """
    if not isinstance(entry, dict):
        return None, False

    start_value = first_present(entry, SCHEDULE_START_KEYS)
    end_value = first_present(entry, SCHEDULE_END_KEYS)
    start_seconds = parse_time_of_day_seconds(start_value)
    end_seconds = parse_time_of_day_seconds(end_value)
    if start_seconds is None or end_seconds is None:
        return None, False

    now = local_now(now_epoch)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    now_tod = int((now - midnight).total_seconds())

    days_value = first_present(entry, SCHEDULE_DAY_KEYS)
    days = normalize_day_value(days_value)
    weekday = now.weekday()

    if start_seconds <= end_seconds:
        if days is not None and weekday not in days:
            return None, True
        if start_seconds <= now_tod < end_seconds:
            return midnight.timestamp() + start_seconds, True
        return None, True

    # Overnight interval, e.g. 22:00 -> 06:00.
    if now_tod >= start_seconds:
        if days is not None and weekday not in days:
            return None, True
        return midnight.timestamp() + start_seconds, True

    if now_tod < end_seconds:
        yesterday = now - dt.timedelta(days=1)
        yesterday_weekday = yesterday.weekday()
        if days is not None and yesterday_weekday not in days:
            return None, True
        yesterday_midnight = midnight - dt.timedelta(days=1)
        return yesterday_midnight.timestamp() + start_seconds, True

    return None, True


def block_active_window_start(block: dict[str, Any], now_epoch: float) -> Tuple[Optional[float], bool]:
    if not truthy_enabled(block.get("enabled")):
        return None, True

    # Runtime start fields are useful for timer/lock modes if present.
    start_time = parse_epoch_like(block.get("startTime"))
    if start_time is not None and start_time <= now_epoch:
        return start_time, True

    schedule = block.get("schedule")
    if isinstance(schedule, list) and schedule:
        any_recognized = False
        starts: list[float] = []
        for entry in schedule:
            start, recognized = schedule_entry_active_start(entry, now_epoch)
            any_recognized = any_recognized or recognized
            if start is not None:
                starts.append(start)
        if starts:
            return min(starts), True
        return None, any_recognized

    # Enabled unscheduled blocks are treated as always-active for today's stats.
    return start_of_day_epoch(now_epoch), True


def active_policy_cutoff(
    policy_db: str,
    now_epoch: float,
    fallback_hours: float,
    max_window_hours: float,
    grace_seconds: float,
) -> tuple[float, str, list[str]]:
    try:
        policy = load_settings_json(policy_db)
    except Exception as exc:
        fallback = now_epoch - fallback_hours * 3600
        return fallback, "fallback", [f"policy window fallback: unable to read policy: {exc}"]

    blocks = policy.get("blocks", {})
    starts: list[float] = []
    unknown_enabled = 0

    if isinstance(blocks, dict):
        for block in blocks.values():
            if not isinstance(block, dict):
                continue
            if not truthy_enabled(block.get("enabled")):
                continue
            start, recognized = block_active_window_start(block, now_epoch)
            if start is not None:
                starts.append(start)
            elif not recognized:
                unknown_enabled += 1

    if starts:
        earliest = min(starts) - grace_seconds
        capped = max(earliest, now_epoch - max_window_hours * 3600)
        source = "active-policy-window"
        if unknown_enabled:
            capped = min(capped, now_epoch - fallback_hours * 3600)
            source = "active-policy-window+fallback"
        return capped, source, []

    fallback = now_epoch - fallback_hours * 3600
    if unknown_enabled:
        return fallback, "fallback", [
            f"policy window fallback: {unknown_enabled} enabled block(s) had unrecognized schedule shape"
        ]

    # No enabled block looked active. Keep a small recent window anyway so stats
    # edits around boundary conditions do not become invisible.
    return now_epoch - min(fallback_hours, 1.0) * 3600, "no-active-blocks", []


def table_exists(conn: sqlite3.Connection, schema: str, table: str) -> bool:
    sql = f"SELECT 1 FROM {quote_ident(schema)}.sqlite_master WHERE type='table' AND name=? LIMIT 1"
    return conn.execute(sql, (table,)).fetchone() is not None


def list_tables(conn: sqlite3.Connection, schema: str) -> set[str]:
    sql = f"SELECT name FROM {quote_ident(schema)}.sqlite_master WHERE type='table'"
    return {row[0] for row in conn.execute(sql)}


def table_columns(conn: sqlite3.Connection, schema: str, table: str) -> tuple[str, ...]:
    sql = f"PRAGMA {quote_ident(schema)}.table_info({quote_ident(table)})"
    return tuple(row[1] for row in conn.execute(sql))


def validate_schema(
    conn: sqlite3.Connection,
    db_label: str,
    schema: str,
    expected: dict[str, tuple[str, ...]],
    weaker: list[str],
) -> bool:
    actual_tables = list_tables(conn, schema)
    expected_tables = set(expected)
    ok = True

    missing_tables = expected_tables - actual_tables
    unexpected_tables = actual_tables - expected_tables
    if missing_tables:
        weaker.append(f"{db_label} ({schema}): missing expected tables {sorted(missing_tables)}")
        ok = False
    if unexpected_tables:
        weaker.append(f"{db_label} ({schema}): unexpected tables present {sorted(unexpected_tables)}")
        ok = False

    for table in sorted(expected_tables & actual_tables):
        actual_columns = table_columns(conn, schema, table)
        expected_columns = expected[table]
        if actual_columns != expected_columns:
            weaker.append(
                f"{db_label} ({schema}).{table}: schema changed "
                f"(expected {list(expected_columns)}, got {list(actual_columns)})"
            )
            ok = False

    return ok


def table_cutoff_value(conn: sqlite3.Connection, table: str, cutoff_epoch: float) -> float:
    quoted = quote_ident(table)
    max_values = []
    for schema in ("main", "gold"):
        if not table_exists(conn, schema, table):
            continue
        row = conn.execute(f"SELECT MAX(date) FROM {quote_ident(schema)}.{quoted}").fetchone()
        if row and row[0] is not None:
            try:
                max_values.append(float(row[0]))
            except (TypeError, ValueError):
                pass
    max_date = max(max_values) if max_values else None
    if max_date is None:
        return cutoff_epoch
    if max_date > 10_000_000_000:
        return cutoff_epoch * 1000.0
    if 10_000 <= max_date <= 100_000:
        # Day number, e.g. floor(unix_seconds / 86400).
        return math.floor(cutoff_epoch / 86400.0)
    if 19_000_000 <= max_date <= 30_000_000:
        # YYYYMMDD integer-ish encoding.
        return float(local_now(cutoff_epoch).strftime("%Y%m%d"))
    return cutoff_epoch


def identity_diff_expr(identity_columns: tuple[str, ...]) -> list[str]:
    return [f"l.{quote_ident(column)} IS NOT b.{quote_ident(column)}" for column in identity_columns]


def join_expr(key_columns: tuple[str, ...]) -> str:
    return " AND ".join(f"l.{quote_ident(column)} = b.{quote_ident(column)}" for column in key_columns)


def missing_expr(key_columns: tuple[str, ...]) -> str:
    # Any non-date key column being NULL after the LEFT JOIN indicates absence.
    marker = key_columns[-1]
    return f"l.{quote_ident(marker)} IS NULL"


def compare_table(
    conn: sqlite3.Connection,
    db_label: str,
    table: str,
    key_columns: tuple[str, ...],
    identity_columns: tuple[str, ...],
    counter_columns: tuple[str, ...],
    cutoff_epoch: float,
    weaker: list[str],
    stronger: list[str],
) -> None:
    if not table_exists(conn, "gold", table):
        if table_exists(conn, "main", table):
            weaker.append(f"{db_label}.{table}: missing protected baseline table")
        return
    if not table_exists(conn, "main", table):
        weaker.append(f"{db_label}.{table}: missing live table")
        return

    quoted_table = quote_ident(table)
    cutoff_value = table_cutoff_value(conn, table, cutoff_epoch)
    join = join_expr(key_columns)
    bad_conditions = [missing_expr(key_columns)]
    bad_conditions.extend(identity_diff_expr(identity_columns))
    bad_conditions.extend(
        f"l.{quote_ident(column)} IS NULL OR l.{quote_ident(column)} < b.{quote_ident(column)}"
        for column in counter_columns
    )
    bad_where = " OR ".join(f"({condition})" for condition in bad_conditions)

    bad_sql = f"""
        SELECT COUNT(*)
        FROM gold.{quoted_table} AS b
        LEFT JOIN main.{quoted_table} AS l ON {join}
        WHERE b.date >= ? AND ({bad_where})
    """
    bad_count = int(conn.execute(bad_sql, (cutoff_value,)).fetchone()[0])
    if bad_count:
        weaker.append(
            f"{db_label}.{table}: {bad_count} baseline row(s) in active window were deleted, changed, or reduced"
        )
        return

    positive_conditions = [missing_expr(key_columns).replace("l.", "b.")]
    # For a live row, b.<marker> IS NULL means new row. Counter increases are also monotone.
    marker = key_columns[-1]
    positive_conditions = [f"b.{quote_ident(marker)} IS NULL"]
    positive_conditions.extend(
        f"l.{quote_ident(column)} > b.{quote_ident(column)}" for column in counter_columns
    )
    positive_where = " OR ".join(f"({condition})" for condition in positive_conditions)
    positive_sql = f"""
        SELECT COUNT(*)
        FROM main.{quoted_table} AS l
        LEFT JOIN gold.{quoted_table} AS b ON {join}
        WHERE l.date >= ? AND ({positive_where})
    """
    positive_count = int(conn.execute(positive_sql, (cutoff_value,)).fetchone()[0])
    if positive_count:
        stronger.append(f"{db_label}.{table}: {positive_count} monotone stats update(s) in active window")


def compare_stats_db(
    db_label: str,
    gold_path: str,
    live_path: str,
    tables: tuple[tuple[str, tuple[str, ...], tuple[str, ...], tuple[str, ...]], ...],
    expected_schemas: dict[str, tuple[str, ...]],
    cutoff_epoch: float,
    weaker: list[str],
    stronger: list[str],
) -> None:
    if not os.path.exists(gold_path) and not os.path.exists(live_path):
        return
    if not os.path.exists(gold_path):
        weaker.append(f"{db_label}: missing protected baseline database")
        return
    if not os.path.exists(live_path):
        weaker.append(f"{db_label}: missing live database")
        return

    conn = sqlite3.connect(f"file:{live_path}?mode=ro", uri=True)
    try:
        conn.execute("ATTACH DATABASE ? AS gold", (f"file:{gold_path}?mode=ro&immutable=1",))
        live_ok = validate_schema(conn, db_label, "main", expected_schemas, weaker)
        gold_ok = validate_schema(conn, db_label, "gold", expected_schemas, weaker)
        if not (live_ok and gold_ok):
            return
        for table, key_columns, identity_columns, counter_columns in tables:
            compare_table(
                conn,
                db_label,
                table,
                key_columns,
                identity_columns,
                counter_columns,
                cutoff_epoch,
                weaker,
                stronger,
            )
    finally:
        conn.close()


def compare_stats(
    policy_db: str,
    gold_browser_db: str,
    live_browser_db: str,
    gold_helper_db: str,
    live_helper_db: str,
    now_epoch: float,
    fallback_hours: float,
    max_window_hours: float,
    grace_seconds: float,
) -> StatsResult:
    cutoff_epoch, cutoff_source, window_reasons = active_policy_cutoff(
        policy_db,
        now_epoch,
        fallback_hours,
        max_window_hours,
        grace_seconds,
    )
    weaker: list[str] = []
    stronger: list[str] = []
    stronger.extend(window_reasons)

    compare_stats_db(
        "data-browser.db",
        gold_browser_db,
        live_browser_db,
        BROWSER_TABLES,
        EXPECTED_BROWSER_SCHEMAS,
        cutoff_epoch,
        weaker,
        stronger,
    )
    compare_stats_db(
        "data-helper.db",
        gold_helper_db,
        live_helper_db,
        HELPER_TABLES,
        EXPECTED_HELPER_SCHEMAS,
        cutoff_epoch,
        weaker,
        stronger,
    )

    if weaker:
        return StatsResult("weaker", weaker, cutoff_epoch, cutoff_source)
    if stronger:
        return StatsResult("stronger", stronger, cutoff_epoch, cutoff_source)
    return StatsResult("equal", [], cutoff_epoch, cutoff_source)


def format_summary(result: StatsResult, limit: int = 12) -> str:
    cutoff = dt.datetime.fromtimestamp(result.cutoff_epoch).isoformat(timespec="seconds")
    header = {
        "equal": "Statistics databases are monotone in the active policy window.",
        "stronger": "Statistics databases contain monotone updates in the active policy window.",
        "weaker": "Statistics databases were reduced or changed in the active policy window.",
    }[result.relation]
    lines = [header, f"Window starts at {cutoff} ({result.cutoff_source})."]
    if result.reasons:
        lines.extend(["", "Summary:"])
        shown = result.reasons[:limit]
        lines.extend(f"- {reason}" for reason in shown)
        remaining = len(result.reasons) - len(shown)
        if remaining > 0:
            lines.append(f"- ... and {remaining} more")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare Cold Turkey stats databases against a monotone baseline over the active policy window."
    )
    parser.add_argument("--policy-db", default=DEFAULT_POLICY_DB)
    parser.add_argument("--gold-browser-db", default=DEFAULT_GOLD_BROWSER_DB)
    parser.add_argument("--live-browser-db", default=DEFAULT_LIVE_BROWSER_DB)
    parser.add_argument("--gold-helper-db", default=DEFAULT_GOLD_HELPER_DB)
    parser.add_argument("--live-helper-db", default=DEFAULT_LIVE_HELPER_DB)
    parser.add_argument("--fallback-hours", type=float, default=48.0)
    parser.add_argument("--max-window-hours", type=float, default=72.0)
    parser.add_argument("--grace-seconds", type=float, default=300.0)
    parser.add_argument("--now", type=float, default=None, help="Unix epoch seconds for deterministic tests.")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args()

    now_epoch = args.now if args.now is not None else dt.datetime.now().timestamp()
    result = compare_stats(
        args.policy_db,
        args.gold_browser_db,
        args.live_browser_db,
        args.gold_helper_db,
        args.live_helper_db,
        now_epoch,
        args.fallback_hours,
        args.max_window_hours,
        args.grace_seconds,
    )

    if args.json:
        print(
            json.dumps(
                {
                    "ok": result.ok,
                    "relation": result.relation,
                    "cutoff_epoch": result.cutoff_epoch,
                    "cutoff_iso": dt.datetime.fromtimestamp(result.cutoff_epoch).isoformat(timespec="seconds"),
                    "cutoff_source": result.cutoff_source,
                    "reasons": result.reasons,
                },
                indent=2,
            )
        )
    elif args.summary:
        print(format_summary(result))
    else:
        print(format_summary(result))

    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
