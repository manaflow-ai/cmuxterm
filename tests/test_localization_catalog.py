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


class LocalizationCatalogTests(unittest.TestCase):
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
