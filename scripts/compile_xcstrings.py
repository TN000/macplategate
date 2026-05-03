#!/usr/bin/env python3
"""
Compile Localizable.xcstrings → per-locale .lproj/Localizable.strings files
for inclusion in the .app bundle's top-level Contents/Resources/.

Why: Swift Package Manager copies Localizable.xcstrings into a nested module
bundle (SPZApp_SPZApp.bundle/) which SwiftUI can read at runtime, but macOS
Launch Services and System Settings → Language & Region only detect supported
languages by scanning Contents/Resources/{lang}.lproj/Localizable.strings.

Without these per-locale .strings files, System Settings shows
"MacPlateGate doesn't support additional languages" even though the app is
fully localized internally.

Usage:
    python3 scripts/compile_xcstrings.py <xcstrings_path> <output_dir>

Example (called from build_app.sh):
    python3 scripts/compile_xcstrings.py \
        Sources/SPZApp/Resources/Localizable.xcstrings \
        build/MacPlateGate.app/Contents/Resources
"""
import json, os, sys


def escape_strings_value(s: str) -> str:
    """Escape a string for the .strings file format (Apple plist-like)."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r")


def write_strings_file(path: str, entries: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = ["/* Auto-generated from Localizable.xcstrings — do not edit. */", ""]
    for key, value in entries.items():
        ek = escape_strings_value(key)
        ev = escape_strings_value(value)
        lines.append(f'"{ek}" = "{ev}";')
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    xcstrings_path = sys.argv[1]
    output_dir = sys.argv[2]

    with open(xcstrings_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    source_lang = catalog.get("sourceLanguage", "en")
    strings = catalog.get("strings", {})

    # Find every target language used across all keys.
    target_langs = set()
    for entry in strings.values():
        for lang in entry.get("localizations", {}).keys():
            target_langs.add(lang)
    target_langs.add(source_lang)

    for lang in sorted(target_langs):
        per_lang = {}
        for key, entry in strings.items():
            if lang == source_lang:
                # Source-language key uses the key itself as value (SwiftUI fallback).
                per_lang[key] = key
            else:
                loc = entry.get("localizations", {}).get(lang, {})
                unit = loc.get("stringUnit", {})
                value = unit.get("value")
                if value:
                    per_lang[key] = value
        if not per_lang:
            continue
        path = os.path.join(output_dir, f"{lang}.lproj", "Localizable.strings")
        write_strings_file(path, per_lang)
        print(f"  wrote {path} ({len(per_lang)} keys)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
