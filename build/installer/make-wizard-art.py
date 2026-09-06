"""Renders the Inno Setup wizard images from the app's own icon colours and font.

    python build/installer/make-wizard-art.py

Writes wizard-large-*.png (the tall panel on the Welcome / Finished pages) and
wizard-small-*.png (the header badge on the interior pages) next to this script, one
file per DPI step. serverlife.iss lists all of them; Inno picks the size the current
DPI wants and downsamples from there.

Same gradient (#2E6BF5 -> #22C3E6) and heartbeat mark as build/generate-icon.py, so the
installer looks like the app and not like WinZip circa 1999.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ACCENT_FROM = (0x2E, 0x6B, 0xF5)   # Theme.xaml accentBlue
ACCENT_TO = (0x22, 0xC3, 0xE6)     # Theme.xaml accentCyan

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FONT_DIR = REPO / "src" / "Serverlife" / "Assets" / "Fonts"
ICON_PNG = REPO / "src" / "Serverlife" / "Assets" / "serverlife-source-1024.png"

# Inno shows these at 164x314 / 55x58 at 100% DPI; the rest are 150 / 200 / 250%.
LARGE_SIZES = [(164, 314), (246, 471), (328, 628), (410, 797)]
SMALL_SIZES = [(55, 58), (83, 86), (110, 116), (138, 140)]

SS = 4  # supersample: PIL has no antialiased primitives, so draw big and shrink.


def diagonal_gradient(w: int, h: int) -> Image.Image:
    """Top-left to bottom-right, the same direction the icon's gradient runs."""
    grad = Image.new("RGB", (w, h))
    px = grad.load()
    span = (w - 1) + (h - 1)
    for y in range(h):
        for x in range(w):
            t = (x + y) / span
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(ACCENT_FROM, ACCENT_TO))
    return grad


def heartbeat(draw: ImageDraw.ImageDraw, w: int, h: int, alpha: int) -> None:
    """The ECG pulse from the icon, stretched wide and bled off both edges."""
    mid = 0.46
    pts = [
        (-0.10, mid), (0.30, mid), (0.40, mid - 0.13),
        (0.52, mid + 0.16), (0.63, mid - 0.09), (0.72, mid), (1.10, mid),
    ]
    draw.line(
        [(round(x * w), round(y * h)) for x, y in pts],
        fill=(255, 255, 255, alpha),
        width=round(w * 0.035),
        joint="curve",
    )


def render_large() -> Image.Image:
    base_w, base_h = LARGE_SIZES[-1]
    w, h = base_w * SS, base_h * SS

    img = Image.new("RGBA", (w, h))
    img.paste(diagonal_gradient(w, h), (0, 0))

    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    heartbeat(ImageDraw.Draw(overlay), w, h, alpha=54)
    img = Image.alpha_composite(img, overlay)

    draw = ImageDraw.Draw(img)
    pad = round(w * 0.11)
    title_font = ImageFont.truetype(str(FONT_DIR / "FiraSansCondensed-SemiBold.ttf"), round(w * 0.135))
    sub_font = ImageFont.truetype(str(FONT_DIR / "FiraSansCondensed-Light.ttf"), round(w * 0.058))

    sub_y = h - pad - round(w * 0.058)
    draw.text((pad, sub_y), "Local dev servers, visible.", font=sub_font, fill=(255, 255, 255, 210))
    title_bbox = draw.textbbox((0, 0), "Serverlife", font=title_font)
    draw.text((pad, sub_y - (title_bbox[3] - title_bbox[1]) - round(w * 0.05)),
              "Serverlife", font=title_font, fill=(255, 255, 255, 255))

    return img


def render_small() -> Image.Image:
    base = SMALL_SIZES[-1][1] * SS
    icon = Image.open(ICON_PNG).convert("RGBA").resize((base, base), Image.LANCZOS)
    return icon


def save_steps(master: Image.Image, sizes, stem: str) -> None:
    for w, h in sizes:
        frame = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        scaled = master.resize((w, min(h, round(master.height * w / master.width))), Image.LANCZOS)
        frame.paste(scaled, (0, (h - scaled.height) // 2), scaled)
        out = HERE / f"{stem}-{w}.png"
        frame.save(out)
        print(f"wrote {out.relative_to(REPO)}  ({w}x{h})")


def main() -> None:
    save_steps(render_large(), LARGE_SIZES, "wizard-large")
    save_steps(render_small(), SMALL_SIZES, "wizard-small")


if __name__ == "__main__":
    main()
