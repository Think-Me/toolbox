#!/usr/bin/env python3
"""生成 Toolbox 的 logo 候选图。

设计约束：
- macOS 图标规范：圆角矩形（squircle 近似），半径约 22.5% 边长，无外阴影
- 必须在 32px 下仍可辨认（菜单栏/程序坞缩小后），所以内部元素不能多于 3 个层级
- 三个功能模块（剪贴板 / hosts / 截图贴图）用颜色而非细节图形暗示

输出 Design/logo/candidates/*.png（1024）与 contact-sheet.png（多尺寸预览）。
"""
from PIL import Image, ImageDraw, ImageFilter
import math
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "Design", "logo", "candidates")
OUT = os.path.normpath(OUT)
os.makedirs(OUT, exist_ok=True)

S = 1024
RADIUS = int(S * 0.225)          # Apple 图标圆角比例

# 三个模块的识别色
BLUE = (56, 132, 255)
GREEN = (52, 199, 123)
ORANGE = (255, 149, 50)
INK = (28, 30, 38)


def squircle(size=S, radius=RADIUS):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def gradient(top, bottom, size=S):
    base = Image.new("RGB", (size, size))
    px = base.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(0, size):
            px[x, y] = c
    return base


def gradient_fast(top, bottom, size=S):
    """1×N 渐变再 resize 成 N×N：纯 PIL，不依赖 numpy。"""
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(round(top[k] * (1 - t) + bottom[k] * t) for k in range(3))
    return strip.resize((size, size), Image.BILINEAR)


def finish(img, mask):
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def sheen(draw, size=S):
    """顶部一道柔和的高光，让平面图标有点立体感"""
    for i in range(int(size * 0.34)):
        a = int(26 * (1 - i / (size * 0.34)))
        draw.line([(0, i), (size, i)], fill=(255, 255, 255, a))


# ---------------------------------------------------------------- A 层叠方块
def cand_a():
    img = gradient_fast((246, 248, 252), (222, 229, 240)).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    sheen(d)
    s = 300
    # 三块依次偏移，颜色对应三个模块；从后往前画
    for (x, y, col) in [(300, 250, ORANGE), (360, 340, GREEN), (420, 430, BLUE)]:
        d.rounded_rectangle([x, y, x + s, y + s], radius=54, fill=col)
        d.rounded_rectangle([x, y, x + s, y + s], radius=54, outline=(255, 255, 255, 90), width=6)
    return finish(img, squircle())


# ---------------------------------------------------------------- B 工具箱
def cand_b():
    img = gradient_fast((70, 92, 140), (34, 44, 74)).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    sheen(d)
    # 提手
    d.rounded_rectangle([410, 210, 614, 330], radius=44, outline=(255, 255, 255, 230), width=26)
    # 箱体
    d.rounded_rectangle([212, 330, 812, 800], radius=64, fill=(255, 255, 255, 240))
    # 箱体分隔条
    d.rectangle([212, 500, 812, 548], fill=(70, 92, 140, 255))
    # 三个模块色点
    for i, col in enumerate([BLUE, GREEN, ORANGE]):
        cx = 330 + i * 182
        d.ellipse([cx - 34, 630, cx + 34, 698], fill=col)
    return finish(img, squircle())


# ---------------------------------------------------------------- C 单字标
def cand_c():
    img = gradient_fast((255, 158, 66), (238, 84, 74)).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    sheen(d)
    # 用两条粗笔画出一个 T，横笔右端接一个图钉圆点（呼应"贴图"）
    d.rounded_rectangle([250, 268, 774, 372], radius=52, fill=(255, 255, 255, 246))
    d.rounded_rectangle([438, 268, 542, 780], radius=52, fill=(255, 255, 255, 246))
    d.ellipse([404, 700, 576, 872], fill=(255, 255, 255, 235))
    d.ellipse([462, 758, 518, 814], fill=(238, 84, 74, 255))
    return finish(img, squircle())


