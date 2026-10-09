#!/usr/bin/env python3
"""Toolbox logo 候选 v2。

v1 的教训（看 contact-sheet 的 32/16px 预览得出）：
- 浅色底（A、E）在浅色桌面上会消失，且多元素缩小后糊成一团
- 能活到 16px 的只有：轮廓明确的单一主体（箱子、T、取景框+点）
所以 v2 一律：深色或有对比的底 + 单一主形 + 最多 3 个色块。

同时生成菜单栏模板图（模板图必须是纯 alpha 形状，系统自己按深浅色染色）。
"""
from PIL import Image, ImageDraw
import os

OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "Design", "logo", "candidates"))
os.makedirs(OUT, exist_ok=True)

S = 1024
R = int(S * 0.225)
BLUE, GREEN, ORANGE, INK = (56, 132, 255), (52, 199, 123), (255, 149, 50), (26, 28, 36)


def squircle_mask(size=S, radius=R):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def grad(top, bottom, size=S):
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    return strip.resize((size, size), Image.BILINEAR)


def new(top, bottom):
    img = grad(top, bottom).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    for i in range(int(S * 0.32)):          # 顶部柔光
        d.line([(0, i), (S, i)], fill=(255, 255, 255, int(22 * (1 - i / (S * 0.32)))))
    return img, d


def out(img):
    o = Image.new("RGBA", img.size, (0, 0, 0, 0))
    o.paste(img, (0, 0), squircle_mask())
    return o


# ---------------------------------------------------------- A2 层叠（深底两格）
def a2():
    img, d = new((58, 74, 116), (26, 32, 54))
    # 只留两层，偏移加大，16px 下也能看出"叠了两张"
    d.rounded_rectangle([300, 268, 660, 628], radius=62, fill=(255, 255, 255, 120))
    d.rounded_rectangle([364, 332, 724, 692], radius=62, fill=BLUE)
    d.rounded_rectangle([364, 332, 724, 692], radius=62, outline=(255, 255, 255, 120), width=8)
    # 前面那张上画两行"文本"，点明剪贴板
    for i in range(2):
        y = 430 + i * 96
        d.rounded_rectangle([432, y, 660 - i * 70, y + 44], radius=22, fill=(255, 255, 255, 235))
    return out(img)


# ---------------------------------------------------------- B2 工具箱
def b2():
    img, d = new((76, 98, 148), (32, 42, 70))
    d.rounded_rectangle([404, 206, 620, 330], radius=48, outline=(255, 255, 255, 235), width=30)
    d.rounded_rectangle([206, 330, 818, 806], radius=70, fill=(255, 255, 255, 245))
    d.rectangle([206, 496, 818, 548], fill=(76, 98, 148, 255))
    for i, col in enumerate([BLUE, GREEN, ORANGE]):
        cx = 330 + i * 182
        d.ellipse([cx - 36, 630, cx + 36, 702], fill=col)
    return out(img)


# ---------------------------------------------------------- C2 单字 T + 图钉
def c2():
    img, d = new((255, 162, 70), (232, 74, 66))
    white = (255, 255, 255, 248)
    d.rounded_rectangle([244, 262, 780, 378], radius=58, fill=white)   # 横
    d.rounded_rectangle([440, 262, 546, 700], radius=54, fill=white)   # 竖
    # 竖笔末端收成图钉：实心圆 + 针尖，去掉 v1 那个空心环（16px 下会糊）
    d.ellipse([402, 620, 584, 802], fill=white)
    d.polygon([(468, 782), (518, 782), (493, 878)], fill=white)
    return out(img)


# ---------------------------------------------------------- D2 取景框 + 图钉
def d2():
    img, d = new((44, 52, 68), (14, 16, 24))
    arm, thick, pad = 196, 48, 196
    white = (255, 255, 255, 240)
    for cx, cy, sx, sy in [(pad, pad, 1, 1), (S - pad, pad, -1, 1),
                           (pad, S - pad, 1, -1), (S - pad, S - pad, -1, -1)]:
        x0, x1 = sorted((cx, cx + sx * arm)); y0, y1 = sorted((cy, cy + sy * thick))
        d.rounded_rectangle([x0, y0, x1, y1], radius=thick / 2, fill=white)
        x0, x1 = sorted((cx, cx + sx * thick)); y0, y1 = sorted((cy, cy + sy * arm))
        d.rounded_rectangle([x0, y0, x1, y1], radius=thick / 2, fill=white)
    d.ellipse([398, 340, 626, 568], fill=ORANGE)
    d.polygon([(482, 552), (542, 552), (512, 716)], fill=ORANGE)
    d.ellipse([468, 410, 556, 498], fill=(255, 255, 255, 250))
    return out(img)


