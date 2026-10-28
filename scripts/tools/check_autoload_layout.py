#!/usr/bin/env python3
"""Fail if an autoload script's member variables differ from the frozen layout.

Installed copies apply content patches by swapping each autoload's script in
place, and the live object keeps the member-variable slots of the version that
was installed. Adding, removing, retyping or reordering a member variable
therefore corrupts memory on older installs: the 0.1.2 patch crashed 0.1.0 and
0.1.1 copies this way. Functions, constants and comments may change freely; new
state belongs in a child node or a separate script.
"""
import re
import sys
from pathlib import Path

FROZEN = {
    "scripts/core/settings.gd": [
        "var data := {}",
        "var binds := {}",
    ],
    "scripts/core/net.gd": [
        "var players := {}",
        "var in_game := false",
        "var solo := true",
        'var last_message := ""',
    ],
    "scripts/core/sfx.gd": [
        "var streams := {}",
        "var _pool3d: Array[AudioStreamPlayer3D] = []",
        "var _pool2d: Array[AudioStreamPlayer] = []",
        "var _i3 := 0",
        "var _i2 := 0",
        "var _music: AudioStreamPlayer",
        "var _rng := RandomNumberGenerator.new()",
    ],
    "scripts/core/updater.gd": [
        "var state := State.IDLE",
        'var message := ""',
        'var latest_version := ""',
        'var release_url := ""',
        "var progress := 0.0",
        "var _manifest := {}",
        "var _assets := {}",
        "var _http: HTTPRequest",
        "var _busy := false",
    ],
}

root = Path(__file__).resolve().parents[2]
failed = False
for rel, expected in FROZEN.items():
    lines = (root / rel).read_text().splitlines()
    actual = [re.sub(r"\s*#.*$", "", l).rstrip() for l in lines
              if re.match(r"^(@\w+(\(.*?\))?\s+)*(static\s+)?var\s", l)]
    if actual != expected:
        failed = True
        print(f"{rel}: member variables changed (installed copies would crash on this patch)")
        print("  expected: " + " | ".join(expected))
        print("  actual:   " + " | ".join(actual))
if failed:
    sys.exit(1)
print("autoload member layouts unchanged")
