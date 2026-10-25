"""Makes the small PDF files tests/test_pdf_*.gd read (tests/fixtures/pdf/). They are kept in the repository, so this only needs to be run
again to change them:  python tools/make_pdf_fixtures.py   (needs reportlab, pypdf and Pillow)."""
import io
import os
import zlib

from PIL import Image, ImageDraw
from pypdf import PdfReader, PdfWriter
from reportlab.lib.colors import Color, HexColor
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "tests", "fixtures", "pdf")
FONTS = os.path.join(ROOT, "assets", "pdf_fonts")
os.makedirs(OUT, exist_ok=True)


def path(name):
    return os.path.join(OUT, name)


def base14():
    """Two pages in the standard fonts (not embedded), rotated text, shapes in colour; the second page is landscape."""
    c = canvas.Canvas(path("base14.pdf"), pagesize=(300, 200), pageCompression=1)
    c.setTitle("Base 14")
    c.setFont("Helvetica", 14)
    c.drawString(20, 170, "Hello PDF, Helvetica")
    c.setFont("Times-Roman", 14)
    c.drawString(20, 150, "Times Roman and fi ligature")
    c.setFont("Courier-Bold", 12)
    c.drawString(20, 130, "Courier Bold 0123456789")
    c.setFillColor(HexColor("#e63946"))
    c.rect(20, 60, 80, 50, fill=1, stroke=0)
    c.setStrokeColor(HexColor("#1d3557"))
    c.setLineWidth(3)
    c.circle(170, 85, 30, stroke=1, fill=0)
    c.setDash(6, 3)
    c.line(20, 40, 280, 40)
    c.saveState()
    c.translate(250, 120)
    c.rotate(90)
    c.setFillColor(Color(0, 0, 0))
    c.setFont("Helvetica-Oblique", 10)
    c.drawString(0, 0, "rotated")
    c.restoreState()
    c.showPage()
    c.setPageSize((400, 220))
    c.setFont("Helvetica-Bold", 20)
    c.drawString(20, 170, "Page two is wider")
    c.setFillColor(HexColor("#2a9d8f"))
    c.roundRect(20, 40, 200, 80, 12, fill=1, stroke=0)
    c.showPage()
    c.save()


def embedded():
    """An embedded TrueType font (Liberation Serif), a JPEG, a PNG with transparency, gradients, transparency, a clip."""
    pdfmetrics.registerFont(TTFont("LibSerif", os.path.join(FONTS, "LiberationSerif-Regular.ttf")))
    pdfmetrics.registerFont(TTFont("LibSans", os.path.join(FONTS, "LiberationSans-Bold.ttf")))
    c = canvas.Canvas(path("embedded.pdf"), pagesize=(320, 240), pageCompression=1)
    c.setFont("LibSerif", 16)
    c.drawString(16, 210, "Embedded serif: Affe, ÅÄÖ, ß, œ")
    c.setFont("LibSans", 12)
    c.drawString(16, 190, "Embedded bold sans 0123")
    # a picture: photo-like JPEG and a PNG with a soft edge
    im = Image.new("RGB", (64, 48))
    d = ImageDraw.Draw(im)
    for x in range(64):
        d.line([(x, 0), (x, 47)], fill=(x * 4, 120, 255 - x * 4))
    d.ellipse([20, 10, 44, 38], fill=(255, 220, 0))
    jb = io.BytesIO()
    im.save(jb, "JPEG", quality=90)
    jb.seek(0)
    from reportlab.lib.utils import ImageReader
    c.drawImage(ImageReader(jb), 16, 110, width=96, height=72)
    al = Image.new("RGBA", (40, 40), (0, 0, 0, 0))
    ImageDraw.Draw(al).ellipse([2, 2, 38, 38], fill=(200, 30, 60, 200))
    pb = io.BytesIO()
    al.save(pb, "PNG")
    pb.seek(0)
    c.drawImage(ImageReader(pb), 130, 120, width=60, height=60, mask="auto")
    # gradients
    for box, draw in [((16, 60, 130, 40), lambda: c.linearGradient(16, 60, 140, 100, (HexColor("#f4a261"), HexColor("#264653")), extend=False)),
                      ((190, 40, 80, 80), lambda: c.radialGradient(230, 80, 40, (HexColor("#ffffff"), HexColor("#e76f51")), extend=False))]:
        c.saveState()
        pth = c.beginPath()
        pth.rect(*box)
        c.clipPath(pth, stroke=0, fill=0)
        draw()
        c.restoreState()
    # transparency and a clip
    c.saveState()
    c.setFillColor(Color(0.1, 0.2, 0.8, alpha=0.4))
    c.rect(180, 140, 100, 60, fill=1, stroke=0)
    c.setFillColor(Color(0.9, 0.2, 0.1, alpha=0.4))
    c.rect(210, 120, 90, 60, fill=1, stroke=0)
    c.restoreState()
    c.saveState()
    p = c.beginPath()
    p.circle(60, 30, 22)
    c.clipPath(p, stroke=0, fill=0)
    c.setFillColor(HexColor("#6a4c93"))
    c.rect(30, 0, 100, 60, fill=1, stroke=0)
    c.restoreState()
    c.showPage()
    c.save()


def many():
    """Thirty small pages, each with its number: paging, the slider, drawing on different pages."""
    c = canvas.Canvas(path("many.pdf"), pagesize=(200, 280), pageCompression=1)
    for i in range(1, 31):
        c.setFont("Helvetica-Bold", 40)
        c.drawCentredString(100, 130, str(i))
        c.setFont("Helvetica", 9)
        c.drawString(10, 10, "page %d of 30" % i)
        c.showPage()
    c.save()


def encrypted():
    src = PdfReader(path("base14.pdf"))
    for name, algo, user in [("rc4_128.pdf", "RC4-128", ""), ("aes_128.pdf", "AES-128", ""), ("aes_256.pdf", "AES-256", ""), ("locked.pdf", "AES-128", "secret")]:
        w = PdfWriter()
        for p in src.pages:
            w.add_page(p)
        w.encrypt(user_password=user, owner_password="owner-secret", algorithm=algo)
        with open(path(name), "wb") as f:
            w.write(f)


def damaged():
    """The cross-reference table cut off (the file has to be read by scanning), and a stream with a stray byte after its zlib data."""
    data = open(path("base14.pdf"), "rb").read()
    cut = data.rfind(b"xref")
    open(path("no_xref.pdf"), "wb").write(data[:cut])
    # a minimal PDF whose content stream is followed by a newline inside /Length (the engine's decompress_dynamic dies on that)
    content = zlib.compress(b"0.2 0.4 0.9 rg 20 20 160 60 re f")
    content += b"\n"
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << >> >>",
            b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(content) + content + b"\nendstream"]
    out = bytearray(b"%PDF-1.4\n")
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for o in offs:
        out += b"%010d 00000 n \n" % o
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    open(path("stray_byte.pdf"), "wb").write(bytes(out))


if __name__ == "__main__":
    base14()
    embedded()
    many()
    encrypted()
    damaged()
    for n in sorted(os.listdir(OUT)):
        print(n, os.path.getsize(path(n)))
