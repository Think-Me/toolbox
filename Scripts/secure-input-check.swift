// 退出码 0 = Secure Input 关闭（可以合成按键）；10 = 已开启（合成按键会被 HID 层丢弃）
import Carbon.HIToolbox
import Foundation
if IsSecureEventInputEnabled() {
    FileHandle.standardError.write(
        "⚠️ Secure Input 已开启（常见于远程桌面/密码框），系统会丢弃所有合成键盘事件。\n".data(using: .utf8)!)
    exit(10)
}
exit(0)
