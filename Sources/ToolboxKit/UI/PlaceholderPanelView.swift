import AppKit

/// M0/M2 期间的占位浮层内容：一圈边框 + 一行说明文字。
/// M1 会被剪贴板列表替换。
@MainActor
public final class PlaceholderPanelView: NSView {
    public init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.96).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.55, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }
}
