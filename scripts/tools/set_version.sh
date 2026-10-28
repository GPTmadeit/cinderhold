#!/usr/bin/env bash
# Bump the game version everywhere it lives: tools/set_version.sh 0.2.0
set -euo pipefail
v=${1:?usage: set_version.sh X.Y.Z}
cd "$(dirname "$0")/../.."
sed -i "s/^const VERSION := \".*\"/const VERSION := \"$v\"/" scripts/core/version.gd
sed -i "s/^config\/version=\".*\"/config\/version=\"$v\"/" project.godot
sed -i "s/^application\/short_version=\".*\"/application\/short_version=\"$v\"/; s/^application\/version=\".*\"/application\/version=\"$v\"/; s/^version\/name=\".*\"/version\/name=\"$v\"/" export_presets.cfg
IFS=. read -r a b c <<< "$v"
sed -i "s/^version\/code=.*/version\/code=$((a * 10000 + b * 100 + c))/" export_presets.cfg
grep -h "VERSION :=\|config/version\|version/code" scripts/core/version.gd project.godot export_presets.cfg