# ---------------------------------------------------------------- D 取景框+图钉
def cand_d():
    img = gradient_fast((38, 44, 58), (18, 20, 28)).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    sheen(d)
    # 四角取景框：每个角由一横一竖两根条拼成 L 形
    arm, thick, pad = 190, 46, 200
    white = (255, 255, 255, 238)
    for cx, cy, sx, sy in [(pad, pad, 1, 1), (S - pad, pad, -1, 1),
                           (pad, S - pad, 1, -1), (S - pad, S - pad, -1, -1)]:
        x0, x1 = sorted((cx, cx + sx * arm))
        y0, y1 = sorted((cy, cy + sy * thick))
        d.rounded_rectangle([x0, y0, x1, y1], radius=thick / 2, fill=white)
        x0, x1 = sorted((cx, cx + sx * thick))
        y0, y1 = sorted((cy, cy + sy * arm))
        d.rounded_rectangle([x0, y0, x1, y1], radius=thick / 2, fill=white)
    # 中心图钉：圆头 + 针
    d.ellipse([404, 356, 620, 572], fill=ORANGE)
    d.polygon([(486, 556), (538, 556), (512, 700)], fill=ORANGE)
    d.ellipse([470, 420, 554, 504], fill=(255, 255, 255, 210))
    return finish(img, squircle())


# ---------------------------------------------------------------- E 三格
def cand_e():
    img = gradient_fast((250, 251, 253), (228, 233, 242)).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    sheen(d)
    tiles = [(216, 216, BLUE), (216, 552, GREEN), (552, 216, ORANGE), (552, 552, INK)]
    for x, y, col in tiles:
        d.rounded_rectangle([x, y, x + 256, y + 256], radius=48, fill=col)
    # 每格里一个极简符号：横线(文本) / 节点(hosts) / 取景框(截图) / 图钉
    x0, y0, _ = tiles[0]
    for i in range(3):
        d.line([(x0 + 56, y0 + 78 + i * 52), (x0 + 200, y0 + 78 + i * 52)],
               fill=(255, 255, 255, 240), width=18)
    x0, y0, _ = tiles[1]
    d.ellipse([x0 + 60, y0 + 60, x0 + 108, y0 + 108], fill=(255, 255, 255, 240))
    d.ellipse([x0 + 150, y0 + 150, x0 + 198, y0 + 198], fill=(255, 255, 255, 240))
    d.line([(x0 + 100, y0 + 100), (x0 + 160, y0 + 160)], fill=(255, 255, 255, 240), width=16)
    x0, y0, _ = tiles[2]
    d.rectangle([x0 + 64, y0 + 64, x0 + 192, y0 + 192], outline=(255, 255, 255, 240), width=18)
    d.line([(x0 + 64, y0 + 128), (x0 + 192, y0 + 128)], fill=(255, 255, 255, 120), width=10)
    x0, y0, _ = tiles[3]
    d.ellipse([x0 + 84, y0 + 60, x0 + 172, y0 + 148], fill=(255, 255, 255, 240))
    d.polygon([(x0 + 116, y0 + 140), (x0 + 140, y0 + 140), (x0 + 128, y0 + 208)],
              fill=(255, 255, 255, 240))
    return finish(img, squircle())


def contact_sheet(cands, path):
    """1024 缩略 + 128/64/32/16 实际尺寸，用来判断小尺寸是否还认得出"""
    sizes = [128, 64, 32, 16]
    pad = 28
    cell = 220
    w = pad + len(cands) * (cell + pad)
    h = pad + cell + 20 + sum(sizes) + 20 * len(sizes)
    sheet = Image.new("RGBA", (w, h), (245, 246, 249, 255))
    d = ImageDraw.Draw(sheet)
    for i, (name, im) in enumerate(cands):
        x = pad + i * (cell + pad)
        big = im.resize((cell, cell), Image.LANCZOS)
        sheet.alpha_composite(big, (x, pad))
        d.text((x + 6, pad + cell + 4), name, fill=(60, 62, 70, 255))
        y = pad + cell + 26
        for s in sizes:
            small = im.resize((s, s), Image.LANCZOS)
            sheet.alpha_composite(small, (x + (cell - s) // 2, y))
            y += s + 12
    sheet.convert("RGB").save(path)


def main():
    cands = [
        ("A 层叠方块", cand_a()),
        ("B 工具箱", cand_b()),
        ("C 单字标T", cand_c()),
        ("D 取景框图钉", cand_d()),
        ("E 三格拼贴", cand_e()),
    ]
    for name, im in cands:
        slug = name.split(" ")[0].lower()
        im.save(os.path.join(OUT, f"logo-{slug}.png"))
        print(f"  写出 logo-{slug}.png  ({name})")
    contact_sheet(cands, os.path.join(OUT, "..", "contact-sheet.png"))
    print("  写出 contact-sheet.png（含 128/64/32/16 实际尺寸预览）")


if __name__ == "__main__":
    main()
