#!/bin/bash
# 重编译 + 重启，并把"重编译后 TCC 掉授权"的恢复步骤打出来。
# 实测：ad-hoc 签名下每次重建 cdhash 都会变，屏幕录制/辅助功能可能要求重新授权。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
./Scripts/build-app.sh "$CONFIG"

cat <<'TXT'

重编译后如果功能异常，按这个顺序排查：

1) 截图拿到黑屏 / 提示未授权：
     tccutil reset ScreenCapture com.ebertwiseman.toolbox
2) 剪贴板"选中后只复制不粘贴"：
     tccutil reset Accessibility com.ebertwiseman.toolbox
3) 执行完上面两条后必须完全退出并重开 App（授权状态在进程启动时读取）：
     pkill -x Toolbox; open Build/Toolbox.app
4) 权限当前值随时可查：
     open Build/Toolbox.app --stderr /tmp/perms.log --args --perms; sleep 2; cat /tmp/perms.log
5) 热键是否全部注册成功：
     open Build/Toolbox.app --stderr /tmp/hk.log --args --hotkey-probe; sleep 2; cat /tmp/hk.log

注意：查询窗口/权限的探针进程自己也要有屏幕录制权限，
否则 CGWindowList 会"看不见"别的 App 的窗口，误判成功能没生效。
