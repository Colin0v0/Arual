#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# CI 托管 runner 没有真实音频硬件，不能把本机设备诊断当作发布门禁。
# 发布构建仍执行完整单元测试、Release 构建和严格签名校验；硬件诊断只在真机执行。
TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
TESTING_PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
test -f "$TESTING_PLUGIN"
# 托管 runner 可能预装多个 SDK；固定最新 macOS 15 SDK，避免发布包的部署目标随默认 Xcode 漂移。
SDK_LIST="$(xcodebuild -showsdks)"
SDK_VERSION="$(printf '%s\n' "$SDK_LIST" | sed -n 's/.*macosx\(15\.[0-9]*\).*/\1/p' | sort -V | tail -1)"
test -n "$SDK_VERSION"
SDK_PATH="$(xcrun --sdk "macosx$SDK_VERSION" --show-sdk-path)"
export SDKROOT="$SDK_PATH"
# AppKit 窗口、菜单和快照测试共享全局状态，CI 串行执行以消除测试之间的窗口竞争。
swift build --build-tests -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" \
    -Xswiftc -sdk -Xswiftc "$SDK_PATH"
./Scripts/prepare-test-resources.sh
swift test --skip-build --no-parallel -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" \
    -Xswiftc -sdk -Xswiftc "$SDK_PATH"
AURAL_BUILD_CONFIGURATION=release ./Scripts/build-app.sh
codesign --verify --strict dist/Aural.app

printf 'CI 检查通过：单元测试、Release 构建和签名校验均成功。\n'
