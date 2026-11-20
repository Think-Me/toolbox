# 发布流程（RELEASING）

一个仓库、两个平台、**统一版本号、一个 release 页**。任何一端有改动都可以随时发版——
没改的那端把上一版产物**原样重传**，两端用户的更新器都不会误推更新。

## 版本号规则

- 仓库版本号 `X.Y.Z`，两处文件必须一致（`chore(release)` 提交同时 bump）：
  - Mac：`Resources/Info.plist` 的 `CFBundleShortVersionString`
  - Windows：`windows/Directory.Build.props` 的 `<Version>`（程序集版本、设置页显示、vpk 的 packVersion 都从它来）
- 版本号是 **repo 级**的：标识仓库状态，不表示哪端有变更。哪端改了什么写进 release note。
- **Mac 更新判定不看仓库版本**，而看 `Resources/Info.plist` 的 `CFBundleVersion`（Mac 内容版本，
  发版时通过 `mac.json` 资产发布）：
  - 只有 macOS 代码/资源**真的改了**才 +1；Windows-only 发版保持原值。
  - 这样统一版本号 bump、但 Mac 没变时，Mac 更新器不会误报可更新。
- 首个统一版本从 **0.3.0** 起（此前 Mac 线上 0.1.14、Windows 线上 0.2.6，都小于 0.3.0，不触发任何端降级）。

## 发版步骤

1. **bump 版本**：两处仓库版本文件改成 `X.Y.Z`；若本次 macOS 有改动，同时把
   `Resources/Info.plist` 的 `CFBundleVersion` +1。提交 `chore(release): vX.Y.Z`。
2. **Mac 产物**（macOS 机器）：

   ```bash
   make dmg                   # → Build/Toolbox.dmg
   ./Scripts/gen-mac-json.sh  # → Build/mac.json（记录 macBuild）
   ```
3. **Windows 产物**（Windows 机器，**仅当 Windows 有改动时**）：

   ```powershell
   cd windows
   dotnet publish src/Toolbox.App/Toolbox.App.csproj -p:PublishProfile=win-x64
   $ver = (Select-String -Path windows\Directory.Build.props -Pattern '<Version>([^<]+)').Matches[0].Groups[1].Value
   vpk pack -r win-x64 --packId Toolbox --packTitle Toolbox --packVersion $ver `
     --packDir windows\Build\win-x64 --mainExe Toolbox.App.exe `
     --icon windows\src\Toolbox.App\Assets\Toolbox.ico `
     --noPortable `
     --outputDir windows\Build\Releases
   ```

   产物：`Toolbox-win-Setup.exe` / `Toolbox-X.Y.Z-full.nupkg` / `releases.win.json`。
   Windows 没改动时**不要重新打包**，直接重传上一版产物（`--noPortable` 后不再生成 Portable）。
4. **建 release** `vX.Y.Z`，资产**必含两端**：
   - macOS：`Toolbox.dmg` + `mac.json`（Mac 更新器靠 `mac.json` 判断是否真有更新）
   - Windows：`Toolbox-win-Setup.exe` + `Toolbox-X.Y.Z-full.nupkg` + `releases.win.json`
   - 没改动的一端重传上一版的原样产物（同版本 `mac.json` / nupkg）。
5. **同步 Windows 滚动源**：`./Scripts/sync-stable.sh`（仅当 Windows 有改动时需要）。
   已装版本硬编码从 `releases/download/stable/` 拉更新，这个 tag 必须保持最新；Windows 没改就跳过。
6. **release note** 按下面的模板写清哪端有变更。

## 防踩规则（不变式，改流程前先读）

- **`stable` tag 必须保持 prerelease=True**：Mac 更新器查 `releases/latest`，而 GitHub 的 latest
  不含 prerelease——这是 Windows 资产不干扰 Mac 更新检查的关键机制。
- **Windows 产物永远不要单独发成非 prerelease 的 release**：`AppUpdater.parseRelease` 在 latest 里
  找不到 `.dmg` 会直接报错（全员更新检查失败）。"每个 release 资产必含两端"同时堵住这颗雷。
- **没改的一端重传上一版产物是安全的**：
  - Mac：重传上一版 DMG + 同一个 `mac.json`（macBuild 不变）→ 更新器判「已是最新」。
  - Windows：重传上一版 nupkg/feed（内嵌版本不变）→ `CheckForUpdatesAsync` 返回 null。
- **`mac.json` 必须与 DMG 里的 `CFBundleVersion` 一致**：build 偏小会漏推，偏大会造成反复更新。
  每次 `make dmg` 后用 `./Scripts/gen-mac-json.sh` 生成，不要手写。
- **Windows 没改时不要用新的统一版本重新打包**：nupkg 内嵌版本会跟着涨，Velopack 就会误推。
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
- **为什么 Mac 用 `mac.json` 而不是 tag 版本**：统一版本号每版都会涨，但 macOS 可能并没有改动；
  直接比 tag 会把 Windows-only 发版误判成 Mac 有新版本。`mac.json` 记录的是真正影响 Mac 的内容版本。
- **为什么 Windows 更新源仍指固定滚动 tag 而不是版本化 release**：更新 URL 不能随发版变（旧安装版
  里是硬编码的），滚动 tag 语义就是"Windows 最新"；版本化 release 上的同款资产用于人工下载溯源。
