# Toolbox for Windows

macOS 版的功能对等移植，技术栈 **.NET 10 + WPF**。本目录是独立解决方案，和根目录的 Swift 工程互不影响。

> 当前状态：**核心逻辑层完成；P0 骨架已可运行** —— 托盘图标、单实例、全局热键、
> 设置窗（通用页）、日志与崩溃兜底都已接通。
> 剪贴板 / 翻译 / Hosts / 截图四个模块仍是占位，点菜单会明确告诉你它在哪个阶段实现（P1–P4）。

## 为什么是 WPF

- 截图/贴图/标注需要**全屏透明置顶窗、多显示器、逐像素绘制、贴图窗口长期驻留**，WPF 的 `Window` + `DrawingVisual` 最直接。
- 剪贴板/热键/UI Automation/注册表都是 Win32 能力，WPF 进程内 P/Invoke 即可。
- WebView 方案（Tauri/Electron）在这些场景要额外处理 DPI、透明窗、内存和原生消息，且贴图多开时内存代价高；首版不选。
- 不使用 WinUI 3：截图遮罩和贴图窗口的窗口样式控制不如 WPF 成熟，且需要 Windows App SDK 运行时。

目标框架：

| 项目 | TFM | 说明 |
|---|---|---|
| `Toolbox.Core` | `net10.0` | 纯逻辑，可跨平台单测 |
| `Toolbox.Core.Tests` | `net10.0` | xUnit |
| `Toolbox.App` | `net10.0-windows` | WPF，`UseWPF=true`，`WinExe`，x64 |
| `Toolbox.Elevated`（待建） | `net10.0-windows` | 控制台/WinExe，仅做 hosts 写入 |

## 目录

```
windows/
  Toolbox.slnx                  # Core + App + Tests
  Directory.Build.props
  src/
    Toolbox.Core/
      Infrastructure/           # AppPaths、滚动日志
      Shell/                    # 托盘菜单的纯数据契约（TrayMenuBuilder）
      Settings/                 # AppSettings、热键解析与校验、JSON 读写
      Hosts/                    # 规则模型 + 哨兵块编译器
      Clipboard/                # 条目模型、采集策略、SQLite 存储
      Translation/              # 引擎、语言码、网络策略、HTTP 客户端
      Capture/                  # 虚拟桌面/选区/DPI/马赛克几何
    Toolbox.App/                # P0：托盘、热键、设置窗、日志
      Shell/                    # TaskbarSink、TrayIcon、TrayMenu、SingleInstance、LoginItem
      Hotkeys/                  # HotkeyService（RegisterHotKey 包装）
      Actions/                  # AppActionTable（菜单与热键共用）
      Settings/                 # SettingsWindow、HotkeyRecorderBox、占位页
      Diagnostics/              # --probe 报告
    Toolbox.Elevated/           # 待建：提权写 hosts
  tests/
    Toolbox.Core.Tests/         # 98 个用例（2026-10-24）
```

## 构建与测试

Windows 10 1903+ / Windows 11，安装 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)：

```powershell
winget install Microsoft.DotNet.SDK.10
cd windows
dotnet test Toolbox.slnx        # 单元测试
dotnet run --project src/Toolbox.App/Toolbox.App.csproj   # 启动托盘 App（无窗口）
```

冒烟检查（脚本友好）：`Toolbox.App.exe --probe` 会把托盘、热键注册结果、开机自启状态、
设置窗能否加载写进 `%LOCALAPPDATA%\Toolbox\probe.txt`，全通过时退出码 0，否则 1。

打包成**可双击运行的自包含目录**（目标机器不需要装 .NET）：

```powershell
dotnet publish src/Toolbox.App/Toolbox.App.csproj -p:PublishProfile=win-x64
# 产物：windows/Build/win-x64/Toolbox.App.exe（约 251 个文件 / 134 MB）
```

刻意不用单文件：托盘图标是用 `LoadImage(LR_LOADFROMFILE)` 从 `Assets/Toolbox.ico` 读的，
单文件打包后这个文件不在磁盘上，得先改成嵌入资源再从内存建 `HICON`。留到 P5 做安装器时一起处理。

> 如果 SDK 装在用户目录（`%USERPROFILE%\.dotnet`）而不是 `C:\Program Files\dotnet`，
> 直接双击 `bin/Debug` 下的 exe 会报"缺少 .NET 运行时"，因为 apphost 只认系统安装位置。
> 要么设 `DOTNET_ROOT`，要么用上面的自包含产物。

