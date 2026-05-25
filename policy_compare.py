#!/usr/bin/env python3

import argparse
import json
import sqlite3
import sys
from dataclasses import dataclass
from typing import Any, Optional


DEFAULT_GOLD_DB = "/Library/Application Support/IronTurkeyLocker/gold/data-app.db"
DEFAULT_LIVE_DB = "/Library/Application Support/Cold Turkey/data-app.db"
EXPECTED_POLICY_TABLES = {"settings"}
EXPECTED_SETTINGS_COLUMNS = ("key", "value")


GLOBAL_EQUALITY_KEYS = {
    "password",
    "passwordStrict",
    "blockMode",
    "blockEmbedded",
    "blockInactive",
    "blockUnsupported",
    "blockLoginChange",
    "blockTimeChange",
    "blockUserChange",
    "blockTaskManager",
    "blockTaskManagerChrome",
    "blockInstaller",
    "blockScreenTime",
    "blockSplit",
    "blockAllowance",
    "blockCharity",
}

KNOWN_TOP_LEVEL_KEYS = {"settings", "blocks", "additional"}
KNOWN_BLOCK_FIELDS = {
    "apps",
    "autostart",
    "break",
    "customUsers",
    "enabled",
    "exceptions",
    "lock",
    "lockUnblock",
    "password",
    "pomodoroTime",
    "randomTextLength",
    "restartUnblock",
    "schedule",
    "startTime",
    "timer",
    "type",
    "users",
    "web",
    "window",
}

# These fields appear to represent actual blocking scope. We only treat a
# superset as "at least as strict".
BLOCK_SUPERSET_FIELDS = {"web", "apps"}

# Exceptions weaken a block, so only a subset is acceptable.
BLOCK_SUBSET_FIELDS = {"exceptions"}

# These fields are security-relevant but their ordering is ambiguous, so the
# first prototype requires exact equality.
BLOCK_EQUALITY_FIELDS = {
    "break",
    "lockUnblock",
    "password",
    "pomodoroTime",
    "randomTextLength",
    "restartUnblock",
    "type",
    "customUsers",
    "window",
}

# These fields look runtime-ish and are ignored in the first prototype.
BLOCK_IGNORED_FIELDS = {"startTime"}
TOP_LEVEL_IGNORED_KEYS = {"additional"}


@dataclass
class ComparisonResult:
    relation: str
    reasons: list[str]

    @property
    def ok(self) -> bool:
        return self.relation != "weaker"


def decode_payload(value: str) -> str:
    if not value.startswith("CTB17"):
        raise ValueError("Unexpected settings encoding prefix")
    data = value[5:]
    return "".join(chr(int(data[i : i + 2], 16) - 0x11) for i in range(0, len(data), 2))


def connect_readonly(db_path: str, immutable: bool = False) -> sqlite3.Connection:
    uris = []
    if immutable:
        uris.append(f"file:{db_path}?mode=ro&immutable=1")
    else:
        uris.append(f"file:{db_path}?mode=ro")
        uris.append(f"file:{db_path}?mode=ro&immutable=1")

    last_error: Exception | None = None
    for uri in uris:
        try:
            return sqlite3.connect(uri, uri=True)
        except sqlite3.OperationalError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error
    raise sqlite3.OperationalError(f"unable to open database file: {db_path}")


def load_settings_json(db_path: str, immutable: bool = False) -> dict[str, Any]:
    conn = connect_readonly(db_path, immutable=immutable)
    try:
        actual_tables = {
            row[0]
            for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        if actual_tables != EXPECTED_POLICY_TABLES:
            raise ValueError(
                f"Unexpected policy DB tables in {db_path}: expected {sorted(EXPECTED_POLICY_TABLES)}, got {sorted(actual_tables)}"
            )

        actual_columns = tuple(
            row[1] for row in conn.execute("PRAGMA table_info(settings)")
        )
        if actual_columns != EXPECTED_SETTINGS_COLUMNS:
            raise ValueError(
                f"Unexpected settings schema in {db_path}: expected {list(EXPECTED_SETTINGS_COLUMNS)}, got {list(actual_columns)}"
            )

        row = conn.execute("SELECT value FROM settings WHERE key = 'settings'").fetchone()
    finally:
        conn.close()
    if not row:
        raise ValueError(f"No settings row found in {db_path}")
    return json.loads(decode_payload(row[0]))


def as_set(value: Any) -> set[str]:
    if isinstance(value, list):
        return {json.dumps(item, sort_keys=True) for item in value}
    raise TypeError(f"Expected list, got {type(value).__name__}")


def normalize_enabled(value: Any) -> Any:
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "false"}:
            return lowered
    return value


