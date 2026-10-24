#!/usr/bin/env python3
"""生成 Windows 端图标资源：windows/src/Toolbox.App/Assets/Toolbox.ico

图形的唯一来源仍是 gen-logo-v2.py —— 和 macOS 的 AppIcon.icns 同一个母版，
避免"两个平台两套 logo"（gen-icon-assets.py 开头就强调了这一点）。

ICO 里塞多尺寸：托盘要 16/20/24/32（对应 100%/125%/150%/200% 缩放），
任务栏和资源管理器要 32/48/256。

用法：python Scripts/gen-icon-assets-win.py
依赖：pillow（仅开发期，不进产物）。
"""
import importlib.util
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

spec = importlib.util.spec_from_file_location("genlogov2", os.path.join(HERE, "gen-logo-v2.py"))
g2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g2)

OUT = os.path.normpath(os.path.join(
    HERE, "..", "windows", "src", "Toolbox.App", "Assets", "Toolbox.ico"))

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


def main():
    master = g2.b2()                       # 1024 原图，RGBA
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # Pillow 会按 sizes 逐档重采样，交出来的就是多尺寸 ICO
    master.save(OUT, format="ICO", sizes=[(s, s) for s in SIZES])

    # 自检：读回来确认每档都在，且尺寸真的是正方形
    with Image.open(OUT) as ico:
        got = sorted(ico.info.get("sizes", set()))
    missing = [s for s in SIZES if (s, s) not in got]
    if missing:
        raise SystemExit(f"ICO 缺少尺寸：{missing}")
    print(f"  {os.path.relpath(OUT, os.path.dirname(HERE))} "
          f"{os.path.getsize(OUT)} bytes，{len(got)} 档尺寸")


if __name__ == "__main__":
    main()
