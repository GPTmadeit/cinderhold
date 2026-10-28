#!/usr/bin/env bash
# Render a screenshot on a hidden Hyprland workspace so it never takes over the desktop.
# usage: tests/shot.sh <out.png> <seconds> [extra args after --]
set -e
out=$(realpath -m "$1"); secs=$2; shift 2
dir=$(cd "$(dirname "$0")/.." && pwd)
log="${out%.png}.log"
rm -f "$out" "$log"
cmd="CINDER_DISABLE=${CINDER_DISABLE:-} godot --path $dir --resolution 1600x900 ${GODOT_ARGS:-} -- --shot $out $secs $* > $log 2>&1"
hyprctl dispatch "hl.dsp.exec_cmd(\"$cmd\", { workspace = \"special:cinderdev silent\" })" >/dev/null
for _ in $(seq 1 $((secs * 4 + 120))); do
  grep -qE "shot saved|avg fps" "$log" 2>/dev/null && break
  sleep 0.5
done
grep -E "ERROR|SCRIPT|avg fps|shot saved|frame:|offscreen" "$log" | head -20 || true
