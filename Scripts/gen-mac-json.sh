#!/bin/bash
# 生成 release 资产 Build/mac.json —— Mac 更新判定用的“内容版本”。
#
# 为什么需要它：仓库版本号是双端统一的，每发一版都会 bump；但 macOS 可能并没有改动。
# Mac 更新器如果直接比 tag 版本，就会把 Windows-only 发版误判成 Mac 有新版本。
# 这里输出的 macBuild 来自 Info.plist 的 CFBundleVersion，**只有 macOS 真改动时才 +1**。
#
# 用法：发版时在 make dmg 之后运行，然后把 Build/mac.json 一起传到 release。
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"

mkdir -p Build
printf '{"macBuild":%s,"macVersion":"%s"}\n' "$BUILD" "$VERSION" > Build/mac.json
echo "已生成 Build/mac.json：macBuild=$BUILD macVersion=$VERSION"
