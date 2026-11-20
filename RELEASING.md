# 发布流程（RELEASING）

一个仓库、两个平台、**统一版本号、一个 release 页**。任何一端有改动都可以随时发版——
没改的那端把上一版产物**原样重传**，两端用户的更新器都不会误推更新。

## 版本号规则

- 单一版本号 `X.Y.Z`，两处文件必须一致（`chore(release)` 提交同时 bump）：
  - Mac：`Resources/Info.plist` 的 `CFBundleShortVersionString`（`CFBundleVersion` 是 build 计数，独立递增）
  - Windows：`windows/Directory.Build.props` 的 `<Version>`（程序集版本、设置页显示、vpk 的 packVersion 都从它来）
- 版本号是 **repo 级**的：标识仓库状态，不表示哪端有变更。哪端改了什么写进 release note。
- 首个统一版本从 **0.3.0** 起（此前 Mac 线上 0.1.14、Windows 线上 0.2.6，都小于 0.3.0，不触发任何端降级）。

## 发版步骤

1. **bump 版本**：两处版本文件改成 `X.Y.Z`，提交 `chore(release): vX.Y.Z`。
2. **Mac 产物**（macOS 机器）：`make dmg` → `Build/Toolbox.dmg`。
3. **Windows 产物**（Windows 机器）：

   ```powershell
   cd windows
   dotnet publish src/Toolbox.App/Toolbox.App.csproj -p:PublishProfile=win-x64
   $ver = (Select-String -Path windows\Directory.Build.props -Pattern '<Version>([^<]+)').Matches[0].Groups[1].Value
   vpk pack -r win-x64 --packId Toolbox --packTitle Toolbox --packVersion $ver `
     --packDir windows\Build\win-x64 --mainExe Toolbox.App.exe `
     --icon windows\src\Toolbox.App\Assets\Toolbox.ico `
     --outputDir windows\Build\Releases
   ```

   产物：`Toolbox-win-Setup.exe` / `Toolbox-win-Portable.zip` / `Toolbox-X.Y.Z-full.nupkg` / `releases.win.json`。
4. **建 release** `vX.Y.Z`，资产**必含两端**：
   - `Toolbox.dmg`（必有——Mac 更新器从 `releases/latest` 里找它）
   - Windows 四件套（`releases.win.json` 是 Velopack 的更新 feed）
5. **同步 Windows 滚动源**：`./Scripts/sync-stable.sh`（把第 4 步的 Windows 资产 clobber 覆盖到 `stable` tag）。
   已装版本硬编码从 `releases/download/stable/` 拉更新，这个 tag 必须永远最新。
6. **release note** 按下面的模板写清哪端有变更。

## 防踩规则（不变式，改流程前先读）

- **`stable` tag 必须保持 prerelease=True**：Mac 更新器查 `releases/latest`，而 GitHub 的 latest
  不含 prerelease——这是 Windows 资产不干扰 Mac 更新检查的关键机制。
- **Windows 产物永远不要单独发成非 prerelease 的 release**：`AppUpdater.parseRelease` 在 latest 里
  找不到 `.dmg` 会直接报错（全员更新检查失败）。"每个 release 资产必含两端"同时堵住这颗雷。
- **没改的一端重传上一版产物是安全的**：
  - Mac：`ProxyVersion.isNewer(同版本) = false` → 报「已是最新」，不推。
  - Windows：Velopack feed 同版本 → `CheckForUpdatesAsync` 返回 null → 「已是最新版本」，不推。
- `stable` 这个名字不能改：已装版本的 updateUrl 硬编码指向 `releases/download/stable/`。
- vpk 的 `--packVersion` 必须与 `Directory.Build.props` 的 `<Version>` 一致（发版脚本从 props 里提取，
  别手敲）。

## release note 模板

```
## Toolbox vX.Y.Z

### Windows
- 修复：……

### macOS
- 无变更（沿用上一版产物）
```

## 为什么这样设计

- **为什么统一版本号而不是各发各的**：此前 Mac v0.1.14 / Windows 0.2.6 各自漂移，"v0.2.6 修了什么"
  只对一端成立；本地工作副本甚至落后于线上 Windows。统一后一个版本号回答"仓库现在是什么状态"。
- **为什么没改的一端要重传产物而不是留空**：Mac 更新器对 latest 里没有 dmg 的 release 会报错；
  且手动从 releases 页下载的用户（无论哪端）在任何最新 release 里都该找得到对应平台的安装包。
- **为什么 Windows 更新源仍指固定滚动 tag 而不是版本化 release**：更新 URL 不能随发版变（旧安装版
  里是硬编码的），滚动 tag 语义就是"Windows 最新"；版本化 release 上的同款资产用于人工下载溯源。
