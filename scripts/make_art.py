"""Generate all Tien's Coolers art assets."""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import pz_model

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "Contents", "mods", "TienCoolers", "42")
TEX = os.path.join(MOD, "media", "textures")

# Rendering the real models needs the game's own media folder. Set CF_PZ_MEDIA to
# point at it; without it the poster falls back to the drawn cooler, so the script
# still runs on a machine with no Project Zomboid install.
PZ_MEDIA = os.environ.get("CF_PZ_MEDIA") or next(
    (p for p in (
        r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media",
        os.path.expanduser("~/Library/Application Support/Steam/steamapps/common/"
                           "ProjectZomboid/Project Zomboid.app/Contents/Java/media"),
        os.path.expanduser("~/.steam/steam/steamapps/common/ProjectZomboid/media"),
    ) if os.path.isdir(p)), None)

OUTLINE = (22, 32, 45, 255)
BAG = (196, 224, 240, 190)
BAG_HI = (238, 250, 255, 225)
ICE_LT = (240, 250, 255, 255)
ICE_MD = (176, 214, 236, 255)
ICE_DK = (120, 168, 204, 255)
BAND = (28, 84, 132, 255)
BAND_EDGE = (150, 206, 240, 255)
LABEL = (236, 248, 255, 255)


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

# The label is stamped pixel by pixel: at 32x32 a real font either renders to mush
# or blows past the width of the bag. Three columns per glyph, five rows, one column
# of air between them - 11px for "ICE", which fits the band with a pixel to spare.
GLYPHS = {
    "I": ["###", ".#.", ".#.", ".#.", "###"],
    "C": ["###", "#..", "#..", "#..", "###"],
    "E": ["###", "#..", "##.", "#..", "###"],
}


def stamp(d, text, x, y, colour, gap=1):
    for ch in text:
        rows = GLYPHS[ch]
        for ry, row in enumerate(rows):
            for rx, on in enumerate(row):
                if on == "#":
                    d.point((x + rx, y + ry), fill=colour)
        x += len(rows[0]) + gap


def ice_bag_icon():
    img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Straight-ish sides and a flat bottom: a full bag slumps, it does not bulge into
    # a ball, and the flat base is what separates it from a jar at inventory size.
    body = [
        (13, 7), (19, 7), (22, 10), (25, 14), (26, 20),
        (26, 28), (24, 30), (8, 30), (6, 28), (6, 20), (7, 14), (10, 10),
    ]
    d.polygon(body, fill=BAG)

    # Cubes above and below the label, none of them centred on it.
    cubes = [(9, 11), (15, 10), (20, 12), (8, 25), (14, 25), (20, 25), (11, 20)]
    for cx, cy in cubes:
        d.rectangle([cx, cy, cx + 4, cy + 4], fill=ICE_MD)
        d.rectangle([cx, cy, cx + 2, cy + 2], fill=ICE_LT)
        d.point((cx + 4, cy + 4), fill=ICE_DK)
        d.point((cx + 3, cy + 4), fill=ICE_DK)
        d.point((cx + 4, cy + 3), fill=ICE_DK)

    mask = Image.new("L", (32, 32), 0)
    ImageDraw.Draw(mask).polygon(body, fill=255)
    img.putalpha(Image.composite(img.split()[3], Image.new("L", (32, 32), 0), mask))

    # The printed band, drawn edge to edge and then clipped to the silhouette, so it
    # runs off both sides the way it wraps the world model.
    band = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bd.rectangle([0, 15, 31, 23], fill=BAND)
    bd.line([(0, 15), (31, 15)], fill=BAND_EDGE)
    bd.line([(0, 23), (31, 23)], fill=BAND_EDGE)
    stamp(bd, "ICE", 11, 17, LABEL)
    band.putalpha(Image.composite(band.split()[3], Image.new("L", (32, 32), 0), mask))
    img = Image.alpha_composite(img, band)

    # Plastic sheen down the left shoulder and hip.
    d = ImageDraw.Draw(img)
    d.line([(9, 12), (8, 14)], fill=BAG_HI)
    d.line([(8, 26), (8, 28)], fill=BAG_HI)

    # Gathered neck, fanning out above the tie.
    d.polygon([(12, 2), (20, 2), (19, 9), (13, 9)], fill=BAG)
    d.line([(14, 3), (15, 8)], fill=BAG_HI)
    d.line([(18, 3), (17, 8)], fill=(168, 200, 220, 200))

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
    #
    # PlasticBag_Ground.fbx unwraps the bag as a loop across x 0-163 only: x 27-133 is
    # the wide face (both halves folded onto the same island, which is why the word
    # comes out the right way round on either side) and the gussets take the strips at
    # either end. Everything past x 163 is texture the mesh never samples. So the band
    # runs the full width of that loop, with no vertical end caps - they would show up
    # as a seam down the gusset - and the word sits at the centre of the face.
    WRAP = 163
    FACE_CENTRE = 80

    d = ImageDraw.Draw(img)
    d.rectangle([0, 96, WRAP, 160], fill=(28, 84, 132))
    d.line([(0, 102), (WRAP, 102)], fill=(150, 206, 240), width=3)
    d.line([(0, 154), (WRAP, 154)], fill=(150, 206, 240), width=3)
    font = load_font(34)
    text = "ICE"
    tw = d.textlength(text, font=font)
    d.text((FACE_CENTRE - tw / 2, 112), text, font=font, fill=(232, 246, 255))
    return img


