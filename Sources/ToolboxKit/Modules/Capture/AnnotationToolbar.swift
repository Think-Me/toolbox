import AppKit

/// 标注工具条：5 工具 │ 6 颜色 │ 3 线宽 │ 撤销 重做 清空。
///
/// 和操作条（复制/钉图/存盘…）排在**同一行**（用户明确要求），
/// 行内两块面板由 `CaptureToolbarLayout` 定位。
///
/// 沿用 M1 的教训：图标化必须配 tooltip 把可读性补回来。
/// 按钮一律显式 target/action —— M2 踩过 `target: nil` 时
/// action 沿响应链上找、兄弟视图收不到，点了没反应。
@MainActor
public final class AnnotationToolbarView: NSView {
    public enum Command: Equatable {
        case tool(AnnotationTool)
        case color(AnnotationColor)
        case lineWidth(CGFloat)
        case undo
        case redo
        case clear
    }
    public var onCommand: ((Command) -> Void)?

    private static let h: CGFloat = 32
    private static let edge: CGFloat = 6
    private static let buttonH: CGFloat = 24
    private static let toolPitch: CGFloat = 26
    private static let dotPitch: CGFloat = 24
    private static let dotSize: CGFloat = 18
    private static let sepWidth: CGFloat = 9

    private let toolSymbols: [AnnotationTool: (String, String)] = [
        .rect: ("rectangle", "矩形"),
        .arrow: ("arrow.up.right", "箭头"),
        .pen: ("pencil", "画笔"),
        .mosaic: ("mosaic", "马赛克"),
        .text: ("textformat", "文字"),
    ]

