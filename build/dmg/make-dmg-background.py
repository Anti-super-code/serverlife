"""Renders the macOS .dmg window background from the app's own palette and font.

    python3 build/dmg/make-dmg-background.py

Writes background.png (640x400) and background@2x.png (1280x800) next to this
script. build/package-mac.sh hands the 1x file to create-dmg, which picks up the
@2x sibling on its own; the icon coordinates in that script line up with the
arrow and caption drawn here.

Same light ground (#EDF1F6) and Fira Sans Condensed as the app, so the disk
image reads as part of Serverlife and not like a stock template.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FONT = REPO / "macos/Sources/Serverlife/Resources/Fonts/FiraSansCondensed-SemiBold.ttf"

# Theme.swift
BG = (0xED, 0xF1, 0xF6)
TEXT_MID = (0x43, 0x4D, 0x60)
TEXT_LO = (0x71, 0x7D, 0x91)
ARROW = (0xAF, 0xBA, 0xC9)   # a light slate that sits quietly between the icons

W, H = 640, 500
SS = 3  # supersample: PIL has no antialiased primitives, so draw big and shrink.

# Icon centres, kept in step with the --icon / --app-drop-link flags in
# build/package-mac.sh. The arrow runs between the two top icons; the second row
# (READ-ME-FIRST.txt, LICENSE) needs headroom below it for its labels, which is
# what the extra window height buys.
APP_C = (170, 175)
APPLICATIONS_C = (470, 175)
ROW2_Y = 340
ICON_HALF = 50  # --icon-size 100


def render(scale: int) -> Image.Image:
    w, h = W * scale * SS, H * scale * SS
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    s = scale * SS

    # Caption across the top.
    caption = "Drag Serverlife onto Applications to install"
    font = ImageFont.truetype(str(FONT), 22 * s)
    tw = d.textlength(caption, font=font)
    d.text(((w - tw) / 2, 48 * s), caption, font=font, fill=TEXT_MID)

    # Arrow from just right of the app icon to just left of the Applications icon.
    y = APP_C[1] * s
    x0 = (APP_C[0] + ICON_HALF + 18) * s
    x1 = (APPLICATIONS_C[0] - ICON_HALF - 18) * s
    shaft = 5 * s
    d.line([(x0, y), (x1 - 10 * s, y)], fill=ARROW, width=shaft)
    head = 13 * s
    d.polygon([(x1, y), (x1 - head, y - head), (x1 - head, y + head)], fill=ARROW)

    # Label for the second row, sitting just above those two icons.
    sub = "Keep these for reference"
    sfont = ImageFont.truetype(str(FONT), 13 * s)
    sw = d.textlength(sub, font=sfont)
    d.text(((w - sw) / 2, (ROW2_Y - ICON_HALF - 26) * s), sub, font=sfont, fill=TEXT_LO)

    return img.resize((W * scale, H * scale), Image.LANCZOS)


def main() -> None:
    render(1).save(HERE / "background.png")
    render(2).save(HERE / "background@2x.png")
    print("wrote", HERE / "background.png", "and background@2x.png")


if __name__ == "__main__":
    main()
