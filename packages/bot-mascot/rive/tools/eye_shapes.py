import math

from rml import LOGO

N = 96
ANG = [2 * math.pi * i / N for i in range(N)]
BASELINE_S = 0.66


def hole_radii():
    vs = LOGO["hole"]["verts"]
    pts = []
    for i in range(len(vs)):
        a, b = vs[i], vs[(i + 1) % len(vs)]
        p0 = (a["x"], a["y"])
        p1 = (a["x"] + math.cos(a["rot"]) * a["dout"], a["y"] + math.sin(a["rot"]) * a["dout"])
        p2 = (b["x"] - math.cos(b["rot"]) * b["din"], b["y"] - math.sin(b["rot"]) * b["din"])
        p3 = (b["x"], b["y"])
        for k in range(40):
            t = k / 40
            m = [(1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3]
            pts.append((sum(w * p[0] for w, p in zip(m, (p0, p1, p2, p3))),
                        sum(w * p[1] for w, p in zip(m, (p0, p1, p2, p3)))))
    A = cx = cy = 0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
        c = x0 * y1 - x1 * y0
        A += c; cx += (x0 + x1) * c; cy += (y0 + y1) * c
    cx, cy = cx / (3 * A), cy / (3 * A)
    polar = sorted((math.atan2(y - cy, x - cx) % (2 * math.pi), math.hypot(x - cx, y - cy)) for x, y in pts)
    polar = [(polar[-1][0] - 2 * math.pi, polar[-1][1])] + polar + [(polar[0][0] + 2 * math.pi, polar[0][1])]
    out = []
    for th in ANG:
        j = next(k for k in range(1, len(polar)) if polar[k][0] >= th)
        (t0, r0), (t1, r1) = polar[j - 1], polar[j]
        out.append(r0 + (r1 - r0) * (th - t0) / max(t1 - t0, 1e-9))
    return out


def sample(fn):
    return [fn(th) for th in ANG]


def at(r, th):
    x = (th % (2 * math.pi)) / (2 * math.pi) * N
    i = int(x) % N
    f = x - int(x)
    return r[i] * (1 - f) + r[(i + 1) % N] * f


def mirror(r):
    return sample(lambda th: at(r, math.pi - th))


def rotate(r, phi):
    return sample(lambda th: at(r, th - phi))


def area(r):
    return sum(0.5 * x * x for x in r) * (2 * math.pi / N)


def fit(r, target):
    k = math.sqrt(target / area(r))
    return [x * k for x in r]


def lerp(a, b, t):
    return [x + (y - x) * t for x, y in zip(a, b)]


def width_of(r):
    return max(math.cos(th) * x for th, x in zip(ANG, r)) - min(math.cos(th) * x for th, x in zip(ANG, r))


class EyeShapes:
    def __init__(self, scale):
        self.hole = [x * scale for x in hole_radii()]
        self.target = area(self.hole)
        self.directions = {"right": self.hole, "left": mirror(self.hole),
                           "up": rotate(self.hole, -math.pi / 2), "down": rotate(self.hole, math.pi / 2)}

    def softened_hole(self):
        return fit(lerp(self.hole, mirror(self.hole), 0.5), self.target)
