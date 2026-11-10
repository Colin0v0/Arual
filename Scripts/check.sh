#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 显式加载当前工具链自带的宏插件，避免 CLT 省略宏加载参数；缺失直接失败。
TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
TESTING_PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
test -f "$TESTING_PLUGIN"
swift test -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
./Scripts/build-app.sh
codesign --verify --strict dist/Aural.app
./dist/Aural.app/Contents/MacOS/Aural --diagnose

# 麦克风诊断只读硬件属性，不录音、不切换输入、不写入增益。
./dist/Aural.app/Contents/MacOS/Aural --diagnose-inputs
