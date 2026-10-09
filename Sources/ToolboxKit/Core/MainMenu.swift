import AppKit

/// 给菜单栏 App 装一份最小主菜单。
///
/// 为什么必须装：LSUIElement / accessory App 平时没有菜单条，但 AppKit 的
/// **key equivalent 匹配是走主菜单的**。没有 Edit 菜单，⌘C / ⌘V / ⌘X / ⌘Z / ⌘A
/// 就不会被派发到文本视图，表现就是"编辑器能打字、但粘贴没用"。
/// 这不是 STTextView 的问题，换成 NSTextView 一样如此。
public enum MainMenu {

    @MainActor
    public static func install(appName: String = "Toolbox") {
        let main = NSMenu()

        // 应用菜单：至少要有 Quit，否则 ⌘Q 无效
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 \(appName)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        // 编辑菜单：文本视图的 ⌘X/C/V/A/Z 全靠这一组
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(item("撤销", #selector(UndoManager.undo), "z"))
        let redo = item("重做", #selector(UndoManager.redo), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("剪切", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("拷贝", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("粘贴", #selector(NSText.paste(_:)), "v"))
        let pasteMatch = item("粘贴和匹配风格", #selector(NSTextView.pasteAsPlainText(_:)), "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(pasteMatch)
        edit.addItem(.separator())
        edit.addItem(item("全选", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(item("删除", #selector(NSText.delete(_:)), ""))
        editItem.submenu = edit

        // 窗口菜单：让 ⌘W 关闭设置窗生效
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private static func item(_ title: String, _ action: Selector,
                             _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = [.command]
        return i
    }
}
