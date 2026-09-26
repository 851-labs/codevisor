# The text test card: 1400×900 px, shown 1:1 on tuftlord (700×280 CSS px at 2×).
# Magenta corner markers let the analysis find the card in any screenshot.
from PIL import Image, ImageDraw, ImageFont
W, H = 1400, 560
im = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(im)
M = 24
for x, y in [(0, 0), (W - M, 0), (0, H - M), (W - M, H - M)]:
    d.rectangle([x, y, x + M - 1, y + M - 1], fill=(255, 0, 255))
def font(size):
    for path in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
        try: return ImageFont.truetype(path, size)
        except OSError: pass
    return ImageFont.load_default()
text = "The quick brown fox jumps over the lazy dog 0123456789 {}[]()<>"
y = 40
for size in (14, 18, 22, 26):  # device pixels: 7–13 pt text at 2×
    d.text((40, y), text, fill="black", font=font(size)); y += size + 14
# Coloured text on coloured backgrounds: where 4:2:0 smears chroma.
pairs = [((220, 0, 0), (0, 0, 200)), ((0, 160, 0), (200, 0, 160)), ((255, 255, 255), (200, 0, 0)), ((0, 0, 0), (0, 150, 255))]
for fg, bg in pairs:
    d.rectangle([40, y, W - 40, y + 44], fill=bg)
    d.text((52, y + 10), text, fill=fg, font=font(22)); y += 56
# 1-px lines, alternating, and a checker patch.
for i in range(0, 200, 2):
    d.line([(40 + i, y + 10), (40 + i, y + 110)], fill="black")
for i in range(0, 100, 2):
    d.line([(280, y + 10 + i), (480, y + 10 + i)], fill=(0, 0, 200))
for i in range(0, 100, 2):
    for j in range(0, 200, 2):
        d.point((540 + j + (i // 2 % 2), y + 10 + i), fill="black")
im.save("/tmp/sharp/card.png")
open("/tmp/sharp/card.html", "w").write('<!doctype html><html><body style="margin:0;background:#fff"><img src="card.png" style="width:700px;height:280px;display:block;margin:220px auto;image-rendering:pixelated"></body></html>')
print("card", W, H, "rows end at", y + 120)
