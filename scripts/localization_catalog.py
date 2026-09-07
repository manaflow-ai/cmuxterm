#!/usr/bin/env python3
"""Audit and update the macOS XCStrings catalogs without losing Xcode ordering."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


TARGET_LOCALES = ("de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja")
CATALOGS = (
    "Resources/Localizable.xcstrings",
    "Resources/InfoPlist.xcstrings",
    "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Resources/Localizable.xcstrings",
    "Packages/macOS/CmuxFeedback/Sources/CmuxFeedback/ComposerUI/Resources/Localizable.xcstrings",
    "Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources/Localizable.xcstrings",
    "TunnelExtension/InfoPlist.xcstrings",
)
OMISSIONS_PATH = Path(__file__).with_name("localization-allowed-omissions.json")
PLURALS_PATH = Path(__file__).with_name("localization-plurals.json")
PLACEHOLDER_RE = re.compile(
    r"%(?:(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:hh|h|ll|l|L|z|t|j)?[diouxXeEfFgGcsSpaA@]|%)"
)
MACHINE_MARKER_RE = re.compile(r"(?:TODO|TRANSLATE|MACHINE_TRANSLATION|<translated>|\[translation\])", re.I)


class ObjectPairs(list):
    """A JSON object represented as ordered pairs, including duplicate keys."""


def _pairs_hook(pairs: list[tuple[str, Any]]) -> ObjectPairs:
    return ObjectPairs(pairs)


def _load_pairs(path: Path) -> ObjectPairs:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs_hook)


def _load_plain(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _dump_value(value: Any, level: int = 0) -> str:
    indent = "  " * level
    child_indent = "  " * (level + 1)
    if isinstance(value, ObjectPairs):
        if not value:
            return "{}"
        lines = ["{"]
        for index, (key, item) in enumerate(value):
            suffix = "," if index + 1 < len(value) else ""
            lines.append(f"{child_indent}{json.dumps(key, ensure_ascii=False)}: {_dump_value(item, level + 1)}{suffix}")
        lines.append(f"{indent}}}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "[]"
        lines = ["["]
        for index, item in enumerate(value):
            suffix = "," if index + 1 < len(value) else ""
            lines.append(f"{child_indent}{_dump_value(item, level + 1)}{suffix}")
        lines.append(f"{indent}]")
        return "\n".join(lines)
    return json.dumps(value, ensure_ascii=False)


def _write_pairs(path: Path, value: ObjectPairs) -> None:
    path.write_text(_dump_value(value) + "\n", encoding="utf-8")


def _get(obj: ObjectPairs, key: str, default: Any = None) -> Any:
    for candidate, value in reversed(obj):
        if candidate == key:
            return value
    return default


def _get_pair(obj: ObjectPairs, key: str) -> tuple[int, Any] | None:
    for index in range(len(obj) - 1, -1, -1):
        if obj[index][0] == key:
            return index, obj[index][1]
    return None


def _set(obj: ObjectPairs, key: str, value: Any) -> None:
    pair = _get_pair(obj, key)
    if pair is None:
        obj.append((key, value))
    else:
        obj[pair[0]] = (key, value)


def _plain(value: Any) -> Any:
    if isinstance(value, ObjectPairs):
        result: dict[str, Any] = {}
        for key, item in value:
            result[key] = _plain(item)
        return result
    if isinstance(value, list):
        return [_plain(item) for item in value]
    return value


def _source(entry: dict[str, Any]) -> str:
    return entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", "")


def _placeholders(value: str) -> list[str]:
    return PLACEHOLDER_RE.findall(value)


def _locale_unit(entry: dict[str, Any], locale: str) -> dict[str, Any] | None:
    return entry.get("localizations", {}).get(locale, {}).get("stringUnit")


def _allowed_omissions() -> dict[str, str]:
    if not OMISSIONS_PATH.exists():
        return {}
    data = json.loads(OMISSIONS_PATH.read_text(encoding="utf-8"))
    return {str(key): str(value) for key, value in data.items()}


def _plural_keys() -> set[str]:
    if not PLURALS_PATH.exists():
        return set()
    data = json.loads(PLURALS_PATH.read_text(encoding="utf-8"))
    return {str(key) for key in data}


def _entry_rows(path: Path) -> Iterable[tuple[str, dict[str, Any]]]:
    data = _load_plain(path)
    for key, entry in data.get("strings", {}).items():
        yield key, entry


def _catalog_paths(args: argparse.Namespace) -> list[Path]:
    if args.catalog:
        return [Path(item) for item in args.catalog]
    return [Path(item) for item in CATALOGS]


def command_extract(args: argparse.Namespace) -> int:
    path = Path(args.catalog)
    rows = []
    for key, entry in _entry_rows(path):
        unit = _locale_unit(entry, args.locale)
        if unit and unit.get("state") == "translated":
            continue
        source = _source(entry)
        rows.append(
            {
                "key": key,
                "source": source,
                "comment": entry.get("comment"),
                "placeholders": _placeholders(source),
            }
        )
    start = args.batch * args.batch_size
    selected = rows[start : start + args.batch_size]
    payload = {"catalog": str(path), "locale": args.locale, "batch": args.batch, "total": len(rows), "entries": selected}
    output = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    return 0


def _localized_object(value: str, plural: dict[str, str] | None = None) -> ObjectPairs:
    unit = ObjectPairs([("state", "translated"), ("value", value)])
    pairs: list[tuple[str, Any]] = [("stringUnit", unit)]
    if plural:
        variations = ObjectPairs(
            [
                (
                    "plural",
                    ObjectPairs(
                        [
                            (category, ObjectPairs([("stringUnit", ObjectPairs([("state", "translated"), ("value", text)]))]))
                            for category, text in plural.items()
                        ]
                    ),
                )
            ]
        )
        pairs.append(("variations", variations))
    return ObjectPairs(pairs)


def _merge_localization(entry: ObjectPairs, locale: str, value: str, plural: dict[str, str] | None) -> None:
    localizations = _get(entry, "localizations")
    if not isinstance(localizations, ObjectPairs):
        localizations = ObjectPairs()
        _set(entry, "localizations", localizations)
    localization = _get(localizations, locale)
    if not isinstance(localization, ObjectPairs):
        _set(localizations, locale, _localized_object(value, plural))
        return
    string_unit = _get(localization, "stringUnit")
    if not isinstance(string_unit, ObjectPairs):
        string_unit = ObjectPairs()
        _set(localization, "stringUnit", string_unit)
    _set(string_unit, "state", "translated")
    _set(string_unit, "value", value)
    if plural:
        _set(
            localization,
            "variations",
            _localized_object("", plural)[1][1],
        )


def _merge_entry_pairs(data: ObjectPairs, locale: str, translations: dict[str, dict[str, Any]]) -> set[str]:
    strings = _get(data, "strings")
    if not isinstance(strings, ObjectPairs):
        raise ValueError("catalog has no strings object")
    seen: set[str] = set()
    for key, entry in strings:
        if key not in translations or not isinstance(entry, ObjectPairs):
            continue
        item = translations[key]
        if item.get("omit"):
            localizations = _get(entry, "localizations")
            if isinstance(localizations, ObjectPairs):
                localizations[:] = [(name, value) for name, value in localizations if name != locale]
        else:
            value = item.get("value")
            if not isinstance(value, str):
                raise ValueError(f"translation for {key} must have a string value")
            _merge_localization(entry, locale, value, item.get("plural"))
        seen.add(key)
    return seen


def command_merge(args: argparse.Namespace) -> int:
    path = Path(args.catalog)
    payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
    if isinstance(payload, dict) and "translations" in payload:
        payload = payload["translations"]
    if isinstance(payload, list):
        translations = {item["key"]: item for item in payload}
    elif isinstance(payload, dict):
        translations = {key: (item if isinstance(item, dict) else {"value": item}) for key, item in payload.items()}
    else:
        raise ValueError("translation input must be a list or object")
    data = _load_pairs(path)
    merged = _merge_entry_pairs(data, args.locale, translations)
    missing = set(translations) - merged
    if missing:
        raise ValueError(f"translation keys not found in {path}: {', '.join(sorted(missing)[:5])}")
    _write_pairs(path, data)
    print(f"merged {len(merged)} {args.locale} translations into {path}")
    return 0


def _check_entry(path: Path, key: str, entry: dict[str, Any], locale: str, omissions: dict[str, str]) -> list[str]:
    errors: list[str] = []
    source = _source(entry)
    source_placeholders = _placeholders(source)
    unit = _locale_unit(entry, locale)
    allowed = locale != "ja" and path.resolve() == Path("Resources/Localizable.xcstrings").resolve() and key in omissions
    if unit is None:
        if not allowed:
            errors.append(f"{path}:{key}: missing {locale} entry")
        return errors
    if unit.get("state") != "translated":
        errors.append(f"{path}:{key}: {locale} state is {unit.get('state')!r}")
    value = unit.get("value")
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{path}:{key}: {locale} value is empty")
        return errors
    if _placeholders(value) != source_placeholders:
        errors.append(f"{path}:{key}: {locale} placeholders {_placeholders(value)!r} != {source_placeholders!r}")
    if value == source and not allowed:
        errors.append(f"{path}:{key}: {locale} copies English")
    if MACHINE_MARKER_RE.search(value):
        errors.append(f"{path}:{key}: {locale} contains a machine marker")
    return errors


def command_check(args: argparse.Namespace) -> int:
    omissions = _allowed_omissions()
    plural_keys = _plural_keys()
    errors: list[str] = []
    for path in _catalog_paths(args):
        try:
            data = _load_plain(path)
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{path}: invalid JSON: {exc}")
            continue
        strings = data.get("strings")
        if not isinstance(strings, dict):
            errors.append(f"{path}: missing strings object")
            continue
        for locale in TARGET_LOCALES:
            for key, entry in strings.items():
                errors.extend(_check_entry(path, key, entry, locale, omissions))
                if key in plural_keys:
                    localization = entry.get("localizations", {}).get(locale, {})
                    plural = localization.get("variations", {}).get("plural", {})
                    required_categories = {"zero", "one", "two", "few", "many", "other"} if locale == "ar" else {"one", "other"}
                    missing_categories = required_categories - set(plural)
                    if missing_categories:
                        errors.append(f"{path}:{key}: {locale} missing plural categories {sorted(missing_categories)}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"localization check failed: {len(errors)} error(s)", file=sys.stderr)
        return 1
    print(f"localization check passed: {len(_catalog_paths(args))} catalogs, {len(TARGET_LOCALES)} locales")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract = subparsers.add_parser("extract", help="extract one locale's unfinished entries")
    extract.add_argument("--catalog", required=True)
    extract.add_argument("--locale", required=True, choices=TARGET_LOCALES)
    extract.add_argument("--batch", type=int, default=0)
    extract.add_argument("--batch-size", type=int, default=100)
    extract.add_argument("--output")
    extract.set_defaults(function=command_extract)

    merge = subparsers.add_parser("merge", help="merge translated values into a catalog")
    merge.add_argument("--catalog", required=True)
    merge.add_argument("--locale", required=True, choices=TARGET_LOCALES)
    merge.add_argument("--input", required=True)
    merge.set_defaults(function=command_merge)

    check = subparsers.add_parser("check", help="validate macOS catalog parity")
    check.add_argument("--catalog", action="append")
    check.set_defaults(function=command_check)
    return parser


if __name__ == "__main__":
    try:
        parsed_args = build_parser().parse_args()
        raise SystemExit(parsed_args.function(parsed_args))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