# --------------------------------------------------------------------------
# Shared cooler illustration for the icon, poster and Workshop preview.
# --------------------------------------------------------------------------

# Where each platform keeps the faces this art uses. The list has to cover every
# machine the script runs on: ImageFont.load_default() is a 10px bitmap that ignores
# the size argument, so a missing font does not degrade - it silently renders the
# poster title and the bag's "ICE" label as unreadable specks.
_FONT_DIRS = (r"C:\Windows\Fonts", "/System/Library/Fonts/Supplemental",
              "/Library/Fonts", os.path.expanduser("~/Library/Fonts"),
              "/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/TTF")
_BOLD = ("arialbd.ttf", "Arial Bold.ttf", "seguisb.ttf", "DejaVuSans-Bold.ttf")
_REGULAR = ("arial.ttf", "Arial.ttf", "segoeui.ttf", "DejaVuSans.ttf")


def load_font(size, bold=True):
    for name in (_BOLD if bold else _REGULAR) + _REGULAR:
        for directory in _FONT_DIRS:
            try:
                return ImageFont.truetype(os.path.join(directory, name), size)
            except OSError:
                continue
    return ImageFont.load_default(size)


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


def scatter_cold_moodles(img, count):
    """Vanilla's cold moodle, dropped in behind the subject instead of drawn snowflakes.

    It is the icon players already read as "this is cold", and it brings the game's own
    line work, so the poster sits next to a screenshot without looking hand-drawn.
    Draws nothing when the game's media folder is missing.
    """
    if not PZ_MEDIA:
        return
    path = os.path.join(PZ_MEDIA, "ui", "Moodles", "128", "Status_TemperatureLow.png")
    if not os.path.isfile(path):
        return
    moodle = Image.open(path).convert("RGBA")

    w, h = img.size
    rnd = random.Random(11)
    for _ in range(count):
        side = rnd.randint(int(w * 0.06), int(w * 0.13))
        stamp = moodle.resize((side, side), Image.LANCZOS)
        # Held well back, so it reads as wallpaper and never as a second subject.
        stamp.putalpha(stamp.split()[3].point(lambda a, f=rnd.uniform(0.22, 0.40): int(a * f)))
        img.alpha_composite(stamp, (rnd.randrange(-side // 3, w - side // 2),
                                    rnd.randrange(-side // 3, int(h * 0.72))))


def model_scene(size):
    """The game's cooler with our bag of ice in front of it, both from the real models.

    Returns None when the game's media folder cannot be found, so callers fall back to
    draw_cooler().
    """
    if not PZ_MEDIA:
        return None

    cooler = pz_model.render(
        os.path.join(PZ_MEDIA, "models_X", "WorldItems", "Clothing", "Cooler_Ground.fbx"),
        os.path.join(PZ_MEDIA, "textures", "Clothes", "Bag", "Cooler.png"),
        size=int(size * 0.56), yaw=48, pitch=24)
    bag = pz_model.render(
        os.path.join(PZ_MEDIA, "models_X", "WorldItems", "Clothing", "PlasticBag_Ground.fbx"),
        os.path.join(TEX, "WorldItems", "TienCoolerIceBag.png"),
        size=int(size * 0.30), yaw=68, pitch=24)
    cooler = cooler.crop(cooler.getbbox())
    bag = bag.crop(bag.getbbox())

    scene = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Both models stand on one ground line, the bag a touch nearer the camera so it
    # overlaps the cooler's front corner instead of floating alongside it.
    ground = int(size * 0.655)
    overlap = int(bag.width * 0.42)
    left = (size - (cooler.width + bag.width - overlap)) // 2

    cx, cy = left + bag.width - overlap, ground - cooler.height
    _ground_shadow(scene, cx, cy, cooler, blur=15, alpha=135)
    scene.alpha_composite(cooler, (cx, cy))

    bx, by = left, ground + int(bag.height * 0.06) - bag.height
    _ground_shadow(scene, bx, by, bag, blur=11, alpha=125)
    scene.alpha_composite(bag, (bx, by))
    return scene


def _ground_shadow(scene, x, y, model, blur, alpha):
    shadow = Image.new("RGBA", scene.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        [x + model.width * 0.03, y + model.height * 0.90,
         x + model.width * 0.99, y + model.height * 1.11], fill=(4, 10, 16, alpha))
    scene.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))


def cold_backdrop(size, moodles=9):
    """The poster's ground: a cold radial wash with vanilla moodles held well back."""
    w = h = size
    img = Image.new("RGBA", (w, h), (18, 26, 24, 255))
    d = ImageDraw.Draw(img)

    for i in range(h, 0, -4):
        t = i / h
        c = (int(18 + 26 * (1 - t)), int(30 + 46 * (1 - t)), int(34 + 60 * (1 - t)))
        d.ellipse([w / 2 - i, h / 2 - i * 0.8, w / 2 + i, h / 2 + i * 0.8], fill=c)

    scatter_cold_moodles(img, count=moodles)
    return img


def mod_icon(size=128, fill=0.94):
    """The mod-list icon: the poster's models, cropped tight and centred.

    Same scene as the poster so the two read as one mod in the list, but with no room
    for a ground line or a title the art is trimmed to its bounding box and scaled to
    fill the tile. Renders at 3x and comes down with LANCZOS: at 128px the bag's
    printed band only survives if the edges are resolved before they are shrunk.
    """
    img = cold_backdrop(size, moodles=5)

    scene = model_scene(size * 3)
    if scene is None:                          # no game install - the drawn fallback
        drawn = draw_cooler(int(size * 0.88))
        img.paste(drawn, ((size - drawn.width) // 2, int(size * 0.09)), drawn)
        return img.convert("RGB")

    art = scene.crop(scene.getbbox())
    span = int(size * fill)
    scale = min(span / art.width, span / art.height)
    art = art.resize((max(1, round(art.width * scale)), max(1, round(art.height * scale))),
                     Image.LANCZOS)
    img.alpha_composite(art, ((size - art.width) // 2, (size - art.height) // 2))
    return img.convert("RGB")


def banner(size, title, subtitle, title_px, sub_px, cooler_frac=0.62, subject=None):
    w = h = size
    img = cold_backdrop(size)
    d = ImageDraw.Draw(img)

    if subject is not None:
        img.paste(subject, (0, 0), subject)
    else:
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

    return img.convert("RGB")


def main():
    icon = ice_bag_icon()
    icon.save(ensure(os.path.join(TEX, "Item_TienCoolerIceBag.png")))

    world = ice_bag_world_texture()
    world.save(ensure(os.path.join(TEX, "WorldItems", "TienCoolerIceBag.png")))

    scene = model_scene(512)
    banner(512, "TIEN'S COOLERS", "Portable Cold Storage", 44, 20,
           subject=scene).save(ensure(os.path.join(MOD, "poster.png")))
    banner(512, "TIEN'S COOLERS", "Portable Cold Storage", 44, 20,
           subject=scene).save(ensure(os.path.join(ROOT, "preview.png")))

    mod_icon(128).save(ensure(os.path.join(MOD, "icon.png")))

    # A 4x blowup of the inventory icon, handy for eyeballing the pixels.
    icon.resize((256, 256), Image.NEAREST).save(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon_preview.png"))
    print("done")


if __name__ == "__main__":
    main()
