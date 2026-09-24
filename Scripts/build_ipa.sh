#!/usr/bin/env bash
#
# build_ipa.sh — 在 macOS（Xcode 工具链）上构建 TrollStore 可安装的 .ipa
#
# 策略：不生成 .xcodeproj（避免 XcodeGen/Xcode 版本不匹配），
#       直接用 swiftc 编译 SwiftUI 源码为 arm64 可执行，组 app bundle，
#       ad-hoc 签名 + 嵌入 no-sandbox entitlements，再打包成 .ipa。
#       由 GitHub Actions macos runner 或本地 Mac 调用。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/TraeResetiOS"
ENT="$SRC/TraeResetiOS.entitlements"
INFO="$SRC/Info.plist"
EXE="TraeResetiOS"
BUILD="${BUILD_NUMBER:-1}"

echo "==> 1/5 注入 build number: $BUILD"
plutil -replace CFBundleVersion -string "$BUILD" "$INFO"
echo "    CFBundleVersion -> $BUILD"

echo "==> 2/5 swiftc 编译 (arm64, iOS 14+)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
APP="$ROOT/dist/$EXE.app"
rm -rf "$ROOT/dist"
mkdir -p "$APP"

swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios16.0 \
  -parse-as-library \
  -O \
  -framework SwiftUI -framework UIKit \
  -o "$APP/$EXE" \
  "$SRC"/*.swift

cp "$INFO" "$APP/Info.plist"

echo "==> 3/5 校验可执行文件为 arm64"
file "$APP/$EXE"

echo "==> 4/5 ad-hoc 签名 + 嵌入 no-sandbox entitlements"
codesign --force --sign - --entitlements "$ENT" "$APP/$EXE"
codesign --force --sign - --entitlements "$ENT" "$APP"
# 打印已嵌入的 entitlements 供核对
echo "--- 已嵌入 entitlements ---"
codesign -d --entitlements - "$APP/$EXE" 2>/dev/null || true

echo "==> 5/5 打包 .ipa (build $BUILD)"
cd "$ROOT/dist"
rm -rf Payload
mkdir -p Payload
cp -R "$APP" Payload/
OUT="$ROOT/dist/TraeResetiOS-b${BUILD}-TrollStore.ipa"
rm -f "$OUT"
zip -qryX "$OUT" Payload
cp -f "$OUT" "$ROOT/TraeResetiOS-TrollStore.ipa"
echo "完成: $OUT"
ls -lh "$OUT"
