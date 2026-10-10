#!/usr/bin/env python3
"""生成 App 图标资源：

1. Resources/AppIcon.icns        ← B2 toolbox 方案（iconutil 打包全套尺寸）
2. Resources/MenuBarIcon.png     ← 取景框+图钉，纯 alpha 黑色形状，
                                   作为 NSImage.isTemplate 的模板图，
                                   系统会按菜单栏深浅色自动染色

图标形状的唯一来源是 gen-logo-v2.py，避免"预览图是一套、实际打包是另一套"。
"""
import os
import subprocess
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importlib.util
spec = importlib.util.spec_from_file_location("genlogov2", os.path.join(HERE, "gen-logo-v2.py"))
g2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g2)

RES = os.path.normpath(os.path.join(HERE, "..", "Resources"))
ICONSET = os.path.join(RES, "AppIcon.iconset")

# iconutil 要求的固定命名；缺一个尺寸就会被拒
SIZES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def build_appicon():
    os.makedirs(ICONSET, exist_ok=True)
    master = g2.b2()                      # 1024 原图
    for name, px in SIZES:
        master.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
    icns = os.path.join(RES, "AppIcon.icns")
    if os.path.exists(icns):
        os.remove(icns)
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", icns], check=True)
    print(f"  AppIcon.icns {os.path.getsize(icns)} bytes")
    return icns


def build_menubar_template():
    """模板图必须是**纯黑 + alpha**：任何颜色都会被系统当成非模板图，
    在深色菜单栏上就会糊成一片。"""
    img = g2.menubar_template(size=88)   # 22pt @4x，缩放到 22/44 都够清晰
    out = os.path.join(RES, "MenuBarIcon.png")
    img.save(out)
    # 自检：非透明像素必须全是黑色
    small = img.resize((22, 22), Image.LANCZOS).convert("RGBA")
    bad = 0
    for y in range(22):
        for x in range(22):
            r, g, b, a = small.getpixel((x, y))
            if a > 8 and (r, g, b) != (0, 0, 0):
                bad += 1
    print(f"  MenuBarIcon.png {img.size[0]}x{img.size[1]}，非黑像素 {bad} 个"
          + ("（模板图会被判为彩色图！）" if bad else " ✓ 纯 alpha 形状"))
    return out


def main():
    icns = build_appicon()
    mb = build_menubar_template()
    # 预览图：把 icns 的 128 与菜单栏模板摆在一起，便于肉眼确认
    prev = Image.new("RGBA", (300, 140), (246, 247, 250, 255))
    app_preview = g2.b2().resize((112, 112), Image.LANCZOS)
    prev.alpha_composite(app_preview, (14, 14))
    dark = Image.new("RGBA", (160, 112), (30, 32, 38, 255))
    t = Image.open(mb).resize((22, 22), Image.LANCZOS)
    white = Image.new("RGBA", t.size, (0, 0, 0, 0))
    white.paste((255, 255, 255, 255), (0, 0), t)
    dark.alpha_composite(white, (20, 45))
    dark.alpha_composite(white, (60, 45))
    light = Image.new("RGBA", (160, 112), (238, 240, 244, 255))
    black = Image.new("RGBA", t.size, (0, 0, 0, 0))
    black.paste((30, 30, 36, 255), (0, 0), t)
    light.alpha_composite(black, (20, 45))
    light.alpha_composite(black, (60, 45))
    prev.alpha_composite(dark, (130, 14))
    prev.alpha_composite(light, (130, 14 + 56))
    prev.convert("RGB").save(os.path.join(RES, "..", "Design", "logo", "applied-preview.png"))
    print("  预览：Design/logo/applied-preview.png")


if __name__ == "__main__":
    main()
