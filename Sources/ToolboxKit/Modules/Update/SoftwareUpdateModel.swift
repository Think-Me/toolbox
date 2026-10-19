import Foundation
import SwiftUI

/// 软件自更新的 UI 状态源：查更新、下载、替换、重启。
@MainActor
public final class SoftwareUpdateModel: ObservableObject {
    @Published public var status: AppUpdateStatus?
    @Published public var isBusy = false          // 正在检查或下载
    @Published public var progress: Double?      // 下载进度 0...1
    @Published public var message: String?

    public let currentVersion: String
    private let settingsProvider: () -> UpdateSettings

    public init(settings: @escaping () -> UpdateSettings,
                currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0") {
        self.settingsProvider = settings
        self.currentVersion = currentVersion
    }

    private func makeFetcher() -> any HTTPFetching {
        let s = settingsProvider()
        return URLSessionFetcher(proxyPort: s.useProxy ? s.proxyPort : nil)
    }

    public func check() async {
        isBusy = true; message = "检查更新中…"
        let result = await AppUpdater.check(currentVersion: currentVersion,
                                            settings: settingsProvider(), fetcher: makeFetcher())
        status = result
        isBusy = false
        switch result {
        case .upToDate: message = "已是最新版本（\(currentVersion)）"
        case .available(let info): message = "发现新版本 \(info.version)"
        case .failed(let e): message = "检查失败：\(e)"
        }
    }

    /// 下载并安装。成功后本进程会退出、由外部脚本替换并重启。
    public func install() async {
        guard case .available(let info) = status else { return }
        isBusy = true; progress = 0; message = "下载更新…"
        do {
            let (dmg, mount) = try await AppUpdater.downloadAndMount(
                info: info, settings: settingsProvider(), fetcher: makeFetcher()) { p in
                Task { @MainActor in self.progress = p }
            }
            guard let newApp = AppUpdater.appInMount(mount) else {
                message = "镜像里没找到 Toolbox.app"; isBusy = false; progress = nil
                _ = AppUpdater.detach(mount)
                return
            }
            let current = Bundle.main.bundleURL
            let script = AppUpdater.swapScript(mountApp: newApp, currentApp: current, mount: mount, dmg: dmg)
            try Self.runDetached(script)
            message = "正在更新并重启…"
            // 给脚本一点启动时间再退出，让脚本接管替换
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        } catch {
            message = "更新失败：\(error)"; isBusy = false; progress = nil
        }
    }

    /// 把脚本写到临时文件并脱离本进程运行（本进程退出后它继续完成替换+重启）。
    private static func runDetached(_ script: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-swap-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [url.path]
        // 不继承标准 IO，避免随父进程退出被连带
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
