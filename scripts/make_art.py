"""Generate all Cooler Fridge art assets."""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = r"C:\Users\Chen\Zomboid\Workshop\CoolerFridge"
MOD = os.path.join(ROOT, "Contents", "mods", "CoolerFridge", "42")
TEX = os.path.join(MOD, "media", "textures")

OUTLINE = (22, 32, 45, 255)
BAG = (196, 224, 240, 190)
BAG_HI = (238, 250, 255, 225)
ICE_LT = (240, 250, 255, 255)
ICE_MD = (176, 214, 236, 255)
ICE_DK = (120, 168, 204, 255)


def ensure(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def outline_from_alpha(img, colour=OUTLINE, threshold=40):
    """Wrap the opaque part of img in a 1px outline, PZ icon style."""
    alpha = img.split()[3].point(lambda a: 255 if a > threshold else 0)
    grown = alpha.filter(ImageFilter.MaxFilter(3))
    ring = Image.new("L", img.size, 0)
    rd = ring.load()
    gd = grown.load()
    ad = alpha.load()
    for y in range(img.height):
        for x in range(img.width):
            if gd[x, y] and not ad[x, y]:
                rd[x, y] = 255
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(colour, (0, 0), ring)
    out.alpha_composite(img)
    return out


# --------------------------------------------------------------------------
# 32x32 inventory icon: a clear bag of ice cubes with a twist tie.
# --------------------------------------------------------------------------

def ice_bag_icon():
    img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    body = [
        (13, 5), (19, 5), (21, 9), (24, 13), (26, 20), (25, 27),
        (21, 30), (11, 30), (7, 27), (6, 20), (8, 13), (11, 9),
    ]
    d.polygon(body, fill=BAG)

    # Cubes tumbled into the bottom two thirds of the bag.
    cubes = [
        (9, 15), (15, 13), (20, 16), (10, 21), (16, 20), (21, 22),
        (12, 26), (18, 26),
    ]
    for cx, cy in cubes:
        d.rectangle([cx, cy, cx + 4, cy + 4], fill=ICE_MD)
        d.rectangle([cx, cy, cx + 2, cy + 2], fill=ICE_LT)
        d.point((cx + 4, cy + 4), fill=ICE_DK)
        d.point((cx + 3, cy + 4), fill=ICE_DK)
        d.point((cx + 4, cy + 3), fill=ICE_DK)

    # Keep the cubes inside the silhouette.
    mask = Image.new("L", (32, 32), 0)
    ImageDraw.Draw(mask).polygon(body, fill=255)
    img.putalpha(Image.composite(img.split()[3], Image.new("L", (32, 32), 0), mask))

    # Plastic sheen down the left shoulder.
    d = ImageDraw.Draw(img)
    d.line([(10, 13), (9, 19)], fill=BAG_HI)
    d.line([(11, 12), (10, 14)], fill=BAG_HI)

    # Gathered neck, fanning out above the tie.
    d.polygon([(11, 1), (21, 1), (20, 8), (12, 8)], fill=BAG)
    d.line([(13, 2), (14, 7)], fill=BAG_HI)
    d.line([(18, 2), (17, 7)], fill=(168, 200, 220, 200))

    img = outline_from_alpha(img)

    # Twist tie sits on top of the outline so it reads as a separate object.
    d = ImageDraw.Draw(img)
    d.rectangle([11, 5, 20, 8], fill=(150, 38, 38, 255))
    d.rectangle([11, 6, 20, 7], fill=(206, 62, 56, 255))
    d.rectangle([10, 5, 10, 8], fill=OUTLINE)
    d.rectangle([21, 5, 21, 8], fill=OUTLINE)
    d.line([(11, 4), (20, 4)], fill=OUTLINE)
    d.line([(11, 9), (20, 9)], fill=OUTLINE)
    return img


# --------------------------------------------------------------------------
# 256x256 world-model texture, mapped onto the vanilla plastic bag mesh.
# --------------------------------------------------------------------------

def ice_bag_world_texture():
    size = 256
    img = Image.new("RGB", (size, size), (206, 230, 244))
    d = ImageDraw.Draw(img)

    rnd = random.Random(42)
    for _ in range(900):
        x, y = rnd.randrange(size), rnd.randrange(size)
        r = rnd.randint(4, 16)
        shade = rnd.choice([(228, 244, 252), (186, 216, 236), (166, 202, 228)])
        d.rectangle([x, y, x + r, y + r], fill=shade)

    img = img.filter(ImageFilter.GaussianBlur(1.2))
    d = ImageDraw.Draw(img)

    # Faint cube facets so it still reads as ice at a distance.
    for gy in range(0, size, 32):
        for gx in range(0, size, 32):
            jx, jy = rnd.randint(-4, 4), rnd.randint(-4, 4)
            d.rectangle([gx + jx + 4, gy + jy + 4, gx + jx + 26, gy + jy + 26],
                        outline=(240, 250, 255), width=2)

    img = img.filter(ImageFilter.GaussianBlur(0.6))

    # A printed label, the way a real bag of ice has one.
    d = ImageDraw.Draw(img)
    d.rectangle([40, 96, 216, 160], fill=(28, 84, 132))
    d.rectangle([46, 102, 210, 154], outline=(150, 206, 240), width=3)
    font = load_font(34)
    text = "ICE"
    tw = d.textlength(text, font=font)
    d.text(((size - tw) / 2, 112), text, font=font, fill=(232, 246, 255))
    return img


# --------------------------------------------------------------------------
# Shared cooler illustration for the icon, poster and Workshop preview.
# --------------------------------------------------------------------------

def load_font(size, bold=True):
    for name in ("arialbd.ttf" if bold else "arial.ttf", "seguisb.ttf", "segoeui.ttf", "arial.ttf"):
        try:
            return ImageFont.truetype(os.path.join(r"C:\Windows\Fonts", name), size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_snowflake(d, cx, cy, r, colour, width=2):
    for i in range(3):
        a = math.radians(i * 60)
        dx, dy = math.cos(a) * r, math.sin(a) * r
        d.line([(cx - dx, cy - dy), (cx + dx, cy + dy)], fill=colour, width=width)
        for s in (-1, 1):
            bx, by = cx + dx * 0.55 * s, cy + dy * 0.55 * s
            for j in (-1, 1):
                a2 = a + math.radians(50 * j)
                d.line([(bx, by), (bx + math.cos(a2) * r * 0.32,
                                   by + math.sin(a2) * r * 0.32)], fill=colour, width=max(1, width - 1))


def draw_cooler(size):
    """An open cooler packed with ice, drawn on a transparent canvas."""
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def px(v):
        return v * s / 100.0

    outline = (16, 26, 38, 255)
    body_lt = (58, 122, 176, 255)
    body_dk = (34, 82, 126, 255)
    lid_lt = (234, 242, 248, 255)
    lid_dk = (170, 188, 204, 255)
    lw = max(2, int(px(1.1)))

    # Cold glow behind everything.
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([px(6), px(18), px(94), px(94)], fill=(90, 170, 220, 70))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(px(5))))

    # Lid, hinged open behind the body.
    d.polygon([(px(17), px(31)), (px(83), px(21)), (px(90), px(33)), (px(24), px(43))],
              fill=lid_lt, outline=outline, width=lw)
    d.polygon([(px(24), px(43)), (px(90), px(33)), (px(90), px(38)), (px(24), px(48))],
              fill=lid_dk, outline=outline, width=lw)

    # Ice heaped above the rim.
    rnd = random.Random(7)
    for i in range(11):
        cw = px(rnd.uniform(7, 10))
        cx = px(19) + i * px(5.9) + px(rnd.uniform(-1, 1))
        cy = px(37 + rnd.uniform(0, 7))
        d.rectangle([cx, cy, cx + cw, cy + cw], fill=(236, 248, 255, 255),
                    outline=(146, 190, 220, 255), width=max(1, lw - 1))
        d.rectangle([cx + cw * 0.55, cy + cw * 0.55, cx + cw, cy + cw],
                    fill=(186, 218, 240, 255))

    # Body front, covering the bottom half of the ice.
    d.rounded_rectangle([px(16), px(48), px(84), px(86)], radius=px(4),
                        fill=body_lt, outline=outline, width=lw)
    d.rounded_rectangle([px(16), px(72), px(84), px(86)], radius=px(4),
                        fill=body_dk, outline=outline, width=lw)
    d.line([(px(16), px(72)), (px(84), px(72))], fill=outline, width=lw)

    # Rim lip.
    d.rectangle([px(14), px(46), px(86), px(53)], fill=(226, 234, 240, 255),
                outline=outline, width=lw)

    # Handle.
    d.arc([px(38), px(58), px(62), px(78)], start=180, end=360, fill=outline,
          width=max(3, int(px(2.2))))

    for cx, cy, r in ((px(10), px(22), px(7)), (px(91), px(62), px(6)), (px(80), px(11), px(5))):
        draw_snowflake(d, cx, cy, r, (180, 220, 244, 235), width=max(2, int(px(0.9))))

    return img


