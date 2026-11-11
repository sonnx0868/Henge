#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ulimit -s 65520
export HOMEBREW_NO_AUTO_UPDATE=1
if ! pkg-config --exists slirp 2>/dev/null; then brew install pkg-config libslirp; fi
make build/test_code_links build/test_jit build/test_mem build/test_mmu \
  build/test_scroll_bridge build/test_jit_script build/test_scroll_pixels \
  build/test_pvg_video_layout build/test_pvg_present build/test_pvg_queue build/henge-agent build/test_native_image build/test_image_bridge \
  build/test_shutdown build/test_dns_lifecycle build/test_vm_lifecycle build/test_pvg_lifecycle
swiftc -parse-as-library ios/Henge/ScrollMotion.swift tests/test_scroll_motion.swift -o build/test_scroll_motion
swiftc -parse-as-library ios/Henge/SecondaryClickRouting.swift tests/test_secondary_click.swift -o build/test_secondary_click
swiftc -parse-as-library ios/Henge/HardwareKeyRouting.swift tests/test_hardware_keys.swift -o build/test_hardware_keys
swiftc -parse-as-library ios/Henge/TouchScrollMotion.swift tests/test_touch_scroll.swift -o build/test_touch_scroll
swiftc -parse-as-library ios/Henge/PhysicalMouseButtons.swift tests/test_physical_mouse_buttons.swift -o build/test_physical_mouse_buttons
make test-hardware-shortcuts test-jit-advice
for test in test_code_links test_jit test_mem test_mmu test_scroll_bridge test_jit_script \
  test_scroll_pixels test_pvg_video_layout test_pvg_present test_pvg_queue \
  test_scroll_motion test_secondary_click test_hardware_keys test_native_image test_image_bridge test_touch_scroll test_physical_mouse_buttons \
  test_shutdown test_dns_lifecycle test_vm_lifecycle test_pvg_lifecycle; do
  printf 'Running %s\n' "$test"
  "build/$test"
done
bash ios/scripts/check_display.sh
