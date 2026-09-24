#!/usr/bin/env bash
#
# build_ipa.sh — 在 macOS（Xcode 环境）上构建 TrollStore 可安装的 .ipa
# 由 GitHub Actions 的 macos runner 调用，也可在本地 Mac 运行。
#
set -euo pipefail

SCHEME="TraeResetiOS"
CONFIG="Debug"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENT="$ROOT/Sources/TraeResetiOS/TraeResetiOS.entitlements"
WORK="$ROOT/build"

echo "==> 1/6 准备 xcodegen"
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen || {
    echo "brew 安装 xcodegen 失败，尝试官方脚本"
    mkdir -p /tmp/xg && curl -L https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip -o /tmp/xg/xg.zip
    unzip -o /tmp/xg/xg.zip -d /tmp/xg && chmod +x /tmp/xg/XcodeGen && ln -sf /tmp/xg/XcodeGen /usr/local/bin/xcodegen
  }
fi

echo "==> 2/6 生成 Xcode 工程"
(cd "$ROOT" && xcodegen generate)

echo "==> 3/6 注入 build number: ${BUILD_NUMBER:-1}"
BUILD="${BUILD_NUMBER:-1}"
# 注入到 source Info.plist（CI 是临时 checkout，改完不会 commit 回仓库）
plutil -replace CFBundleVersion -string "$BUILD" "$ROOT/Sources/TraeResetiOS/Info.plist"
echo "    CFBundleVersion -> $BUILD"

echo "==> xcodebuild 编译"
rm -rf "$WORK"
xcodebuild \
  -project "$ROOT/TraeResetiOS.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$WORK" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build | tail -n 40

APP="$(find "$WORK" -path '*-iphoneos/*.app' -prune -print | head -n1)"
echo "App: $APP"
[ -n "$APP" ] || { echo "未找到编译产物"; exit 1; }

echo "==> 4/6 解压为 Payload 结构"
IPA_STAGE="$ROOT/dist/Payload"
rm -rf "$ROOT/dist"
mkdir -p "$IPA_STAGE"
cp -R "$APP" "$IPA_STAGE/"

echo "==> 5/6 嵌入 entitlements（ad-hoc 重签，TrollStore 安装时保留）"
APP_NAME="$(basename "$APP")"
codesign --force --sign - \
  --entitlements "$ENT" \
  "$IPA_STAGE/$APP_NAME"

# 校验 entitlements 确实嵌入
echo "--- 校验 entitlements ---"
codesign -d --entitlements - "$IPA_STAGE/$APP_NAME" 2>/dev/null || true

echo "==> 6/6 打包 .ipa (build $BUILD)"
cd "$ROOT/dist"
OUT="$ROOT/dist/TraeResetiOS-b${BUILD}-TrollStore.ipa"
rm -f "$OUT"
zip -qryX "$OUT" Payload
# 留一份固定名（不带 build）方便 CI 上传
cp -f "$OUT" "$ROOT/TraeResetiOS-TrollStore.ipa"
echo "完成: $OUT"
ls -lh "$OUT"
