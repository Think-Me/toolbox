# Toolbox

一个 macOS 菜单栏效率工具，把三类常用功能收进一个常驻 App：

- **剪贴板历史** —— 全局热键呼出，选中即用、自动粘贴、置顶、图片/文件记录
- **Hosts 规则切换** —— 类似 SwitchHosts，一键启停规则、可选自动刷新 DNS
- **截图 + 贴图 + 标注** —— 类似 Snipaste，选区吸附、放大镜取色、矩形/箭头/画笔/马赛克/文字标注
- **本地代理** —— 内置 Xray 内核，把节点转成本地 SOCKS/HTTP 代理，一键系统代理（不做 TUN）

纯菜单栏（`LSUIElement`）App，不占 Dock；Swift + AppKit（设置页用 SwiftUI）。

## 环境要求

- macOS 15+（截图用 `SCScreenshotManager`）
- Apple Silicon（内置的 Xray 内核为 arm64）

## 构建

```bash
make app     # 编译并组装 Build/Toolbox.app（自签名）
make test    # 运行全部单元测试
make smoke   # 热键端到端冒烟（需关闭 RustDesk 等占用 Secure Input 的程序）
make dmg     # 打包 Build/Toolbox.dmg（可分发）
```

首次构建代理功能需要联网下载内置内核：

```bash
./Scripts/fetch-xray.sh   # make app 会自动调用其产物，缺失时代理功能降级
```

## 签名与权限（重要）

本项目**自用**，用本地自签证书（`Scripts/create-signing-cert.sh` 生成），designated requirement
基于 bundle id，使 TCC 授权能跨重建保留。代价：

- 分发给别人时，macOS 会因未经 Apple 公证而拦截。`make dmg` 已内置「解除隔离.command」，
  接收方拖 app 到「应用程序」后双击它即可放行。
- 首次运行需在「系统设置 → 隐私与安全性」手动授予：
  - **屏幕录制**（截图）
  - **辅助功能**（自动粘贴）
  - 可选：`/etc/hosts` 组可写、免密刷新 DNS（App 内会引导一次性授权）

若要正式分发，需要 Developer ID 证书 + 公证（Apple 开发者账号）。

## 快捷键（默认，均可在设置里改）

| 功能 | 键位 |
|---|---|
| 剪贴板历史 | `⌃⌘V` |
| Hosts 快速切换 | `⌘⇧H` |
| 区域截图 | `⌃⌘A` |
| 全屏截图并贴图 | `F2` |
| 收回所有贴图 | `F3` |

## 目录结构

```
Sources/ToolboxKit/     核心库（剪贴板 / hosts / 截图 / 代理 / 基础设施）
Sources/Toolbox/        可执行入口（AppDelegate、菜单、热键注册、调试探针）
Tests/ToolboxKitTests/  单元测试
Scripts/                构建/签名/打包脚本
```

## Finder 右键「新建文件」（可选安装）

提供一个 macOS 缺失的能力：在 Finder 里右键 → **快速操作** → 新建
`文本文件 .txt / Word 文档 .docx / Excel 表格 .xlsx / PPT 演示 .pptx`，
文件名默认为时间戳 `yyyyMMddHHmmss.<ext>`（同秒冲突自动加序号），生成后在 Finder 中选中。

安装 / 卸载：

```bash
./Scripts/newfile-service/install.sh     # 装 4 个快速操作（幂等，可重复运行）
./Scripts/newfile-service/uninstall.sh   # 卸载
```

说明：
- 这是**系统级 Quick Action**，独立于 Toolbox App 本体，装在 `~/Library/Services`；
  不随 .app 分发，需要时在本机跑 `install.sh`。
- 服务是「无输入」型，所以在文件夹空白处右键也会出现；语义是"当前最前 Finder
  窗口的文件夹"（桌面上右键则建到桌面）。
- 首次使用会请求"控制 Finder"的自动化权限，允许一次即可。
- docx/xlsx/pptx 由脚本内联生成最小合法 OOXML（不依赖 python/Office）。
- 受 macOS 限制，"快速操作"是服务菜单的一层，做不到"New ▸ 二级子菜单"，
  故为四个并列项。

## 许可

本项目暂不附开源许可证（保留所有权利）。内置的 Xray 内核为独立二进制，
遵循其上游 MPL-2.0 许可；分发时请一并遵守。
