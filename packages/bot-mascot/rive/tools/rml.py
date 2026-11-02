import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = json.load(open(os.path.join(HERE, "logo_paths.json")))


class Ids:
    def __init__(self, start=10):
        self.n = start

    def __call__(self):
        self.n += 1
        return f"0:{self.n}"


def f(v):
    return f"{v:.3f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def attrs(**kw):
    out = []
    for k, v in kw.items():
        if v is None:
            continue
        if isinstance(v, bool):
            v = "true" if v else "false"
        out.append(f'{k}="{f(v)}"')
    return " ".join(out)


def el(tag, children=None, **kw):
    a = attrs(**kw)
    if not children:
        return f"<{tag} {a}/>"
    body = "\n".join(c for c in children if c)
    body = "\n".join("    " + line for line in body.split("\n"))
    return f"<{tag} {a}>\n{body}\n</{tag}>"


def solid(color):
    return el("SolidColor", colorValue=color, name="Color")


def linear(x1, y1, x2, y2, stops):
    return el("LinearGradient", [el("GradientStop", colorValue=c, position=p) for p, c in stops],
              startX=x1, startY=y1, endX=x2, endY=y2, name="Gradient")


def radial(cx, cy, r, stops, ex=None, ey=None):
    return el("RadialGradient", [el("GradientStop", colorValue=c, position=p) for p, c in stops],
              startX=cx, startY=cy, endX=cx + r if ex is None else ex, endY=cy if ey is None else ey,
              name="Gradient")


def fill(paint, name="Fill", feather=None, **kw):
    kids = [paint]
    if feather:
        kids.append(el("Feather", name="Feather", **feather))
        kw.setdefault("fillRule", "clockwise")
    return el("Fill", kids, name=name, **kw)


def stroke(paint, thickness, name="Stroke", feather=None, cap="round", join="round", **kw):
    kids = [paint]
    if feather:
        kids.append(el("Feather", name="Feather", **feather))
    return el("Stroke", kids, thickness=thickness, cap=cap, join=join, name=name, **kw)


def logo_path(key, inflate=0.0, sx=1.0, sy=1.0, ox=0.0, oy=0.0, name=None, id=None):
    d = LOGO[key]
    cw = d["cw"]
    vs = []
    for v in d["verts"]:
        r = v["rot"]
        nx, ny = math.sin(r), -math.cos(r)
        if not cw:
            nx, ny = -nx, -ny
        x = (v["x"] + nx * inflate) * sx + ox
        y = (v["y"] + ny * inflate) * sy + oy

        hx, hy = math.cos(r) * sx, math.sin(r) * sy
        k = math.hypot(hx, hy)
        vs.append(el("CubicAsymmetricVertex", x=round(x, 2), y=round(y, 2),
                     rotation=round(math.atan2(hy, hx), 4),
                     inDistance=round(v["din"] * k, 2), outDistance=round(v["dout"] * k, 2)))
    return el("PointsPath", vs, isClosed=True, isClockwise=cw, name=name or key, id=id)


def open_path(points, name="Path"):
    vs = []
    for p in points:
        if p[0] == "s":
            vs.append(el("StraightVertex", x=p[1], y=p[2], radius=p[3] if len(p) > 3 else None))
        else:
            vs.append(el("CubicMirroredVertex", x=p[1], y=p[2], rotation=p[3], distance=p[4]))
    return el("PointsPath", vs, isClosed=False, name=name)


def closed_path(points, name="Path", cw=True):
    vs = []
    for p in points:
        if p[0] == "s":
            vs.append(el("StraightVertex", x=p[1], y=p[2], radius=p[3] if len(p) > 3 else None))
        elif p[0] == "c":
            vs.append(el("CubicMirroredVertex", x=p[1], y=p[2], rotation=p[3], distance=p[4]))
        else:
            vs.append(el("CubicDetachedVertex", x=p[1], y=p[2], inRotation=p[3], inDistance=p[4],
                         outRotation=p[5], outDistance=p[6]))
    return el("PointsPath", vs, isClosed=True, isClockwise=cw, name=name)


def ellipse(w, h, name="Path"):
    return el("Ellipse", width=w, height=h, originX=0.5, originY=0.5, name=name)


def rect(w, h, r=0, name="Path"):
    return el("Rectangle", width=w, height=h, cornerRadiusTL=r, originX=0.5, originY=0.5, name=name)


def shape(name, kids, id=None, **kw):
    return el("Shape", kids, name=name, id=id, **kw)


def node(name, kids, id=None, **kw):
    return el("Node", kids, name=name, id=id, **kw)