def compare_enabled(
    block_name: str,
    gold_value: Any,
    live_value: Any,
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    gold_value = normalize_enabled(gold_value)
    live_value = normalize_enabled(live_value)

    if gold_value == live_value:
        return
    if gold_value == "false" and live_value == "true":
        stronger_reasons.append(f"block {block_name!r} field 'enabled' became true")
    elif gold_value == "true" and live_value == "false":
        weaker_reasons.append(f"block {block_name!r} field 'enabled' became false")
    else:
        weaker_reasons.append(
            f"block {block_name!r} field 'enabled' differs: gold={gold_value!r} live={live_value!r}"
        )


def compare_lock(
    block_name: str,
    gold_value: Any,
    live_value: Any,
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    if gold_value == live_value:
        return
    if gold_value == "none" and live_value != "none":
        stronger_reasons.append(f"block {block_name!r} field 'lock' became {live_value!r}")
    elif gold_value != "none" and live_value == "none":
        weaker_reasons.append(f"block {block_name!r} field 'lock' became 'none'")
    else:
        weaker_reasons.append(
            f"block {block_name!r} field 'lock' differs: gold={gold_value!r} live={live_value!r}"
        )


def compare_autostart(
    block_name: str,
    gold_value: Any,
    live_value: Any,
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    if gold_value == live_value:
        return
    if gold_value == "none" and live_value != "none":
        stronger_reasons.append(f"block {block_name!r} field 'autostart' became {live_value!r}")
    elif gold_value != "none" and live_value == "none":
        weaker_reasons.append(f"block {block_name!r} field 'autostart' became 'none'")
    else:
        weaker_reasons.append(
            f"block {block_name!r} field 'autostart' differs: gold={gold_value!r} live={live_value!r}"
        )


def compare_users(
    block_name: str,
    gold_value: Any,
    live_value: Any,
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    if gold_value == live_value:
        return
    if gold_value != "all" and live_value == "all":
        stronger_reasons.append(f"block {block_name!r} field 'users' expanded to 'all'")
    elif gold_value == "all" and live_value != "all":
        weaker_reasons.append(f"block {block_name!r} field 'users' narrowed from 'all'")
    else:
        weaker_reasons.append(
            f"block {block_name!r} field 'users' differs: gold={gold_value!r} live={live_value!r}"
        )


def compare_schedule(
    block_name: str,
    gold_value: Any,
    live_value: Any,
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    gold_items = as_set(gold_value or [])
    live_items = as_set(live_value or [])
    missing = gold_items - live_items
    added = live_items - gold_items
    if missing:
        weaker_reasons.append(
            f"block {block_name!r} field 'schedule' lost {len(missing)} required entries"
        )
    if added:
        stronger_reasons.append(
            f"block {block_name!r} field 'schedule' added {len(added)} stricter entries"
        )


def parse_optional_number(value: Any) -> Optional[float]:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def compare_timer(
    block_name: str,
    gold_value: Any,
    live_value: Any,
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    if gold_value == live_value:
        return

    gold_num = parse_optional_number(gold_value)
    live_num = parse_optional_number(live_value)

    if gold_num is not None and live_num is not None:
        if live_num < gold_num:
            stronger_reasons.append(
                f"block {block_name!r} field 'timer' decreased from {gold_value!r} to {live_value!r}"
            )
            return
        if live_num > gold_num:
            weaker_reasons.append(
                f"block {block_name!r} field 'timer' increased from {gold_value!r} to {live_value!r}"
            )
            return

    weaker_reasons.append(
        f"block {block_name!r} field 'timer' differs: gold={gold_value!r} live={live_value!r}"
    )


def compare_global_settings(
    gold: dict[str, Any],
    live: dict[str, Any],
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    gold_settings = gold.get("settings", {})
    live_settings = live.get("settings", {})

    gold_keys = set(gold_settings)
    live_keys = set(live_settings)
    missing_keys = gold_keys - live_keys
    extra_keys = live_keys - gold_keys

    if missing_keys:
        weaker_reasons.append(f"settings missing expected keys: {sorted(missing_keys)}")
    if extra_keys:
        weaker_reasons.append(f"settings has unexpected extra keys: {sorted(extra_keys)}")

    for key in sorted(GLOBAL_EQUALITY_KEYS):
        if gold_settings.get(key) != live_settings.get(key):
            weaker_reasons.append(
                f"settings.{key} differs: gold={gold_settings.get(key)!r} live={live_settings.get(key)!r}"
            )


def compare_blocks(
    gold: dict[str, Any],
    live: dict[str, Any],
    weaker_reasons: list[str],
    stronger_reasons: list[str],
) -> None:
    gold_blocks = gold.get("blocks", {})
    live_blocks = live.get("blocks", {})

    for block_name, gold_block in sorted(gold_blocks.items()):
        if block_name not in live_blocks:
            weaker_reasons.append(f"block {block_name!r} missing from live config")
            continue

        live_block = live_blocks[block_name]

        unknown_gold_fields = set(gold_block) - KNOWN_BLOCK_FIELDS
        unknown_live_fields = set(live_block) - KNOWN_BLOCK_FIELDS
        if unknown_gold_fields:
            weaker_reasons.append(
                f"block {block_name!r} in gold has unknown fields: {sorted(unknown_gold_fields)}"
            )
        if unknown_live_fields:
            weaker_reasons.append(
                f"block {block_name!r} in live has unknown fields: {sorted(unknown_live_fields)}"
            )

        compare_enabled(
            block_name,
            gold_block.get("enabled"),
            live_block.get("enabled"),
            weaker_reasons,
            stronger_reasons,
        )
        compare_lock(
            block_name,
            gold_block.get("lock"),
            live_block.get("lock"),
            weaker_reasons,
            stronger_reasons,
        )
        compare_autostart(
            block_name,
            gold_block.get("autostart"),
            live_block.get("autostart"),
            weaker_reasons,
            stronger_reasons,
        )
        compare_users(
            block_name,
            gold_block.get("users"),
            live_block.get("users"),
            weaker_reasons,
            stronger_reasons,
        )
        compare_schedule(
            block_name,
            gold_block.get("schedule"),
            live_block.get("schedule"),
            weaker_reasons,
            stronger_reasons,
        )
        compare_timer(
            block_name,
            gold_block.get("timer"),
            live_block.get("timer"),
            weaker_reasons,
            stronger_reasons,
        )

        for field in sorted(BLOCK_EQUALITY_FIELDS):
            if field == "customUsers" and (
                gold_block.get("users") != "custom" or live_block.get("users") != "custom"
            ):
                continue
            gold_value = gold_block.get(field)
            live_value = live_block.get(field)
            if gold_value != live_value:
                weaker_reasons.append(
                    f"block {block_name!r} field {field!r} differs: "
                    f"gold={gold_value!r} live={live_value!r}"
                )

        for field in sorted(BLOCK_SUPERSET_FIELDS):
            gold_items = as_set(gold_block.get(field, []))
            live_items = as_set(live_block.get(field, []))
            missing = gold_items - live_items
            added = live_items - gold_items
            if missing:
                weaker_reasons.append(
                    f"block {block_name!r} field {field!r} lost {len(missing)} required entries"
                )
            if added:
                stronger_reasons.append(
                    f"block {block_name!r} field {field!r} added {len(added)} stricter entries"
                )

        for field in sorted(BLOCK_SUBSET_FIELDS):
            gold_items = as_set(gold_block.get(field, []))
            live_items = as_set(live_block.get(field, []))
            added = live_items - gold_items
            removed = gold_items - live_items
            if added:
                weaker_reasons.append(
                    f"block {block_name!r} field {field!r} added {len(added)} new exceptions"
                )
            if removed:
                stronger_reasons.append(
                    f"block {block_name!r} field {field!r} removed {len(removed)} exceptions"
                )

        extra_fields = set(live_block) - set(gold_block) - BLOCK_IGNORED_FIELDS
        if extra_fields:
            weaker_reasons.append(f"block {block_name!r} has unexpected extra fields: {sorted(extra_fields)}")

    for block_name, live_block in sorted(live_blocks.items()):
        if block_name in gold_blocks:
            continue

        unknown_live_fields = set(live_block) - KNOWN_BLOCK_FIELDS
        if unknown_live_fields:
            weaker_reasons.append(
                f"new live block {block_name!r} has unknown fields: {sorted(unknown_live_fields)}"
            )
            continue

        live_enabled = normalize_enabled(live_block.get("enabled"))
        if live_enabled == "false":
            weaker_reasons.append(f"new live block {block_name!r} is disabled")
            continue

        stronger_reasons.append(f"new live block {block_name!r} is present")

        for field in sorted(BLOCK_SUPERSET_FIELDS):
            live_items = as_set(live_block.get(field, []))
            if live_items:
                stronger_reasons.append(
                    f"new live block {block_name!r} field {field!r} adds {len(live_items)} blocked entries"
                )

        for field in sorted(BLOCK_SUBSET_FIELDS):
            live_items = as_set(live_block.get(field, []))
            if live_items:
                stronger_reasons.append(
                    f"new live block {block_name!r} field {field!r} contains {len(live_items)} exceptions"
                )


def compare_policy(gold: dict[str, Any], live: dict[str, Any]) -> ComparisonResult:
    weaker_reasons: list[str] = []
    stronger_reasons: list[str] = []

    unknown_gold_top_level = set(gold) - KNOWN_TOP_LEVEL_KEYS
    unknown_live_top_level = set(live) - KNOWN_TOP_LEVEL_KEYS
    if unknown_gold_top_level:
        weaker_reasons.append(f"gold policy has unknown top-level keys: {sorted(unknown_gold_top_level)}")
    if unknown_live_top_level:
        weaker_reasons.append(f"live policy has unknown top-level keys: {sorted(unknown_live_top_level)}")

    missing_top_level = (set(gold) - TOP_LEVEL_IGNORED_KEYS) - set(live)
    extra_top_level = (set(live) - TOP_LEVEL_IGNORED_KEYS) - set(gold)
    if missing_top_level:
        weaker_reasons.append(f"live policy is missing top-level keys: {sorted(missing_top_level)}")
    if extra_top_level:
        weaker_reasons.append(f"live policy has unexpected top-level keys: {sorted(extra_top_level)}")

    for key in sorted(set(gold) - {"settings", "blocks"} - TOP_LEVEL_IGNORED_KEYS):
        if gold.get(key) != live.get(key):
            weaker_reasons.append(f"top-level key {key!r} differs")

    compare_global_settings(gold, live, weaker_reasons, stronger_reasons)
    compare_blocks(gold, live, weaker_reasons, stronger_reasons)

    if weaker_reasons:
        return ComparisonResult(relation="weaker", reasons=weaker_reasons)
    if stronger_reasons:
        return ComparisonResult(relation="stronger", reasons=stronger_reasons)
    return ComparisonResult(relation="equal", reasons=[])


def format_summary(result: ComparisonResult, limit: int = 12) -> str:
    header = {
        "equal": "Pending changes are equal to the current gold baseline.",
        "stronger": "Pending changes are stricter than the current gold baseline.",
        "weaker": "Pending changes are weaker than the current gold baseline.",
    }[result.relation]

    if not result.reasons:
        return header

    lines = [header, "", "Summary:"]
    shown = result.reasons[:limit]
    lines.extend(f"- {reason}" for reason in shown)
    remaining = len(result.reasons) - len(shown)
    if remaining > 0:
        lines.append(f"- ... and {remaining} more")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare live Cold Turkey policy against a gold baseline."
    )
    parser.add_argument("--gold-db", default=DEFAULT_GOLD_DB)
    parser.add_argument("--live-db", default=DEFAULT_LIVE_DB)
    parser.add_argument(
        "--immutable-live",
        action="store_true",
        help="Open the live DB using SQLite immutable mode for UI-safe read-only review.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON instead of text.",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Emit a concise human-readable summary for review dialogs.",
    )
    args = parser.parse_args()

    gold = load_settings_json(args.gold_db, immutable=True)
    live = load_settings_json(args.live_db, immutable=args.immutable_live)
    result = compare_policy(gold, live)

    if args.json:
        print(json.dumps({"ok": result.ok, "relation": result.relation, "reasons": result.reasons}, indent=2))
    elif args.summary:
        print(format_summary(result))
        return 0
    elif result.relation == "equal":
        print("EQUAL: live policy matches gold.")
    elif result.relation == "stronger":
        print("STRONGER: live policy is stricter than gold.")
        for reason in result.reasons:
            print(f"- {reason}")
    elif result.ok:
        print("OK: live policy is at least as strict as gold.")
    else:
        print("WEAKER: live policy fell below gold.")
        for reason in result.reasons:
            print(f"- {reason}")

    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
