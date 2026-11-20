#!/bin/bash
# 把本次 vX.Y.Z release 的 Windows 产物同步覆盖到 stable 滚动 tag（发版第 5 步，RELEASING.md）。
#
# 已安装的 Windows 版本从 releases/download/stable/ 拉更新（settings.json 默认 updateUrl），
# 这个 tag 的内容必须永远 = 最新发的 Windows 产物。版本号本身记录在 releases.win.json 里。
#
# 防踩守卫（不变式见 RELEASING.md）：
#   stable 必须保持 prerelease=True —— Mac 更新器查 releases/latest（GitHub 的 latest 不含
#   prerelease），Windows 资产不能出现在那里；此脚本只动 stable，天然满足。
#
# 依赖：gh（GitHub CLI，已 gh auth login）。产物目录 = windows/Build/Releases。
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASES_DIR="windows/Build/Releases"
TAG="stable"
REPO="Think-Me/toolbox"

command -v gh >/dev/null || { echo "❌ 需要 gh（GitHub CLI），先 gh auth login" >&2; exit 1; }

[ -f "$RELEASES_DIR/releases.win.json" ] || {
  echo "❌ 找不到 $RELEASES_DIR/releases.win.json —— 先跑 vpk pack（RELEASING.md 第 3 步）" >&2
  exit 1
}

# Windows 当前产物版本（只用于人读的回显；覆盖动作与版本号无关）
VER="$(python3 -c "import json;print(json.load(open('$RELEASES_DIR/releases.win.json'))['assets'][-1]['version'])" 2>/dev/null \
  || grep -o '"Version":"[^"]*"' "$RELEASES_DIR/releases.win.json" | head -1 | cut -d'"' -f4)"
echo "同步 Windows $VER 产物 → $TAG 滚动 tag"

# 先删旧 release（保留 tag：旧安装版的 updateUrl 仍解析 tag，删资产重建即可）
gh release delete "$TAG" --yes --cleanup-tag=false 2>/dev/null || true

# prerelease=True：不让 stable 挡住 releases/latest（Mac 更新器从 latest 找 dmg）
gh release create "$TAG" \
  --title "stable（滚动更新源）" \
  --notes "自动更新用滚动 release。内容随 main 上最新打包持续替换，版本号看 releases.win.json。" \
  --prerelease

for f in "$RELEASES_DIR"/*; do
  case "$(basename "$f")" in
    Toolbox-win-Setup.exe|*-full.nupkg|*-delta.nupkg|releases.win.json)
      gh release upload "$TAG" "$f" --clobber
      echo "  已上传 $(basename "$f")"
      ;;
    assets.win.json|RELEASES)
      # vpk 的本地清单，线上更新用不到
      ;;
    *)
      echo "  跳过 $(basename "$f")（不识别，人工确认）" >&2
      ;;
  esac
done

echo "✅ stable 已同步到 Windows $VER。下一步按 RELEASING.md 发 vX.Y.Z 正式 release（两端资产齐全）。"
