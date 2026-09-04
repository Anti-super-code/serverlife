"""Generates the Serverlife app icon from nothing but the theme's accent colours.

    python build/generate-icon.py

Writes src/Serverlife/Assets/serverlife-source-1024.png and serverlife.ico, plus the
macOS .icns source. Regenerate rather than hand-editing: the gradient endpoints here are
the same #2E6BF5 -> #22C3E6 the UI uses, so the icon stays in step with the theme.

The mark is a heartbeat line, which is what the app is actually for - not "here are some
servers" but "your servers are still alive". It has to survive being 16px wide in the
notification area, so the line is heavy and there is no other detail to lose.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ACCENT_FROM = (0x2E, 0x6B, 0xF5)   # Theme.xaml accentBlue
ACCENT_TO = (0x22, 0xC3, 0xE6)     # Theme.xaml accentCyan

# Drawn oversized and downsampled: PIL has no antialiased primitives, so supersampling
# is what keeps the rounded corners and the pulse line clean.
SUPERSAMPLE = 4
BASE = 1024
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

REPO = Path(__file__).resolve().parent.parent
WIN_ASSETS = REPO / "src" / "Serverlife" / "Assets"
MAC_ASSETS = REPO / "macos" / "Resources" / "AppIcon"


def diagonal_gradient(size: int) -> Image.Image:
    """Top-left to bottom-right, matching the theme's LinearGradientBrush direction."""
    gradient = Image.new("RGB", (size, size))
    pixels = gradient.load()
    for y in range(size):
        for x in range(size):
            # Position along the diagonal, 0 at top-left and 1 at bottom-right.
            t = (x + y) / (2 * (size - 1))
            pixels[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(ACCENT_FROM, ACCENT_TO)
            )
    return gradient


def render(size: int) -> Image.Image:
    big = size * SUPERSAMPLE

    # Rounded-square mask, at the same 22% radius the UI uses for its large panels.
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=round(big * 0.22), fill=255
    )

    icon = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    icon.paste(diagonal_gradient(big), (0, 0), mask)

    # The pulse: flat, up, hard down, up, flat - an ECG read left to right. Coordinates
    # are fractions of the canvas so the shape is identical at every size.
    points = [
        (0.14, 0.50), (0.32, 0.50), (0.40, 0.30),
        (0.50, 0.72), (0.60, 0.42), (0.68, 0.50), (0.86, 0.50),
    ]
    draw = ImageDraw.Draw(icon)
    draw.line(
        [(round(x * big), round(y * big)) for x, y in points],
        fill=(255, 255, 255, 255),
        width=round(big * 0.075),
        joint="curve",
    )
    # joint="curve" rounds the interior corners but leaves the two ends square.
    radius = round(big * 0.075) // 2
    for x, y in (points[0], points[-1]):
        cx, cy = round(x * big), round(y * big)
        draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=(255, 255, 255, 255))

    return icon.resize((size, size), Image.LANCZOS)


def main() -> None:
    WIN_ASSETS.mkdir(parents=True, exist_ok=True)
    MAC_ASSETS.mkdir(parents=True, exist_ok=True)

    source = render(BASE)
    source.save(WIN_ASSETS / "serverlife-source-1024.png")
    source.save(MAC_ASSETS / "source-icon-1024.png")

    # Each size is rendered rather than scaled from one bitmap: at 16px the pulse needs
    # to be drawn thick, not shrunk into mush.
    frames = [render(s) for s in ICO_SIZES]
    frames[-1].save(
        WIN_ASSETS / "serverlife.ico",
        format="ICO",
        sizes=[(s, s) for s in ICO_SIZES],
        append_images=frames[:-1],
    )

    print(f"wrote {WIN_ASSETS / 'serverlife.ico'} ({', '.join(str(s) for s in ICO_SIZES)}px)")
    print(f"wrote {WIN_ASSETS / 'serverlife-source-1024.png'}")
    print(f"wrote {MAC_ASSETS / 'source-icon-1024.png'}")


if __name__ == "__main__":
    main()
