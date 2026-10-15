#!/bin/zsh
# 安装「Finder 右键 → 快速操作 → 新建 文本/Word/Excel/PPT」服务。
# 幂等：可重复运行。卸载见 uninstall.sh。
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
here="$(cd "$(dirname "$0")" && pwd)"
helper="$HOME/Library/Application Support/ToolboxNewFile"
mkdir -p "$helper"
cp "$here/newfile.sh" "$helper/newfile.sh"; chmod +x "$helper/newfile.sh"
cp "$here/make-workflow.sh" "$helper/make-workflow.sh"; chmod +x "$helper/make-workflow.sh"
"$helper/make-workflow.sh" txt  "文本文件 .txt" txt
"$helper/make-workflow.sh" docx "Word 文档 .docx" docx
"$helper/make-workflow.sh" xlsx "Excel 表格 .xlsx" xlsx
"$helper/make-workflow.sh" pptx "PPT 演示 .pptx" pptx
/System/Library/CoreServices/pbs -flush
echo "已安装 4 个快速操作。Finder 里右键 →「快速操作」即可看到。"
echo "首次使用会请求「控制 Finder」的自动化权限，允许即可。"
