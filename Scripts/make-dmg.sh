#!/bin/bash
# 把 Build/Toolbox.app 打包成 Build/Toolbox.dmg（可分发的安装镜像）。
#
# dmg 只是"容器"：里面装的还是那个 .app，外加一个指向 /Applications 的快捷方式，
# 用户挂载后把图标拖进去即完成安装。它不改变签名——自签的 app 在别的 Mac 上
# 仍需右键"打开"绕过 Gatekeeper（见 spec §1.1 与 README 的签名说明）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Build/Toolbox.app"
DMG="Build/Toolbox.dmg"
VOLNAME="Toolbox"

[ -d "$APP" ] || { echo "找不到 $APP，先跑 ./Scripts/build-app.sh" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# ditto 而非 cp：保留符号链接、扩展属性、可执行位
echo "复制 $APP 到镜像暂存…"
ditto "$APP" "$STAGING/$VOLNAME.app"
ln -s /Applications "$STAGING/Applications"

# 安装助手：用户拖完 app 后双击它，解除 Gatekeeper 隔离 + 权限指引 + 启动
if [ -f "Scripts/dmg-assets/解除隔离.command" ]; then
    cp "Scripts/dmg-assets/解除隔离.command" "$STAGING/解除隔离.command"
    chmod +x "$STAGING/解除隔离.command"
fi

rm -f "$DMG"
echo "生成 $DMG…"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

# 校验镜像可用：挂载 → 确认里面有 app → 卸载
MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
trap 'rm -rf "$STAGING"; [ -n "${MOUNT:-}" ] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
if [ -d "$MOUNT/$VOLNAME.app" ]; then
    echo "✅ 镜像校验通过：挂载后能看到 $VOLNAME.app"
else
    echo "❌ 挂载后没找到 app" >&2; exit 1
fi
hdiutil detach "$MOUNT" >/dev/null
MOUNT=""

APPSZ=$(du -sh "$APP" | awk '{print $1}')
DMGSZ=$(du -sh "$DMG" | awk '{print $1}')
echo "打包完成：$DMG  （$APP 原大小 $APPSZ → dmg $DMGSZ）"
