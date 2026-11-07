#!/usr/bin/env bash
# Build Henge's unsigned, ad-hoc-signed IPA on a Bitrise macOS/Xcode stack.
# SideStore or AltStore re-signs the IPA when installing it on the iPad.
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1

HENGE_ROOT="${BITRISE_SOURCE_DIR:?Bitrise must set BITRISE_SOURCE_DIR}"
HUSK_ROOT="$(dirname "$HENGE_ROOT")/Husk"
STIKJIT_ROOT="$(dirname "$HENGE_ROOT")/StikJIT"
HUSK_REV=afe83d45b31194c4cc9f7b3db7ec2c757db8346e

# Exercise guest code changes and cache invalidation on the Mac build host before packaging iOS.
cd "$HENGE_ROOT"
# The native-vs-JIT harness keeps multi-megabyte HvCpu copies on the main stack.
ulimit -s 65520
make build/test_code_links build/test_jit build/test_mem build/test_mmu build/test_scroll_bridge build/test_jit_script build/test_scroll_pixels build/test_pvg_video_layout
swiftc -parse-as-library ios/Henge/ScrollMotion.swift tests/test_scroll_motion.swift -o build/test_scroll_motion
swiftc -parse-as-library ios/Henge/SecondaryClickRouting.swift tests/test_secondary_click.swift -o build/test_secondary_click
for test in test_code_links test_jit test_mem test_mmu test_scroll_bridge test_scroll_motion test_jit_script test_scroll_pixels test_pvg_video_layout test_secondary_click; do
    printf 'Running %s\n' "$test"
    if "build/$test"; then
        continue
    else
        result=$?
        lldb --batch -o run -o 'thread backtrace all' -- "build/$test" || true
        exit "$result"
    fi
done

missing=()
for tool in meson ninja pkg-config xcodegen cmake; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
    brew install "${missing[@]}"
fi

if ! command -v rustup >/dev/null 2>&1; then
    brew install rustup
    export PATH="$(brew --prefix rustup)/bin:$PATH"
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustup default stable
rustup target add aarch64-apple-ios

git clone --depth 1 https://github.com/Leviidev/Husk.git "$HUSK_ROOT"
git -C "$HUSK_ROOT" fetch --depth 1 origin "$HUSK_REV"
git -C "$HUSK_ROOT" checkout --detach "$HUSK_REV"
cd "$HUSK_ROOT"
./scripts/fetch_sources.sh
./scripts/build_ios.sh libffi glib libslirp
./scripts/build_rppairing_ios.sh

export HUSK="$HUSK_ROOT"
export IOS_DEPS="$HUSK_ROOT/build/ios-arm64/sysroot"
for dep in libhusk_rppairing.a; do
    test -s "$HUSK_ROOT/build/ios-arm64/lib/$dep"
done
for dep in libslirp.a libglib-2.0.a libintl.a libpcre2-8.a; do
    test -s "$IOS_DEPS/lib/$dep" || {
        echo "Missing Husk iOS dependency: $dep" >&2
        exit 1
    }
done

cd "$HENGE_ROOT"
./ios/scripts/fetch_deps.sh
bash ci/build-stikjit.sh "$STIKJIT_ROOT"
rm -rf "$HENGE_ROOT/ios/deps/StikJIT.xcframework"
ditto "$STIKJIT_ROOT/StikJIT.xcframework" "$HENGE_ROOT/ios/deps/StikJIT.xcframework"
./tools/build_ios_restore.sh
make ios-lib
mkdir -p "$HOME/Desktop"
./ios/scripts/package_ipa.sh

mkdir -p "${BITRISE_DEPLOY_DIR:?Bitrise must set BITRISE_DEPLOY_DIR}"
# The IPA is intentionally ad-hoc-signed, without embedded.mobileprovision.
# Bitrise's deploy step treats an .ipa as an installable artifact and rejects it
# without a provisioning profile. Wrap it so it is uploaded as a generic file;
# users extract the IPA and let SideStore or AltStore re-sign it.
( cd "$HOME/Desktop" && zip -0 -q "$BITRISE_DEPLOY_DIR/Henge-color-fix-unsigned.zip" Henge.ipa )
