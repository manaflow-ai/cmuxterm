#!/usr/bin/env python3

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("localization_catalog", ROOT / "scripts/localization_catalog.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def counted(parent, one, other, specifier="d"):
    return {
        **unit(parent),
        "substitutions": {
            "count": {
                "argNum": 1,
                "formatSpecifier": specifier,
                "variations": {"plural": {"one": one, "other": other}},
            }
        },
    }


class LocalizationCatalogTests(unittest.TestCase):
    def test_rejects_lost_line_breaks(self):
        self.assertTrue(MODULE.validate_localization("Name: %@\nStatus: %@", unit("Name: %@ Status: %@"), "de"))

    def test_rejects_strings_outside_the_catalog_strings_object(self):
        catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0",
                   "orphan": {"localizations": {"en": unit("Ignored by Xcode")}}}
        with self.assertRaisesRegex(ValueError, "outside.*strings"):
            MODULE.catalog_entries(json.dumps(catalog))

    def test_shared_spelling_exception_is_locale_specific_and_never_allows_omission(self):
        entry = MODULE.Member("terminal", {"localizations": {"en": unit("Terminal"), "de": unit("Terminal"), "ja": unit("Terminal")}}, 0, 0)
        metadata = {"terminal": {"source": "Terminal", "identityLocales": {"de": "Established German technical term."}}}
        self.assertEqual(MODULE.check_entry(entry, "de", metadata, {}), [])
        self.assertTrue(MODULE.check_entry(entry, "ja", metadata, {}))
        del entry.value["localizations"]["de"]
        self.assertIn("missing locale entry", MODULE.check_entry(entry, "de", metadata, {}))

    def test_japanese_invariant_requires_entry_but_allows_literal(self):
        entry = MODULE.Member("brand", {"localizations": {"en": unit("cmux"), "ja": unit("cmux")}}, 0, 0)
        omissions = {"brand": {"source": "cmux", "class": "brand"}}
        self.assertEqual(MODULE.check_entry(entry, "ja", omissions, {}), [])
        del entry.value["localizations"]["ja"]
        self.assertIn("missing locale entry", MODULE.check_entry(entry, "ja", omissions, {}))

    def test_english_substitutions_and_plural_metadata_validate(self):
        english = counted("%#@count@", unit("%d match"), unit("%d matches"))
        german = counted("%#@count@", unit("%d Treffer"), unit("%d Treffer"))
        entry = MODULE.Member("matches", {"localizations": {"en": english, "de": german}}, 0, 0)
        counts = {"matches": {"source": "%d matches", "arguments": [1]}}
        for locale in ("en", "de"):
            with self.subTest(locale=locale):
                self.assertEqual(MODULE.check_entry(entry, locale, {}, counts), [])

    def test_each_required_plural_leaf_needs_text(self):
        for bad_leaf in ({}, {"stringUnit": {"state": "translated", "value": ""}}):
            for position in ("one", "other"):
                with self.subTest(leaf=bad_leaf, position=position):
                    german = counted("%#@count@ Treffer", unit("%d"), unit("%d"))
                    german["substitutions"]["count"]["variations"]["plural"][position] = bad_leaf
                    self.assertTrue(MODULE.validate_localization("%d matches", german, "de"))

    def test_substitution_cannot_hide_copied_english(self):
        german = counted("Treffer: %#@count@", unit("%d matches"), unit("%d matches"))
        self.assertTrue(MODULE.validate_localization("%d matches", german, "de"))

    def test_plural_only_numeric_leaves_are_valid_when_parent_is_translated(self):
        german = counted("%#@count@ Treffer", unit("%d"), unit("%d"))
        self.assertEqual(MODULE.validate_localization("%d matches", german, "de"), [])

    def test_unused_substitutions_cannot_satisfy_count_metadata(self):
        german = counted("%d Treffer", unit("%d"), unit("%d"))
        entry = MODULE.Member("matches", {"localizations": {"en": unit("%d matches"), "de": german}}, 0, 0)
        counts = {"matches": {"source": "%d matches", "arguments": [1]}}
        self.assertTrue(MODULE.check_entry(entry, "de", {}, counts))

    def test_arabic_requires_all_six_nonempty_categories(self):
        variants = {category: unit("%d نتائج") for category in ("zero", "one", "two", "few", "many", "other")}
        arabic = {"variations": {"plural": variants}}
        self.assertEqual(MODULE.validate_localization("%d matches", arabic, "ar"), [])
        variants["few"] = {}
        self.assertTrue(MODULE.validate_localization("%d matches", arabic, "ar"))

    def test_info_plist_duplicate_records_remain_lossless(self):
        path = ROOT / "Resources/InfoPlist.xcstrings"
        text = path.read_text(encoding="utf-8")
        entries = MODULE.catalog_entries(text)
        keys = [entry.key for entry in entries]
        self.assertEqual(keys.count("NSLocalNetworkUsageDescription"), 2)
        self.assertEqual(keys.count("NSMotionUsageDescription"), 2)
        self.assertEqual(keys.count("NSSpeechRecognitionUsageDescription"), 2)
        self.assertEqual(keys.count("NSSystemAdministrationUsageDescription"), 2)

    def test_merge_rejects_stale_source_and_wrong_placeholder(self):
        original = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "extractionState": "manual",
                    "localizations": {"en": {"stringUnit": {"state": "translated", "value": "Open %@"}}},
                }
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                MODULE.merge(path, "de", [{"key": "example", "source": "Stale %@", "value": "Öffnen %@"}], {})
            with self.assertRaises(ValueError):
                MODULE.merge(path, "de", [{"key": "example", "source": "Open %@", "value": "Öffnen"}], {})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), original)

    def test_merge_preserves_other_locales_and_updates_only_target(self):
        original = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {"stringUnit": {"state": "translated", "value": "Open"}},
                        "ja": {"stringUnit": {"state": "translated", "value": "開く"}},
                    },
                }
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")
            MODULE.merge(path, "de", [{"key": "example", "source": "Open", "value": "Öffnen"}], {})
            updated = json.loads(path.read_text(encoding="utf-8"))
            localizations = updated["strings"]["example"]["localizations"]
            self.assertEqual(localizations["ja"]["stringUnit"]["value"], "開く")
            self.assertEqual(localizations["de"]["stringUnit"]["value"], "Öffnen")


if __name__ == "__main__":
    unittest.main()
