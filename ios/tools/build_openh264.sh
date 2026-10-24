#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=652bdb7719f30b52b08e506645a7322ff1b2cc6f
root="$PWD/.build-deps/openh264"
mkdir -p "$root"
if [ ! -d "$root/source/.git" ]; then
  git clone --no-checkout https://github.com/cisco/openh264.git "$root/source"
fi
git -C "$root/source" checkout --detach "$revision"
test "$(git -C "$root/source" rev-parse HEAD)" = "$revision"
python3 tools/patch_openh264.py "$root/source"
# Explicit targets handle arm64 simulators. Generated files stay outside tracked sources.
cat > "$root/source/build/platform-codex-ios.mk" <<'EOF'
include $(SRC_PATH)build/platform-darwin.mk
SDKROOT := $(shell xcrun --sdk $(SDK) --show-sdk-path)
CC = xcrun --sdk $(SDK) clang
CXX = xcrun --sdk $(SDK) clang++
CFLAGS += -target $(TRIPLE) -isysroot $(SDKROOT) -DAPPLE_IOS
CXXFLAGS += -target $(TRIPLE) -isysroot $(SDKROOT)
EOF
build() {
  local sdk="$1" triple="$2"
  mkdir -p "$root/$sdk"
  pushd "$root/source" >/dev/null
  make clean >/dev/null
  make -j3 libopenh264.a OS=codex-ios ARCH=arm64 USE_ASM=No SDK="$sdk" TRIPLE="$triple" V=No
  cp libopenh264.a "$root/$sdk/libopenh264.a"
  popd >/dev/null
}
build iphoneos arm64-apple-ios18.0
build iphonesimulator arm64-apple-ios18.0-simulator
mkdir -p "$root/include"
cp "$root/source/codec/api/wels/"*.h "$root/include/"
cp "$root/source/LICENSE" "$root/LICENSE"
mkdir -p IPhoneAgent/ThirdParty
cp "$root/source/LICENSE" IPhoneAgent/ThirdParty/OpenH264-LICENSE.txt