def banner(size, title, subtitle, title_px, sub_px, cooler_frac=0.62):
    w = h = size
    img = Image.new("RGB", (w, h), (18, 26, 24))
    d = ImageDraw.Draw(img)

    # Cold radial wash behind the subject.
    for i in range(h, 0, -4):
        t = i / h
        c = (int(18 + 26 * (1 - t)), int(30 + 46 * (1 - t)), int(34 + 60 * (1 - t)))
        d.ellipse([w / 2 - i, h / 2 - i * 0.8, w / 2 + i, h / 2 + i * 0.8], fill=c)

    rnd = random.Random(11)
    for _ in range(26):
        cx, cy = rnd.randrange(w), rnd.randrange(int(h * 0.8))
        draw_snowflake(d, cx, cy, rnd.randint(4, 11), (120, 160, 190), width=1)

    cs = int(size * cooler_frac)
    cooler = draw_cooler(cs)
    img.paste(cooler, ((w - cs) // 2, int(h * 0.12)), cooler)

    tf = load_font(title_px)
    tw = d.textlength(title, font=tf)
    ty = int(h * 0.74)
    d.text(((w - tw) / 2 + 2, ty + 2), title, font=tf, fill=(8, 14, 18))
    d.text(((w - tw) / 2, ty), title, font=tf, fill=(238, 248, 255))

    if subtitle:
        sf = load_font(sub_px, bold=False)
        sw = d.textlength(subtitle, font=sf)
        d.text(((w - sw) / 2, ty + title_px + int(size * 0.02)), subtitle, font=sf, fill=(150, 190, 214))

    return img


def main():
    icon = ice_bag_icon()
    icon.save(ensure(os.path.join(TEX, "Item_CFIceBag.png")))

    world = ice_bag_world_texture()
    world.save(ensure(os.path.join(TEX, "WorldItems", "CFIceBag.png")))

    banner(512, "COOLER FRIDGE", "Portable cold storage for Build 42", 44, 20).save(
        ensure(os.path.join(MOD, "poster.png")))
    banner(512, "COOLER FRIDGE", "Pack ice. Keep food. Build 42.", 44, 20).save(
        ensure(os.path.join(ROOT, "preview.png")))

    small = draw_cooler(112)
    icon_img = Image.new("RGB", (128, 128), (26, 44, 58))
    icon_img.paste(small, (8, 12), small)
    icon_img.save(ensure(os.path.join(MOD, "icon.png")))

    # A 4x blowup of the inventory icon, handy for eyeballing the pixels.
    icon.resize((256, 256), Image.NEAREST).save(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon_preview.png"))
    print("done")


if __name__ == "__main__":
    main()
