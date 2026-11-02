import math
import re


def cubic(p0, p1, p2, p3, t):
    m = ((1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3)
    return (sum(w * p[0] for w, p in zip(m, (p0, p1, p2, p3))), sum(w * p[1] for w, p in zip(m, (p0, p1, p2, p3))))


def svg_contour(d):
    toks = re.findall(r"[MLCZ]|-?\d+(?:\.\d+)?", d)
    pts, i, cur, start = [], 0, None, None
    while i < len(toks):
        c = toks[i]; i += 1
        if c == "M":
            cur = (float(toks[i]), float(toks[i + 1])); i += 2; start = cur
        elif c == "L":
            nxt = (float(toks[i]), float(toks[i + 1])); i += 2
            for k in range(12):
                pts.append((cur[0] + (nxt[0] - cur[0]) * k / 12, cur[1] + (nxt[1] - cur[1]) * k / 12))
            cur = nxt
        elif c == "C":
            p = [(float(toks[i + 2 * j]), float(toks[i + 2 * j + 1])) for j in range(3)]; i += 6
            for k in range(20):
                pts.append(cubic(cur, p[0], p[1], p[2], k / 20))
            cur = p[2]
        elif c == "Z":
            if cur != start:
                for k in range(12):
                    pts.append((cur[0] + (start[0] - cur[0]) * k / 12, cur[1] + (start[1] - cur[1]) * k / 12))
    return pts


def resample(seg, n):
    cum = [0.0]
    for a, b in zip(seg, seg[1:]):
        cum.append(cum[-1] + math.dist(a, b))
    total, out, j = cum[-1], [], 0
    for k in range(n):
        s = total * k / n
        while j < len(cum) - 2 and cum[j + 1] < s:
            j += 1
        f = (s - cum[j]) / max(cum[j + 1] - cum[j], 1e-9)
        out.append((seg[j][0] + (seg[j + 1][0] - seg[j][0]) * f, seg[j][1] + (seg[j + 1][1] - seg[j][1]) * f))
    return out


def rig_points(body_d, n=360):
    dense = svg_contour(body_d)
    return resample(dense + dense[:1], n)


HIP = {"L": [196.0, 336.0], "R": [304.0, 336.0]}
WAIST = [250.0, 330.0]
CENTRE = [250.0, 300.0]
