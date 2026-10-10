#!/bin/bash
# 组装 Build/Toolbox.app：swift build → bundle 布局 → 复制 Info.plist → ad-hoc 签名
#
# 为什么必须组装成真 .app 而不是直接跑裸二进制：TCC（屏幕录制/辅助功能）按
# "bundle id + 代码签名" 识别应用，裸二进制拿不到稳定授权。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="Build/Toolbox.app"

swift build -c "$CONFIG"
# 用 --show-bin-path 取真实产物目录，不硬编码 .build/<arch>-<os>/<config>
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Toolbox"
[ -x "$BIN" ] || { echo "找不到可执行文件: $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Toolbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 图标资源。缺失时不阻断构建，代码里有 SF Symbol 兜底。
for f in AppIcon.icns MenuBarIcon.png; do
    if [ -f "Resources/$f" ]; then
        cp "Resources/$f" "$APP/Contents/Resources/$f"
    else
        echo "⚠️ 缺少 Resources/$f，先跑 ./Scripts/gen-icon-assets.py" >&2
    fi
done

# 不要加 --options runtime（hardened runtime）：本地签名 + hardened 会让
# AppleEvents / 辅助功能类调用因为缺 entitlement 而失败。
#
# 签名身份优先用自签证书，理由见 Scripts/create-signing-cert.sh：
# ad-hoc 的 designated requirement 是 cdhash，每次重建都变 → TCC 授权每次作废。
IDENTITY="${TOOLBOX_SIGN_IDENTITY:-Toolbox Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "signing with: $IDENTITY（TCC 授权可跨重建保留）"
    codesign --force --sign "$IDENTITY" --identifier com.ebertwiseman.toolbox "$APP"
else
    echo "signing with: ad-hoc（⚠️ 每次重建都会掉 TCC 授权，跑一次 ./Scripts/create-signing-cert.sh 可解决）"
    codesign --force --sign - --identifier com.ebertwiseman.toolbox "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | tail -2
echo "built $APP  (bin: $BIN)"
