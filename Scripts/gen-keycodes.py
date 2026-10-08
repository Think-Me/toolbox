#!/usr/bin/env python3
"""从 macOS SDK 的 HIToolbox/Events.h 生成 Sources/ToolboxKit/Core/KeyCodeNames.swift。

为什么要生成而不是手抄：手抄表会漏键，录制器一漏就显示成 "? (40)" 这种没法看的东西
（实测踩到：keyCode 40 = K 不在表里）。SDK 升级后重跑本脚本即可。
"""
import re
import subprocess
import sys

HEADER = (subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip() +
          "/System/Library/Frameworks/Carbon.framework"
          "/Frameworks/HIToolbox.framework/Headers/Events.h")

# 键码名后缀 → 显示标签。没列出来的用去前缀后的原名。
NICE = {
    "Space": "Space", "Delete": "\u232b", "Return": "\u23ce", "Escape": "\u238b",
    "Tab": "\u21e5", "ForwardDelete": "\u2326", "Help": "Help",
    "Home": "\u2196", "End": "\u2198", "PageUp": "\u21de", "PageDown": "\u21df",
    "LeftArrow": "\u2190", "RightArrow": "\u2192", "UpArrow": "\u2191",
    "DownArrow": "\u2193",
    "Equal": "=", "Minus": "-", "RightBracket": "]", "LeftBracket": "[",
    "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/",
    "Backslash": "\\", "Grave": "`", "NonUSBackslash": "\\\\|",
    "CapsLock": "\u21ea",
    # 小键盘统一加"数"前缀，避免和主键盘的字母/数字混在一起看不出区别
}

STRIP_PREFIXES = ("ANSI_", "ISO_", "XE_")


def label(name: str) -> str:
    body = name[len("kVK_"):]
    m = re.fullmatch(r"ANSI_([A-Z0-9])", body)
    if m:
        return m.group(1)
    m = re.fullmatch(r"F(\d+)", body)
    if m:
        return "F" + m.group(1)
    if body.startswith("Keypad"):
        rest = body[len("Keypad"):]
        return "数" + NICE.get(rest, rest)
    for pre in STRIP_PREFIXES:
        if body.startswith(pre):
            body = body[len(pre):]
            break
    return NICE.get(body, body)


def swift_string(s: str) -> str:
    """转义成 Swift 字符串字面量。反斜杠必须先处理。"""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    try:
        src = open(HEADER, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print(f"读不到 SDK 头文件: {e}", file=sys.stderr)
        return 1
    pairs = re.findall(r"\b(kVK_[A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*,", src)
    if not pairs:
        print("一个 kVK_ 常量都没匹配到，正则可能不适配这个 SDK", file=sys.stderr)
        return 1

    # 同一键码可能有多个名字（如 ANSI_ 与 ISO_ 重叠），保留首个定义并记下别名
    table: dict[int, tuple[str, str]] = {}
    for name, val in pairs:
        code = int(val, 0)
        if code not in table:
            table[code] = (label(name), name)

    lines = []
    for code in sorted(table):
        lab, name = table[code]
        lines.append(f"        {code}: {swift_string(lab)},   // {name}")
    body = "\n".join(lines)

    out = f'''import Foundation

/// 虚拟键码 → 显示标签。
///
/// **由 Scripts/gen-keycodes.py 从 SDK 的 HIToolbox/Events.h 生成，不要手改。**
/// 手抄会漏键：实测漏掉 keyCode 40(K) 导致录制器显示成无法阅读的样子。
/// SDK 升级后重跑 `python3 Scripts/gen-keycodes.py` 即可。
public enum KeyCodeNames {{
    static let table: [UInt16: String] = [
{body}
    ]
}}
'''
    dest = "Sources/ToolboxKit/Core/KeyCodeNames.swift"
    with open(dest, "w", encoding="utf-8") as f:
        f.write(out)
    print(f"已生成 {dest}：{len(table)} 个键码")
    return 0


if __name__ == "__main__":
    sys.exit(main())
