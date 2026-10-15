#!/bin/zsh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
rm -rf "$HOME/Library/Services/新建 文本文件 .txt.workflow" \
       "$HOME/Library/Services/新建 Word 文档 .docx.workflow" \
       "$HOME/Library/Services/新建 Excel 表格 .xlsx.workflow" \
       "$HOME/Library/Services/新建 PPT 演示 .pptx.workflow"
rm -rf "$HOME/Library/Application Support/ToolboxNewFile"
/System/Library/CoreServices/pbs -flush
echo "已卸载。"
