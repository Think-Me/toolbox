import AppKit
import SwiftUI

#if canImport(Translation)
// @preconcurrency：SDK 把 TranslationSession 标成 MainActor 隔离、translate 却非隔离，
// Swift 6 会报 "sending 'session' risks data races" —— 框架注解缺陷，不是调用方式问题。
@preconcurrency import Translation
#if canImport(_Translation_SwiftUI)
import _Translation_SwiftUI
#endif
#endif

/// 划词翻译浮窗。
///
/// 浮窗不抢焦点（`FloatingPanel` + `PanelPresenter` 不调 `NSApp.activate`），
/// 所以"替换原文"才能把译文写回用户刚才选中的那段文字。
public struct TranslationPanelView: View {
    @ObservedObject private var model: TranslationModel
    private let canReplace: Bool
    private let onReplace: () -> Void
    @State private var pinned = false

    public init(model: TranslationModel, canReplace: Bool, onReplace: @escaping () -> Void) {
        self.model = model
        self.canReplace = canReplace
        self.onReplace = onReplace
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourceSection
                    Divider()
                    outputSection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .modifier(AppleTaskAttacher(model: model))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.book.closed")
            Text("翻译").font(.headline)
            engineMenu
            Spacer(minLength: 4)
            Text(TranslationLanguages.label(for: model.targetLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.retranslate()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新翻译")
            Button {
                pinned.toggle()
                PanelPresenter.shared.setPinned(pinned)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(pinned ? "取消钉住" : "钉住（点击外部不关闭）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 浮窗内直接换引擎：只影响本次并回写设置，下次呼出沿用。
    private var engineMenu: some View {
        Menu {
            ForEach(TranslationEngine.allCases, id: \.self) { engine in
                Button {
                    model.setEngine(engine)
                } label: {
                    if model.engine == engine {
                        Label(engine.label, systemImage: "checkmark")
                    } else {
                        Text(engine.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(model.engineLabel.isEmpty ? model.engine.shortLabel : model.engineLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("翻译引擎")
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("原文")
            Text(model.sourceText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionTitle("译文")
                if !model.detectedLabel.isEmpty {
                    Text("检测到 \(model.detectedLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("翻译中…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let output = model.output {
                Text(output)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("…")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(model.copied ? "已复制" : "复制译文") { model.copyResult() }
                .disabled(model.output == nil)
            Button("朗读") { model.speak() }
                .disabled(model.output == nil)
            Spacer()
            Button("替换原文") { onReplace() }
                .disabled(!canReplace || model.output == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

/// macOS 15 才有 `.translationTask`；14 上这层直接透传。
private struct AppleTaskAttacher: ViewModifier {
    @ObservedObject var model: TranslationModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.overlay(AppleTaskHost(model: model), alignment: .topLeading)
        } else {
            content
        }
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct AppleTaskHost: View {
    @ObservedObject var model: TranslationModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // `.id` 换新 = 重新挂载 modifier：同一语言对连点"重译"也会再次触发
            .id(model.appleRequestID)
            .translationTask(model.appleConfiguration as? TranslationSession.Configuration) { @MainActor session in
                let serial = await MainActor.run { model.appleRequestID }
                guard let text = await MainActor.run(body: { model.applePendingText }) else { return }
                do {
                    let response = try await session.translate(text)
                    let source = response.sourceLanguage.languageCode?.identifier
                    await MainActor.run {
                        model.applyApple(response.targetText, sourceLanguage: source, serial: serial)
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run { model.failApple(message, serial: serial) }
                }
            }
    }
}
#endif
