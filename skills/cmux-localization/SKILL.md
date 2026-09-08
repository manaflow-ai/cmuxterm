---
name: cmux-localization
description: "Localization rules and audit workflow for cmux UI strings, settings rows, menus, shortcuts, schema/config text, docs, command/help text, alerts, tooltips, and web messages. Use whenever changing user-facing text."
---

# cmux Localization

Use this skill for any user-facing string change.

## Hard rules

- Every user-facing string is localized. Never a bare string literal in SwiftUI `Text()`, `Button()`, alert titles, tooltips, menus, or dialogs.
- Swift/AppKit/SwiftUI: `String(localized: "key.name", defaultValue: "English text")`, with keys in `Resources/Localizable.xcstrings`. Every feature PR includes translated entries for all supported macOS languages (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`).
- `defaultValue`, English fallback text, schema descriptions, and copied English strings do not count as localization. Record deliberate invariant literals in `scripts/localization-allowed-omissions.json`, with the exact source and omission class. A correct translation that shares the English spelling needs a documented `identityLocales` exception for that key and locale; the translated entry remains required.
- Localized web/docs content updates every supported message catalog (currently `web/messages/en.json` and `web/messages/ja.json`) plus any localized data structures carrying inline translations.
- A localization audit is required for every user-facing change.

## Audit checklist

Before finishing a task that changes UI, Settings rows, menus, shortcut metadata, schema/config text, docs, command/help text, alerts, or tooltips:

1. Enumerate the changed user-facing surfaces.
2. Verify each surface has a catalog key and translated values for every supported macOS locale (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`) in the feature PR.
3. Parse the touched localization files and compare changed message keys across locales.
4. Run `rg` over changed Swift/TS/TSX/docs files for newly introduced bare English.
5. State in the final handoff what audit was performed, or explicitly say what could not be verified.

`Resources/Localizable.xcstrings`, `Resources/InfoPlist.xcstrings`, and the linked macOS package catalogs must pass `python3 scripts/localization_catalog.py check`. New keys must carry all nine macOS locale entries, preserve printf placeholders, and use plural variations for count strings where the source has a count.

Count strings are recorded in `scripts/localization-plurals.json` with the English source and the argument numbers that select plurals. Every required plural category must contain translated text. Use substitutions when more than one count varies or when the count is not the first argument. Arabic requires zero/one/two/few/many/other; French and Spanish include many. Keep every message inside the catalog's `strings` object so Xcode compiles it.

## Detailed reference

- [references/audit-workflow.md](references/audit-workflow.md): what counts as user-facing, search patterns, and handoff wording.

New keyboard shortcuts also need docs and Settings entries; see [../cmux-keyboard-shortcuts/SKILL.md](../cmux-keyboard-shortcuts/SKILL.md).
