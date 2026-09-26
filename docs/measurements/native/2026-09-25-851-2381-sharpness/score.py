# usage: score.py TRUTH.png VIEWER.png [label] — crop the card by its magenta markers in both
# images and score the viewer against the truth, region by region.
import sys, numpy as np
from PIL import Image
W, H = 1400, 560
REGIONS = {"black text": (30, 172), "coloured text": (176, 390), "1-px lines": (408, 512)}

def srgb(path):
    """The image in sRGB: screenshots carry the display's profile (Display P3), the card is sRGB."""
    im = Image.open(path)
    icc = im.info.get("icc_profile")
    im = im.convert("RGB")
    if icc:
        import io
        from PIL import ImageCms
        im = ImageCms.profileToProfile(im, ImageCms.ImageCmsProfile(io.BytesIO(icc)), ImageCms.createProfile("sRGB"), outputMode="RGB")
    return im

def crop(path):
    source = srgb(path)
    a = np.asarray(source).astype(np.int32)
    m = (a[..., 0] > 200) & (a[..., 1] < 90) & (a[..., 2] > 200)
    ys, xs = np.nonzero(m)
    if len(xs) < 100: raise SystemExit(f"{path}: markers not found")
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    im = source.crop((x0, y0, x1, y1))
    size = im.size
    if size != (W, H): im = im.resize((W, H), Image.BICUBIC)
    return np.asarray(im).astype(np.float64), size

def ycbcr(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return y, (b - y) / 1.8556, (r - y) / 1.5748

def ssim(x, y):
    from numpy.lib.stride_tricks import sliding_window_view as sw
    k = 7; C1, C2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    X, Y = sw(x, (k, k)), sw(y, (k, k))
    mx, my = X.mean((-1, -2)), Y.mean((-1, -2))
    vx, vy = X.var((-1, -2)), Y.var((-1, -2))
    cxy = ((X - mx[..., None, None]) * (Y - my[..., None, None])).mean((-1, -2))
    return float((((2 * mx * my + C1) * (2 * cxy + C2)) / ((mx**2 + my**2 + C1) * (vx + vy + C2))).mean())

def subsample420(a):
    y, cb, cr = ycbcr(a)
    def down_up(c):
        h, w = c.shape; c2 = c[: h // 2 * 2, : w // 2 * 2].reshape(h // 2, 2, w // 2, 2).mean((1, 3))
        return np.repeat(np.repeat(c2, 2, 0), 2, 1)
    cb, cr = down_up(cb), down_up(cr); y = y[: cb.shape[0], : cb.shape[1]]
    r = y + 1.5748 * cr; b = y + 1.8556 * cb; g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
    return np.clip(np.stack([r, g, b], -1), 0, 255)

def score(truth, other):
    ty, tcb, tcr = ycbcr(truth); oy, ocb, ocr = ycbcr(other)
    out = {}
    for name, (a, b) in REGIONS.items():
        s = slice(a, b)
        out[name] = (ssim(ty[s, 20:W - 20], oy[s, 20:W - 20]),
                     float(np.abs(tcb[s] - ocb[s]).mean() + np.abs(tcr[s] - ocr[s]).mean()))
    return out

truth, tsize = crop(sys.argv[1])
viewer, vsize = crop(sys.argv[2])
label = sys.argv[3] if len(sys.argv) > 3 else "viewer"
rows = [(label + f" (card {vsize[0]}×{vsize[1]})", score(truth, viewer)), ("truth as 4:2:0 (reference)", score(truth, subsample420(truth)))]
print(f"truth card {tsize[0]}×{tsize[1]}")
print(f"{'':34}" + "".join(f"{n:>26}" for n in REGIONS))
for name, r in rows:
    print(f"{name:34}" + "".join(f"   SSIM {r[n][0]:.4f} ΔC {r[n][1]:5.2f}" for n in REGIONS))