macOS 上也能跑核心层（WPF 项目不能编译）：

```bash
~/.dotnet/dotnet test windows/tests/Toolbox.Core.Tests/Toolbox.Core.Tests.csproj
```

CI：`.github/workflows/windows.yml` 在 `windows-latest` 上 restore/build/test，`Toolbox.App` 也会一起编译。
但 CI 没有交互桌面，托盘和热键只能靠 `--probe`（本地跑）和手工验收。

## 数据与配置

| 内容 | 路径 |
|---|---|
| 设置 | `%APPDATA%\Toolbox\settings.json` |
| Hosts 规则库 | `%APPDATA%\Toolbox\hosts\rules.json` |
| 剪贴板数据库 | `%LOCALAPPDATA%\Toolbox\clipboard.db`（WAL） |
| 剪贴板图片 | `%LOCALAPPDATA%\Toolbox\media\<sha256>.png` |
| AI Key | `%APPDATA%\Toolbox\ai.key`（DPAPI `CurrentUser` 加密，**不写 settings.json**） |
| 日志 | `%LOCALAPPDATA%\Toolbox\logs\` |
| `--probe` 报告 | `%LOCALAPPDATA%\Toolbox\probe.txt` |

设置写入是「临时文件 + 原子替换」；JSON 解码失败时备份为 `settings.json.corrupt-<ts>` 再回落默认值。翻译设置里的未知引擎（例如 macOS 的 `apple`）回落为 `auto`，不会让整份配置失效。

## 已实现的核心逻辑

### 设置与热键

- `HotkeyGesture`：修饰键 + Win32 虚拟键码，序列化成 `Ctrl+Alt+V`；解析大小写不敏感，支持 `F1–F24`、`Space/Enter/Esc/Tab/Backtick`。
- 默认热键：剪贴板 `Ctrl+Alt+V`、翻译 `Ctrl+Alt+T`、Hosts `Ctrl+Alt+H`、截图 `Ctrl+Alt+A`（均可在设置里改）。
- `SettingsStore` 原子写入、坏文件备份、缺字段用默认值。

### Hosts 规则

和 macOS 版同一套**托管块**模型：

```
# >>> Toolbox managed >>>
# ==== 规则名 ====
127.0.0.1 dev.example.com
# <<< Toolbox managed <<<
```

- 只替换自己哨兵之间的内容，块外用户手写行原样保留。
- 哨兵缺失/重复/顺序颠倒 → 抛 `BrokenSentinelException`，**绝不猜范围**。
- 支持行内 `#` / `//` 注释、一行多域名、IPv6、CRLF、BOM。
- 同一域名被多条启用规则指向不同 IP 时报冲突（只提示，不阻断）。
- 关掉总开关或删除全部规则 → 摘掉托管块，恢复原 hosts。

待实现的写入侧（`Toolbox.Elevated`）：

