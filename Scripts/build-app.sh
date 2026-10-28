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

# M5 内置 xray 内核。缺失时不阻断构建（代理功能自行降级），但要显眼提示。
if [ -x "Vendor/xray/xray" ]; then
    mkdir -p "$APP/Contents/Resources/proxy"
    cp Vendor/xray/xray Vendor/xray/geoip.dat Vendor/xray/geosite.dat \
       "$APP/Contents/Resources/proxy/"
    # 版本戳：XrayBootstrap 靠它判断"App 升级后要不要重拷内核"
    cp Vendor/xray/.version "$APP/Contents/Resources/proxy/version.txt"
    chmod +x "$APP/Contents/Resources/proxy/xray"
    # arm64 上可执行文件必须有有效签名，否则 exec 即 SIGKILL（spec §1.1 #36）。
    # 嵌套二进制单独签，再 seal 外层 App。
    codesign --force --sign - "$APP/Contents/Resources/proxy/xray"
else
    echo "⚠️ 缺 Vendor/xray/xray，代理功能不可用。先跑 ./Scripts/fetch-xray.sh" >&2
fi

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

# ── 防僵尸实例：只处理"从本路径启动"的旧进程 ────────────────────────────────
# bundle 被 rm -rf 重建后，旧进程还能跑但合成事件已被系统静默丢弃
# （TCC 看似仍授权，排查成本极高，见 BundleIntegrity 注释）。
# 从 Build/ 这里启动的实例直接杀掉换新的；装在 /Applications 等别处的不受影响。
EXE="$APP/Contents/MacOS/Toolbox"
OLD="$(pgrep -f "$EXE" || true)"
if [ -n "$OLD" ]; then
    echo "⚠️ 检测到从 $APP 启动的旧实例（pid: ${OLD//$'\n'/ }），正在重启到新构建…"
    kill $OLD 2>/dev/null || true
    sleep 1
    open "$APP"
    echo "✅ 已重启到新版本"
fi
