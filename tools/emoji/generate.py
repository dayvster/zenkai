#!/usr/bin/env python3
"""Regenerates the emoji table at the bottom of external/plugins/emoji/main.lua.

Inputs (Unicode data, Unicode License v3):
  emoji-test.txt  https://unicode.org/Public/emoji/<version>/emoji-test.txt
  en.xml          https://github.com/unicode-org/cldr/blob/<release>/common/annotations/en.xml

Usage:
  python3 tools/emoji/generate.py emoji-test.txt en.xml external/plugins/emoji/main.lua

Keeps fully-qualified emoji, drops skin-tone variants and components, and attaches
CLDR keywords so searches like "lol" or "love" find the right emoji.
"""
import re
import sys
import xml.etree.ElementTree as ET

BEGIN = "-- BEGIN GENERATED EMOJI DATA"
END = "-- END GENERATED EMOJI DATA"


def lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_keywords(path):
    keywords = {}
    for node in ET.parse(path).getroot().iter("annotation"):
        if node.get("type") == "tts" or not node.text:
            continue
        keywords[node.get("cp")] = [k.strip().lower() for k in node.text.split("|") if k.strip()]
    return keywords


def main(test_path, xml_path, lua_path):
    keywords = load_keywords(xml_path)
    version = "?"
    group = None
    groups, entries = [], []
    line_re = re.compile(r"^[0-9A-F ]+;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$")
    for line in open(test_path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        m = line_re.match(line)
        if not m or group == "Component":
            continue
        char, name = m.group(1), m.group(2).strip()
        if "skin tone" in name:
            continue
        if group not in groups:
            groups.append(group)
        words = keywords.get(char) or keywords.get(char.replace("️", "")) or []
        extra = [w for w in words if w != name.lower()]
        search = name.lower() + "|" + " ".join(extra)
        entries.append((char, name, search, groups.index(group) + 1))

    out = [BEGIN,
           f"-- Unicode Emoji {version} and CLDR English annotations. Copyright (c) Unicode, Inc.",
           "-- Distributed under the Unicode License v3: https://www.unicode.org/license.txt",
           "-- Regenerate with tools/emoji/generate.py; do not edit by hand.",
           "EMOJI_GROUPS = {" + ", ".join(lua_str(g) for g in groups) + "}"]
    for key, col in (("EMOJI_CHARS", 0), ("EMOJI_NAMES", 1), ("EMOJI_SEARCH", 2)):
        out.append(key + " = {")
        out += ["  " + lua_str(e[col]) + "," for e in entries]
        out.append("}")
    out.append("EMOJI_GROUP = {" + ",".join(str(e[3]) for e in entries) + "}")
    out.append(END)

    src = open(lua_path, encoding="utf-8").read()
    start, end = src.index(BEGIN), src.index(END) + len(END)
    open(lua_path, "w", encoding="utf-8").write(src[:start] + "\n".join(out) + src[end:])
    print(f"{len(entries)} emoji in {len(groups)} groups (Emoji {version})")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
