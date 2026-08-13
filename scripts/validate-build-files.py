#!/usr/bin/env python3
"""Validates build files that only Windows tooling ever reads.

Two real breakages prompted this, both invisible on macOS:

1. A `--` inside an XML comment in PixCapWin.csproj. XML forbids it, so MSBuild
   refused the project.
2. Em-dashes in build.ps1. Windows PowerShell 5.1 decodes UTF-8-without-BOM as
   Windows-1252, where the em-dash's third byte becomes a smart quote that
   PowerShell honours as a string delimiter, truncating the string and
   producing a parse error nine lines later.
"""
import glob
import sys
import xml.etree.ElementTree as ET

PATTERNS = [
    "platforms/windows/**/*.csproj",
    "platforms/windows/**/*.xaml",
    "platforms/windows/**/*.manifest",
    "platforms/macos/**/*.plist",
    "extensions/**/*.xml",
]

PS_PATTERNS = [
    "platforms/**/*.ps1",
    "scripts/**/*.ps1",
]

failures = []
checked = 0

for pattern in PS_PATTERNS:
    for path in sorted(glob.glob(pattern, recursive=True)):
        checked += 1
        text = open(path, encoding="utf-8").read()
        offenders = {
            line_number: [c for c in line if ord(c) > 127]
            for line_number, line in enumerate(text.splitlines(), 1)
            if any(ord(c) > 127 for c in line)
        }
        if offenders:
            detail = "; ".join(
                f"line {n}: {''.join(chars)!r}" for n, chars in list(offenders.items())[:3]
            )
            failures.append(
                f"{path}: non-ASCII characters break Windows PowerShell 5.1 parsing ({detail})"
            )

for pattern in PATTERNS:
    for path in sorted(glob.glob(pattern, recursive=True)):
        if "node_modules" in path or "/.build/" in path or "/build/" in path:
            continue
        checked += 1
        try:
            ET.parse(path)
        except ET.ParseError as error:
            failures.append(f"{path}: {error}")

for failure in failures:
    print(f"BROKEN  {failure}")

print(f"{checked - len(failures)}/{checked} XML files valid")
sys.exit(1 if failures else 0)
