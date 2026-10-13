#!/bin/bash
# 下载并校验内置 xray 内核（M5）。产物落在 gitignore 的 Vendor/xray/，
# build-app.sh 会把 xray + geoip.dat + geosite.dat 拷进 .app 并单独签名。
#
# 为什么构建期联网下载而不是把 40MB 二进制提交进仓库：仓库不该背二进制；
# 代价是首次构建需要网络。版本与 SHA256 写死，升级时显式改这里。
set -euo pipefail
cd "$(dirname "$0")/.."

# —— 改版本时三行一起改，SHA256 从 release 的 .dgst 文件里取 ——
VERSION="v26.3.27"
ASSET="Xray-macos-arm64-v8a.zip"
# 注意 asset 名结尾是 v8a（不是 v8）：v8 会 404
SHA256="2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf"

URL="https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${ASSET}"
OUT="Vendor/xray"
STAMP="$OUT/.version"

mkdir -p "$OUT"

# 已经是目标版本且三件套齐全 → 直接跳过（构建不重复联网）
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ] \
   && [ -x "$OUT/xray" ] && [ -f "$OUT/geoip.dat" ] && [ -f "$OUT/geosite.dat" ]; then
    echo "xray $VERSION 已就绪，跳过下载"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "下载 $ASSET ($VERSION)…"
curl -L -f -s -o "$TMP/$ASSET" "$URL"

echo "校验 SHA256…"
ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "❌ 校验和不匹配！" >&2
    echo "   期望 $SHA256" >&2
    echo "   实际 $ACTUAL" >&2
    echo "   要么下载被篡改/截断，要么版本常量没同步更新。拒绝继续。" >&2
    exit 1
fi

echo "解压…"
unzip -o -q "$TMP/$ASSET" -d "$TMP/x"
# 只取需要的三个文件；zip 里还有 README/LICENSE，不入库
cp "$TMP/x/xray"       "$OUT/xray"
cp "$TMP/x/geoip.dat"  "$OUT/geoip.dat"
cp "$TMP/x/geosite.dat" "$OUT/geosite.dat"
chmod +x "$OUT/xray"
printf '%s' "$VERSION" > "$STAMP"

echo "✅ xray $VERSION 就绪：$OUT/{xray,geoip.dat,geosite.dat}"
"$OUT/xray" version | head -1
