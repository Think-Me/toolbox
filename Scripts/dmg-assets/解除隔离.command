#!/bin/bash
# Toolbox 安装助手：把左边的 Toolbox.app 拖进"应用程序"后，双击我。
# 作用：解除 Gatekeeper 隔离属性 + 提示首次要授的权限 + 启动。
# 本机自签、未做 Apple 公证，所以 macOS 会拦一次；解除隔离后即可正常打开。
APP="/Applications/Toolbox.app"
echo "===================="
echo " Toolbox 安装助手"
echo "===================="
echo
if [ ! -d "$APP" ]; then
  echo "❌ 还没在『应用程序』里找到 Toolbox.app。"
  echo "   请先把这个窗口里的 Toolbox.app 拖到左边的 Applications 文件夹，再双击我。"
  echo
  read -n 1 -s -r -p "按任意键退出…"; echo
  exit 1
fi
echo "→ 解除隔离属性…"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
if xattr "$APP" 2>/dev/null | grep -q quarantine; then
  echo "⚠️ 仍有残留，可能需要管理员权限。可在终端执行："
  echo "    sudo xattr -dr com.apple.quarantine \"$APP\""
else
  echo "✅ 已解除隔离。"
fi
echo
echo "首次启动请手动授予（系统设置 → 隐私与安全性）："
echo "  · 屏幕录制  —— 截图"
echo "  · 辅助功能  —— 自动粘贴"
echo
read -n 1 -s -r -p "按任意键启动 Toolbox…"; echo
open "$APP"