# ---------------------------------------------------------- 菜单栏模板图
def menubar_template(size=36):
    """纯 alpha 形状：系统按深浅色自动染色，所以不能有任何颜色/背景。"""
    img = Image.new("RGBA", (size * 4, size * 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = img.size[0]
    arm, thick, pad = s * 0.20, s * 0.085, s * 0.17
    blk = (0, 0, 0, 255)
    for cx, cy, sx, sy in [(pad, pad, 1, 1), (s - pad, pad, -1, 1),
                           (pad, s - pad, 1, -1), (s - pad, s - pad, -1, -1)]:
        x0, x1 = sorted((cx, cx + sx * arm)); y0, y1 = sorted((cy, cy + sy * thick))
        d.rounded_rectangle([x0, y0, x1, y1], radius=thick / 2, fill=blk)
        x0, x1 = sorted((cx, cx + sx * thick)); y0, y1 = sorted((cy, cy + sy * arm))
        d.rounded_rectangle([x0, y0, x1, y1], radius=thick / 2, fill=blk)
    cx, cy, r = s / 2, s * 0.46, s * 0.115
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=blk)
    d.polygon([(cx - r * 0.42, cy + r * 0.7), (cx + r * 0.42, cy + r * 0.7),
               (cx, cy + r * 2.3)], fill=blk)
    return img.resize((size, size), Image.LANCZOS)


def sheet(cands, path):
    from PIL import ImageDraw as ID
    pad, cell = 30, 200
    w = pad + len(cands) * (cell + pad)
    h = pad + cell + 34 + 128 + 40
    s = Image.new("RGBA", (w, h), (246, 247, 250, 255))
    d = ID.Draw(s)
    for i, (name, im) in enumerate(cands):
        x = pad + i * (cell + pad)
        s.alpha_composite(im.resize((cell, cell), Image.LANCZOS), (x, pad))
        d.text((x + 6, pad + cell + 6), name, fill=(55, 58, 66, 255))
        s.alpha_composite(im.resize((64, 64), Image.LANCZOS), (x + 20, pad + cell + 34))
        s.alpha_composite(im.resize((32, 32), Image.LANCZOS), (x + 100, pad + cell + 66))
        s.alpha_composite(im.resize((16, 16), Image.LANCZOS), (x + 150, pad + cell + 82))
    s.convert("RGB").save(path)


def main():
    # 标签用 ASCII：PIL 默认位字体不支持中文，会渲染成方块（只是预览图的问题）
    cands = [("A2 stack", a2()), ("B2 toolbox", b2()),
             ("C2 letter-T", c2()), ("D2 viewfinder", d2())]
    for name, im in cands:
        slug = name.split(" ")[0].lower()
        im.save(os.path.join(OUT, f"logo-{slug}.png"))
    sheet(cands, os.path.join(OUT, "..", "candidates-v2.png"))
    mb = menubar_template()
    mb.save(os.path.join(OUT, "..", "menubar-template-source.png"))
    # 在模拟菜单栏上看看实际效果（深色 + 浅色两条）
    from PIL import ImageDraw as ID
    demo = Image.new("RGBA", (900, 150), (0, 0, 0, 0))
    d = ID.Draw(demo)
    d.rectangle([0, 0, 900, 66], fill=(30, 32, 38, 255))
    d.rectangle([0, 84, 900, 150], fill=(238, 240, 244, 255))
    for i, x in enumerate([40, 120, 200, 280]):
        t = mb.resize((22, 22), Image.LANCZOS)
        dark = Image.new("RGBA", t.size, (0, 0, 0, 0))
        dark.paste((255, 255, 255, 255), (0, 0), t)
        light = Image.new("RGBA", t.size, (0, 0, 0, 0))
        light.paste((30, 30, 36, 255), (0, 0), t)
        demo.alpha_composite(dark, (x, 22))
        demo.alpha_composite(light, (x, 106))
    d.text((360, 26), "<- menu bar template 22px (dark bar)", fill=(220, 222, 228, 255))
    d.text((360, 108), "<- same glyph on light bar", fill=(70, 72, 80, 255))
    demo.convert("RGB").save(os.path.join(OUT, "..", "menubar-preview.png"))
    print("v2 done: candidates-v2.png / menubar-preview.png")


if __name__ == "__main__":
    main()
