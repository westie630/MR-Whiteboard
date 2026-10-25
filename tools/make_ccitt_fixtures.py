"""Makes the fax-coded pictures tests/test_pdf_engine.gd decodes (tests/fixtures/ccitt/). Each is a small bitmap coded by libtiff (through Pillow)
as Group 4, Group 3 (one-dimensional, with end-of-line codes) or Modified Huffman, together with the bitmap libtiff reads back from it, so the
decoder is checked against someone else's. They are kept in the repository, so this only needs to be run again to change them:
    python tools/make_ccitt_fixtures.py        (needs Pillow with libtiff)"""
import io
import json
import os
import random
import struct

from PIL import Image, ImageChops, ImageDraw, ImageFont, TiffImagePlugin

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "tests", "fixtures", "ccitt")
os.makedirs(OUT, exist_ok=True)


def images():
    rng = random.Random(7)
    out = {}
    # text, at a width that is not a multiple of 8
    im = Image.new("1", (203, 120), 255)
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=14)
    for i in range(6):
        d.text((6, 4 + i * 19), "Fax %d: the quick brown fox" % i, font=font, fill=0)
    out["text"] = im
    # a page-wide picture with runs longer than 2560 pixels (extended make-up codes) and black runs of every length class
    im = Image.new("1", (3100, 40), 255)
    d = ImageDraw.Draw(im)
    d.rectangle((10, 5, 2900, 12), fill=0)
    d.rectangle((300, 20, 2999, 30), fill=0)
    for x in range(0, 3100, 97):
        d.line((x, 33, x, 39), fill=0)
    out["wide"] = im
    # noise: every kind of code, short runs
    im = Image.new("1", (96, 64), 255)
    px = im.load()
    for y in range(64):
        for x in range(96):
            px[x, y] = 0 if rng.random() < 0.45 else 255
    out["noise"] = im
    # lines at angles: vertical, pass and horizontal modes
    im = Image.new("1", (160, 100), 255)
    d = ImageDraw.Draw(im)
    d.line((0, 0, 159, 99), fill=0, width=3)
    d.line((159, 0, 0, 99), fill=0, width=1)
    d.line((80, 0, 80, 99), fill=0, width=5)
    d.rectangle((20, 20, 60, 70), outline=0)
    d.ellipse((90, 30, 150, 90), outline=0, width=2)
    out["lines"] = im
    out["blank"] = Image.new("1", (64, 16), 255)
    out["black"] = Image.new("1", (64, 16), 0)
    return out


def strip(tiff):
    """The coded bytes of the one strip of a TIFF, and its tags."""
    order = "<" if tiff[:2] == b"II" else ">"
    ifd = struct.unpack(order + "I", tiff[4:8])[0]
    n = struct.unpack(order + "H", tiff[ifd:ifd + 2])[0]
    tags = {}
    for i in range(n):
        tag, typ, count, val = struct.unpack(order + "HHII", tiff[ifd + 2 + i * 12:ifd + 14 + i * 12])
        if typ == 3 and count == 1:
            val = struct.unpack(order + "H", tiff[ifd + 2 + i * 12 + 8:ifd + 2 + i * 12 + 10])[0]
        if count > 1:
            size = {3: 2, 4: 4}[typ]
            vals = struct.unpack(order + ("H" if typ == 3 else "I") * count, tiff[val:val + size * count])
            val = vals
        tags[tag] = val
    offs, counts = tags[273], tags[279]
    assert isinstance(offs, int) or len(offs) == 1, "more than one strip"
    off = offs if isinstance(offs, int) else offs[0]
    cnt = counts if isinstance(counts, int) else counts[0]
    return tiff[off:off + cnt], tags


def main():
    manifest = {}
    for name, im in images().items():
        for variant, comp, t4 in [("g4", "group4", None), ("g3", "group3", None), ("mh", "tiff_ccitt", None),
                                  ("g32d", "group3", 1), ("g3fill", "group3", 4), ("g32dfill", "group3", 5)]:       # T4Options: 1 = two-dimensional, 4 = fill bits
            saved = ImageChops.invert(im)
            buf = io.BytesIO()
            info = TiffImagePlugin.ImageFileDirectory_v2()
            if t4 is not None:
                info[292] = t4
            saved.save(buf, format="TIFF", compression=comp, tiffinfo=info)
            data, tags = strip(buf.getvalue())
            assert tags.get(266, 1) == 1, "bits in reverse order"
            back = Image.open(io.BytesIO(buf.getvalue()))
            back.load()
            assert back.size == im.size
            assert ImageChops.difference(back.convert("1"), saved).getbbox() is None, "libtiff does not read back what it wrote"
            exp = im.tobytes()                                    # the original: 1 = paper (white), rows padded to bytes, as a PDF picture has them
            k, align = {"g4": (-1, False), "mh": (0, True), "g3": (0, False), "g3fill": (0, False), "g32d": (4, False), "g32dfill": (4, False)}[variant]
            key = "%s_%s" % (name, variant)
            open(os.path.join(OUT, key + ".bin"), "wb").write(data)
            open(os.path.join(OUT, key + ".exp"), "wb").write(exp)
            manifest[key] = {"k": k, "columns": im.size[0], "rows": im.size[1], "align": align, "eol": variant.startswith("g3"), "bytes": len(data)}
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1, sort_keys=True)
    print(len(manifest), "fixtures,", sum(m["bytes"] for m in manifest.values()), "bytes of coded data")


if __name__ == "__main__":
    main()
