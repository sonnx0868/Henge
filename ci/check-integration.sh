#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ulimit -s 65520
make build/test_code_links build/test_jit build/test_mem build/test_mmu \
  build/test_scroll_bridge build/test_jit_script build/test_scroll_pixels \
  build/test_pvg_video_layout build/test_pvg_present build/test_pvg_queue build/henge-agent
swiftc -parse-as-library ios/Henge/ScrollMotion.swift tests/test_scroll_motion.swift -o build/test_scroll_motion
swiftc -parse-as-library ios/Henge/SecondaryClickRouting.swift tests/test_secondary_click.swift -o build/test_secondary_click
swiftc -parse-as-library ios/Henge/HardwareKeyRouting.swift tests/test_hardware_keys.swift -o build/test_hardware_keys
for test in test_code_links test_jit test_mem test_mmu test_scroll_bridge test_jit_script \
  test_scroll_pixels test_pvg_video_layout test_pvg_present test_pvg_queue \
  test_scroll_motion test_secondary_click test_hardware_keys; do
  printf 'Running %s\n' "$test"
  "build/$test"
done
if [ -f ios/scripts/check_display.sh ]; then bash ios/scripts/check_display.sh; fi
