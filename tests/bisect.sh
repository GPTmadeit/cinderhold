#!/usr/bin/env bash
# Benchmark the game with subsystems switched off, one at a time.
cd "$(dirname "$0")/.."
S=${1:-/tmp}
for off in none env terrain lights particles atmosphere "env,lights,particles"; do
  r=$(CINDER_DISABLE=$off tests/shot.sh "$S/bis_${off//,/_}.png" 40 --solo --quality 1 --fps-log 12 | grep -E "offscreen")
  echo "$off: $r"
done