1. App 编译好完整 hosts 文本，写入 `%TEMP%\toolbox-hosts-<guid>.txt`。
2. `Process.Start(new ProcessStartInfo("Toolbox.Elevated.exe", "--apply <file>") { Verb = "runas", UseShellExecute = true })`。
3. Helper 校验参数、备份现有 hosts、原地覆盖（保留 ACL）、`ipconfig /flushdns`，退出码/JSON 结果回传。
4. 备份放 `%ProgramData%\Toolbox\hosts\`，首次写入前存 `original.hosts`，之后每次 `backup-<ts>.hosts`，保留最近 50 份；`--restore` 恢复 `original.hosts`。
5. 每次应用都会弹一次 UAC。首版接受这个成本；后续可改成常驻提权服务 + 命名管道。

安全边界：Helper 只接受「一个文件路径」，只做 hosts 写入 + flushdns，不接受任意命令/参数拼接。

### 剪贴板历史

已实现（Core）：

- 条目类型：`text` / `image` / `fileURLs`，图片只存 SHA-256，实体在 `media/`。
- 采集策略 `ClipboardFilter`：排除进程（KeePass/1Password/Bitwarden，可配置）、自己写回后的 800ms 忽略窗、空文本/空文件列表、文本与图片大小上限。
- 与最近一条内容相同 → 不新增，只更新 `last_copied_at` 并 `copy_count+1`。
- SQLite schema 与 macOS 版字段对齐：`id, kind, text, media_sha, file_urls, byte_length, pixel_w, pixel_h, source_process, source_app_name, pinned, created_at, last_copied_at, copy_count`。
- 列表排序：置顶优先 → `last_copied_at` 倒序 → `rowid` 倒序（同一 tick 写入也有稳定顺序）。
- 淘汰：只删非置顶、按最旧优先；置顶数超过容量时一条都不删。
- 搜索转义 `%` / `_` / `\`。

待实现的采集/交互侧（`Toolbox.App`）：

- 隐藏消息窗 + `AddClipboardFormatListener`，处理 `WM_CLIPBOARDUPDATE`；打开剪贴板失败时重试（剪贴板被占用很常见）。
- 格式优先级：`CF_HDROP` → 注册格式 `PNG` → `CF_DIB`（转 PNG）→ `CF_UNICODETEXT`。
- 来源进程：`GetForegroundWindow` + `GetWindowThreadProcessId` + `QueryFullProcessImageName`。
- 面板：无边框置顶、`ShowActivated=false`；搜索框、↑↓ 选择、Enter 粘贴、`Ctrl+P` 置顶、Delete 删除、Esc 关闭。
- 粘贴：记录呼出前的目标窗口 → 写剪贴板并打「自己写入」时间戳 → 隐藏面板 → `SetForegroundWindow` → `SendInput Ctrl+V`。目标若是管理员进程，UIPI 会拦截合成输入，此时只能提示用户手动粘贴。
- 图片缩略图按需解码，避免一次把几百张 4K 图读进内存。

### 划词翻译

已实现（Core）：

| 引擎 | 端点 | 自动链 |
|---|---|---|
| `auto` | 有道失败 → MyMemory | ✅ |
| `youdao` | `aidemo.youdao.com/trans`（表单 POST，`from=auto`） | 国内直连 |
| `mymemory` | `api.mymemory.translated.net/get`（无 auto，本地猜源语言） | 国内直连 |
| `google` | `translate.googleapis.com/translate_a/single` | 需代理 |
| `ai` | OpenAI 兼容 `chat/completions` | 按域名 |

- 语言码转换：`zh-Hans → zh-CHS / zh-CN`，`zh-Hant → zh-CHT / zh-TW`；`GuessSource` 用 Unicode 区段识别中日韩俄泰阿；源==目标时自动换向（简↔繁除外）。
- 网络策略 `auto`：有道/MyMemory/国内 AI 域名直连，其余走 `127.0.0.1:<proxyPort>`；可强制直连或全局代理。
- 各引擎解析、错误码、HTML 拦截、实体还原、AI 缺 Key 均有测试。
- 没有 Apple 本地翻译：Windows 首版自动链是有道 → MyMemory。系统装了语言包可用 Windows 本地翻译作为后续增强（`Windows.Globalization` + `LanguageModel`，能力不如 Apple 稳定）。

待实现的交互侧（`Toolbox.App`）：

- 取词：UI Automation `AutomationElement.FocusedElement` + `TextPattern.GetSelection()`；失败回退「发 Ctrl+C → 读剪贴板 → 恢复原剪贴板」。
- 浮窗：置顶、无激活、340px 宽自适应高；头部显示实际引擎短名；引擎下拉切换后持久化并重译；复制/朗读/替换原文/钉住。
- **请求序号**：每次重译 `requestId+1`，迟到的旧结果直接丢弃，避免旧译文覆盖新译文（macOS 版踩过的坑）。
- 替换原文：优先 UIA `TextPattern` 写入，失败回退「粘贴」；替换后不重复采集剪贴板。
- 朗读：`System.Speech.Synthesis.SpeechSynthesizer`，按目标语言挑 voice；中文 voice 需系统安装对应语言包。

### 截图 / 贴图 / 标注

Core 只放了与平台无关的几何：

- 虚拟桌面 = 所有显示器边界的并集（支持负坐标）。
- 任意方向拖拽归一化；小于 3×3 视为误触。
- 命中测试 `MonitorAt`；像素↔DIP 换算（PerMonitorV2 每个显示器比例可不同）。
- 马赛克块大小随选区收缩，保证至少 3×3 块。

待实现的 `Toolbox.App`：

- 截屏：`BitBlt` 抓虚拟桌面（`CAPTUREBLT`）→ 冻结成一张位图；HDR/受保护内容后续再评估 `Windows.Graphics.Capture`。
- 遮罩窗：覆盖虚拟桌面、半透明黑、十字光标、放大镜取色、选区八向手柄、尺寸提示。
- 工具栏：矩形/椭圆/箭头/画笔/文字/马赛克、撤销、复制、保存、贴图、取消。
- 标注先画在 WPF `Canvas`/`DrawingVisual`，导出时栅格化到 PNG；马赛克对选区像素做块平均。
- 贴图窗：无边框置顶、可拖动、滚轮缩放、`Ctrl+滚轮` 透明度、双击/右键关闭；多贴图各自独立窗口。
- 多显示器混合 DPI：进程 manifest 声明 `PerMonitorV2`，所有坐标在像素与 DIP 间显式换算。

## 待办（按依赖顺序）

### P0 骨架
- [x] `Toolbox.App`：WPF `WinExe`、单实例互斥、托盘图标（`Shell_NotifyIcon` P/Invoke）、托盘菜单、开机自启（HKCU Run）。
- [x] 隐藏消息窗：全局热键 `RegisterHotKey`、`WM_HOTKEY` 分发、热键冲突提示。
- [x] 设置窗口：通用页（热键录制 + 开机自启）为真功能，其余四页标注待实现阶段。
- [x] 日志与全局异常兜底（未处理异常写日志 + 托盘气泡）。

### P1 剪贴板（已完成）
- [x] `ClipboardMonitor`（格式读取、来源进程、自己写入抑制、通知去抖）。
- [x] 面板 UI + 搜索 + 键盘操作 + 粘贴回目标窗口。
- [x] 图片 DIB→PNG（`--probe` 里有确定性的转换自检）。
- [x] 面板内图片缩略图（DecodePixelWidth=48 按需解码 + sha 缓存）、启动时清理孤立媒体文件。
- [x] 端到端自测：`--paste-probe` + UIA 驱动记事本，验证文本逐字符落地、自写抑制生效。

### P2 翻译（进行中）
- [x] UIA 取词 + Ctrl+C 回退（含剪贴板恢复、自写抑制，划的词不会混进历史）。
- [x] 浮窗 UI（引擎下拉切换并持久化/钉住/复制/朗读/替换原文/重新翻译/请求序号作废）。
- [x] TTS 朗读（System.Speech；精简系统没有 SAPI 语音时气泡提示，不崩）。
- [x] 设置页「翻译」真页签：引擎/目标语言/网络/代理端口/AI 配置；AI Key DPAPI 读写（ai.key）。
- [x] 端到端自测：`--translate-probe` 抓原始响应体 + UIA 驱动记事本划词断言译文。
      实测有道会把数字字段发成字符串（`"errorCode":"0"`），解析层已容错。

### P3 Hosts（基本完成）
- [x] `Toolbox.Elevated` 写入/备份/恢复/flushdns。**自包含单文件**：提权进程不继承
      `DOTNET_ROOT`，框架依赖的 helper 在提权下会因找不到运行时直接失败（实测踩过）。
- [x] 规则库启停（托盘子菜单 + 设置页勾选即应用）、应用结果气泡、托管块异常引导（绝不猜范围）。
- [x] 备份策略：`%ProgramData%\Toolbox\hosts\` 首次存 `original.hosts`，每次 `backup-<ts>.hosts`，保留最近 50 份。
- [ ] 规则的新建/内联编辑；本地文件/远程 URL + ETag 缓存抓取。

### P4 截图（进行中）
- [x] 抓屏：`BitBlt`（CAPTUREBLT）抓光标所在显示器 -> 冻结位图；`--capture-probe` 产物级验证（整屏 + 裁剪尺寸断言）。
- [x] 遮罩窗：压暗 + 选区"亮起" + 尺寸提示 + Esc/双击复制。
- [x] 标注：矩形/箭头/画笔/马赛克/撤销。标注即时栅格化进 WriteableBitmap，导出所见即所得；
      马赛克块平均在 Core（`Mosaic`，选区内像素参与平均，块对齐 blockSize 网格，有测试）。
- [x] 贴图窗：拖动、滚轮缩放、Ctrl+滚轮透明度、双击/右键关闭；多贴图独立窗口。
- [x] 复制进历史（不打自写标记：截图复制本来就是真实复制）。
- [ ] 椭圆/文字标注。
- [ ] 多显示器：v1 只抓光标所在那台；混合 DPI 已按 PerMonitorV2 逐屏取，拼接待做。

### P5 发布（已完成，签名除外）
- [x] 自包含 `win-x64` 发布 + **Velopack** 安装器/便携包/更新包（`vpk pack`，见 App csproj 的
      `PublishElevatedHelper` / `CopyElevatedHelper`；`windows/Build/Releases/` 为产物）。
- [x] 自动更新：App 内置 Velopack（`VelopackApp` + `UpdateService`），仅安装版生效；
      更新源 = settings.json 的 `updateUrl`（默认 GitHub releases `stable` tag，留空关闭）。
      发现新版本 → 后台下载 → 退出时自动安装。
- [ ] 代码签名（OV/EV 证书需购买，未做）：未签名 exe 会被 SmartScreen/杀软拦。
- 注：安装器里 hosts helper 是自包含单文件；**代码签名时 vpk 会连 helper 一起签**。

## 测试策略

- Core 层继续用 xUnit；macOS 版 `Tests/ToolboxKitTests` 的 552 个用例是行为规格，按模块逐条移植，**不要只测新写的代码**。
- 已移植 121 条：设置/热键、hosts 编译与冲突、剪贴板策略与 SQLite、翻译解析/网络策略/自动降级、截图几何，
  以及 P0/P1 新增的路径表、滚动日志、热键校验、托盘菜单契约、列表选中管理、媒体清理。
- UI 层无法在 CI 验证，每个模块附手工验收清单：
  - 剪贴板：文本/图片/多文件、置顶、搜索、粘贴到记事本/浏览器/终端、排除密码管理器。
  - 翻译：中英日互译、无选区、跨进程取词、引擎切换后旧结果不覆盖、AI 缺 Key 提示、代理开关。
  - Hosts：首次写入、重复应用、删除全部规则、手动改坏哨兵、无管理员权限取消 UAC、flushdns 失败提示。
  - 截图：单屏/双屏/负坐标/150% 缩放、选区各方向、复制到微信/画图、贴图拖动缩放、马赛克。

## 已知差异与风险

- **没有 Apple 本地翻译**：自动链退化为有道 → MyMemory；离线不可用。
- **UAC 频率**：首版每次应用 hosts 都提权；可接受但不够顺滑。
- **TTS**：`System.Speech` 的中文 voice 依赖系统语言包，未安装时只能英文。
- **代理**：Google/AI 走 `127.0.0.1:10809`，需要用户已有本地代理；Windows 版代理模块尚未移植。
- **截图**：`BitBlt` 对 HDR、DRM/受保护窗口支持差；WGC 方案需要额外处理光标与多显示器。
- **签名**：未签名 exe 会被 SmartScreen/杀软拦截，正式分发前必须买证书。
- **UI 自动化测不了**：CI 没有交互桌面，托盘图标和 `WM_HOTKEY` 只能在真机上验。所以提供了 `--probe`，
  把"注册成功了没、为什么失败"落成文本，骨架部分可脚本化验收。
- **开机自启只认 `HKCU\...\Run`**：任务管理器"启动"页禁用后会写 `StartupApproved\Run`，本版不读那个键，
  表现为"注册表里有值、实际没随系统启动"。
- **托盘菜单里未实现的模块是可点的**：点了会用气泡说明"将在 Pn 提供"，而不是静默无反应；
  但菜单目前没有置灰，和 Mac 版"带版本号的置灰占位行"略有差别。
- **UI 自动化**：部分应用（终端、游戏、自绘控件）不暴露 `TextPattern`，只能走 Ctrl+C 回退。

## 给接手的人：第一天

1. 装 .NET 10 SDK，`cd windows && dotnet test Toolbox.slnx`，确认 98 个用例全绿。
2. 用 VS 2022 17.14+ / Rider 打开 `Toolbox.slnx`（`.slnx` 需要较新工具链；老版本可 `dotnet sln migrate` 或新建 `.sln`）。
3. 跑一次 `dotnet run --project src/Toolbox.App/Toolbox.App.csproj -- --probe`，确认 `RESULT ok`、
   托盘和 4 个热键都正常；再双击 exe，确认托盘出图标、右键出菜单、设置窗能打开。
4. 按 P1→P4 顺序推进；每完成一个模块，把 macOS 对应测试用例补进 `Toolbox.Core.Tests`，
   并把托盘菜单里对应的那条从 `ReportPending` 换成真实现（动作表和菜单契约都已经就位）。
