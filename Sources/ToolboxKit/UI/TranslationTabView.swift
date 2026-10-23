import SwiftUI

/// 设置页「翻译」。全局热键是 ⇧⌥T 同款可改，键位在「通用 › 快捷键」里。
struct TranslationTabView: View {
    @ObservedObject var model: AppModel
    @State private var keyDraft = ""
    @State private var keySaved = false

    private var t: TranslationSettings { model.settings.translation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("基本") { basicsSection }
                Divider().padding(.horizontal, 20)
                section("引擎") { engineSection }
                Divider().padding(.horizontal, 20)
                section("网络") { networkSection }
                Divider().padding(.horizontal, 20)
                section("AI 引擎") { aiSection }
            }
        }
        .frame(width: 560, height: 420)
        .onAppear { keyDraft = KeychainStore.aiKey ?? "" }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("目标语言").frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(
                    get: { t.targetLanguage },
                    set: { v in model.mutateTranslationSettings { $0.targetLanguage = v } })) {
                    ForEach(TranslationLanguages.targets, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
            Text("源语言自动识别；选中文本与目标语言相同时会翻译成英文。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { t.engine },
                set: { v in model.mutateTranslationSettings { $0.engine = v } })) {
                ForEach(TranslationEngine.allCases, id: \.self) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(engineHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineHint: String {
        switch t.engine {
        case .auto:
            return "Apple 本地可用时走本地（离线、免费）；否则依次尝试有道、MyMemory。"
        case .apple:
            return "macOS 15+ 的本地翻译，完全离线。语言对不支持时会报错，请在浮窗里换引擎。"
        case .youdao:
            return "有道公开接口，国内可直连；属于非官方接口，有频率限制。"
        case .mymemory:
            return "MyMemory 免费接口，直连可用；单次长度和每日额度有限。"
        case .google:
            return "Google 免费端点，国内必须走代理，且可能被反爬页拦截。"
        case .ai:
            return "任意 OpenAI 兼容接口（DeepSeek、通义、OpenAI…），质量最好但需要 Key。"
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("联网方式").frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(
                    get: { t.network },
                    set: { v in model.mutateTranslationSettings { $0.network = v } })) {
                    ForEach(TranslationNetwork.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
            if t.network == .proxy {
                HStack(spacing: 6) {
                    Text("代理端口").font(.system(size: 11))
                    Stepper(value: Binding(
                        get: { t.proxyPort },
                        set: { v in model.mutateTranslationSettings { $0.proxyPort = v } }),
                        in: 1...65535, step: 1) {
                        Text("\(t.proxyPort)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            Text("自动：有道/MyMemory/国内 AI 直连，Google 与 OpenAI 走本机 HTTP 代理；"
                 + "Apple 本地翻译不联网。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Base URL").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                TextField("https://api.deepseek.com/v1", text: Binding(
                    get: { t.aiBaseURL },
                    set: { v in model.mutateTranslationSettings { $0.aiBaseURL = v } }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            HStack(spacing: 8) {
                Text("模型").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                TextField("deepseek-chat", text: Binding(
                    get: { t.aiModel },
                    set: { v in model.mutateTranslationSettings { $0.aiModel = v } }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            HStack(spacing: 8) {
                Text("API Key").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                SecureField("sk-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button(keySaved ? "已保存" : "保存") {
                    KeychainStore.aiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    keySaved = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        keySaved = false
                    }
                }
                .controlSize(.small)
            }
            Text("Key 存在系统钥匙串（不是 settings.json），只在本机可见。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