    private var toolButtons: [(AnnotationTool, NSButton)] = []
    private var colorButtons: [(AnnotationColor, NSButton)] = []
    private var widthButtons: [(CGFloat, NSButton)] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var clearButton: NSButton!
    private var actions: [ObjectIdentifier: Command] = [:]

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.96).cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = NSColor(calibratedWhite: 0.42, alpha: 1).cgColor
        layer?.borderWidth = 1

        var x = Self.edge
        x = placeTools(from: x)
        x = placeSeparator(from: x)
        x = placeColors(from: x)
        x = placeSeparator(from: x)
        x = placeWidths(from: x)
        x = placeSeparator(from: x)
        x = placeHistory(from: x)
        x += Self.edge

        intrinsicWidth = x
        frame.size = CGSize(width: x, height: Self.h)
    }

    /// 同 ActionStripView：固有宽度不能从 frame.size 反推，见那边的注释。
    /// 用 var 是 Swift 的定值初始化规则：init 里调了实例方法之后再给 let 赋值会报错
    private var intrinsicWidth: CGFloat = 0

    required init?(coder: NSCoder) { fatalError("不支持从 nib 构造") }

    public var idealSize: CGSize { CGSize(width: intrinsicWidth, height: Self.h) }

    // MARK: 排布

    private func placeTools(from startX: CGFloat) -> CGFloat {
        var x = startX
        for tool in AnnotationTool.allCases {
            let (symbol, label) = toolSymbols[tool] ?? ("questionmark", tool.rawValue)
            let b = makeButton(symbol: symbol, label: label,
                               hint: "\(label)（再点一次回到选区拖拽）", pitch: Self.toolPitch)
            b.frame = CGRect(x: x + (Self.toolPitch - Self.buttonH) / 2,
                             y: (Self.h - Self.buttonH) / 2, width: Self.buttonH, height: Self.buttonH)
            actions[ObjectIdentifier(b)] = .tool(tool)
            addSubview(b)
            toolButtons.append((tool, b))
            x += Self.toolPitch
        }
        return x
    }

    private func placeColors(from startX: CGFloat) -> CGFloat {
        var x = startX
        for color in AnnotationPalette.colors {
            let b = NSButton(frame: CGRect(x: x + (Self.dotPitch - Self.dotSize) / 2,
                                           y: (Self.h - Self.dotSize) / 2,
                                           width: Self.dotSize, height: Self.dotSize))
            b.isBordered = false
            b.title = ""
            b.setButtonType(.momentaryChange)
            b.target = self
            b.action = #selector(tapped(_:))
            b.toolTip = "颜色 \(color.hexString)"
            b.wantsLayer = true
            b.layer?.cornerRadius = Self.dotSize / 2
            b.layer?.backgroundColor = color.nsColor.cgColor
            b.layer?.borderColor = NSColor(calibratedWhite: 0.1, alpha: 0.9).cgColor
            b.layer?.borderWidth = 1
            actions[ObjectIdentifier(b)] = .color(color)
            colorButtons.append((color, b))
            addSubview(b)
            x += Self.dotPitch
        }
        return x
    }

    private func placeWidths(from startX: CGFloat) -> CGFloat {
        var x = startX
        for w in AnnotationPalette.lineWidths {
            let b = NSButton(frame: CGRect(x: x + (Self.toolPitch - Self.buttonH) / 2,
                                           y: (Self.h - Self.buttonH) / 2,
                                           width: Self.buttonH, height: Self.buttonH))
            b.isBordered = false
            b.title = ""
            b.imagePosition = .imageOnly
            b.setButtonType(.momentaryChange)
            b.target = self
            b.action = #selector(tapped(_:))
            b.toolTip = "线宽 \(Int(w))"
            b.image = Self.lineImage(thickness: w)
            b.contentTintColor = NSColor(calibratedWhite: 0.9, alpha: 1)
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            actions[ObjectIdentifier(b)] = .lineWidth(w)
            widthButtons.append((w, b))
            addSubview(b)
            x += Self.toolPitch
        }
        return x
    }

    private func placeHistory(from startX: CGFloat) -> CGFloat {
        var x = startX
        undoButton = makeButton(symbol: "arrow.uturn.backward", label: "撤销",
                                hint: "撤销 (⌘Z)", pitch: Self.toolPitch)
        undoButton.frame = CGRect(x: x + (Self.toolPitch - Self.buttonH) / 2,
                                  y: (Self.h - Self.buttonH) / 2,
                                  width: Self.buttonH, height: Self.buttonH)
        actions[ObjectIdentifier(undoButton)] = .undo
        addSubview(undoButton)
        x += Self.toolPitch
        redoButton = makeButton(symbol: "arrow.uturn.forward", label: "重做",
                                hint: "重做 (⇧⌘Z)", pitch: Self.toolPitch)
        redoButton.frame = CGRect(x: x + (Self.toolPitch - Self.buttonH) / 2,
                                  y: (Self.h - Self.buttonH) / 2,
                                  width: Self.buttonH, height: Self.buttonH)
        actions[ObjectIdentifier(redoButton)] = .redo
        addSubview(redoButton)
        x += Self.toolPitch
        clearButton = makeButton(symbol: "trash", label: "清空",
                                 hint: "清空全部标注（可撤销）", pitch: Self.toolPitch)
        clearButton.frame = CGRect(x: x + (Self.toolPitch - Self.buttonH) / 2,
                                   y: (Self.h - Self.buttonH) / 2,
                                   width: Self.buttonH, height: Self.buttonH)
        actions[ObjectIdentifier(clearButton)] = .clear
        addSubview(clearButton)
        return x + Self.toolPitch
    }

    private func placeSeparator(from startX: CGFloat) -> CGFloat {
        let v = NSView(frame: CGRect(x: startX + Self.sepWidth / 2 - 0.5,
                                     y: (Self.h - 16) / 2, width: 1, height: 16))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.42, alpha: 0.8).cgColor
        addSubview(v)
        return startX + Self.sepWidth
    }

    private func makeButton(symbol: String, label: String, hint: String,
                            pitch: CGFloat) -> NSButton {
        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.title = ""
        b.setButtonType(.momentaryChange)
        b.target = self
        b.action = #selector(tapped(_:))
        b.toolTip = hint
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        return b
    }

    /// 线宽按钮的图：自己画的模板图，靠 contentTintColor 上色。
    /// 不用 SF Symbol 的 "line.horizontal.3" 之类：那些符号的粗细和我要的 2/4/8 对不上。
    private static func lineImage(thickness: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let p = NSBezierPath()
            // 钳到图内：8pt 线在 14pt 高的图里刚好，再大就会被裁掉变成"看不见"
            p.lineWidth = Swift.min(thickness, rect.height - 2)
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: 2, y: rect.midY))
            p.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: 状态回显

    public func update(selectedTool: AnnotationTool?, color: AnnotationColor,
                       lineWidth: CGFloat, canUndo: Bool, canRedo: Bool,
                       hasAnnotations: Bool) {
        for (tool, b) in toolButtons {
            let on = tool == selectedTool
            b.layer?.backgroundColor = on
                ? NSColor(calibratedWhite: 0.95, alpha: 0.28).cgColor : NSColor.clear.cgColor
            b.contentTintColor = on ? .white : NSColor(calibratedWhite: 0.8, alpha: 1)
        }
        for (c, b) in colorButtons {
            let on = c == color
            b.layer?.borderColor = (on ? NSColor.white
                    : NSColor(calibratedWhite: 0.1, alpha: 0.9)).cgColor
            b.layer?.borderWidth = on ? 2 : 1
        }
        for (w, b) in widthButtons {
            let on = abs(w - lineWidth) < 0.01
            b.layer?.backgroundColor = on
                ? NSColor(calibratedWhite: 0.95, alpha: 0.28).cgColor : NSColor.clear.cgColor
            b.contentTintColor = on ? .white : NSColor(calibratedWhite: 0.9, alpha: 1)
        }
        // isEnabled=false 对 isBordered=false 的模板图按钮几乎没有视觉差别，
        // 必须自己压暗：否则用户分不清"没有可撤销的了"和"撤销按钮坏了"
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        clearButton.isEnabled = hasAnnotations
        undoButton.contentTintColor = tint(canUndo)
        redoButton.contentTintColor = tint(canRedo)
        clearButton.contentTintColor = tint(hasAnnotations)
    }

    private func tint(_ enabled: Bool) -> NSColor {
        NSColor(calibratedWhite: 0.88, alpha: enabled ? 1 : 0.32)
    }

    // MARK: 事件

    @objc private func tapped(_ sender: NSButton) {
        guard let cmd = actions[ObjectIdentifier(sender)] else { return }
        onCommand?(cmd)
    }
}
