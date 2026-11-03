import math

from rml import solid, stroke, open_path, shape

INK_SOFT = "FF2B2C36"
GROUND = 412


def arc_eye(name, x, y, w, h, t, ink=INK_SOFT):
    e = h / 2
    return shape(name, [
        open_path([("s", -w / 2, e), ("c", 0, -e, 0, w * 0.3), ("s", w / 2, e)]),
        stroke(solid(ink), t),
    ], x=x, y=y)


def smile(name, x, y, w, h, t, ink=INK_SOFT, frown=False):
    d = -h if frown else h
    return shape(name, [
        open_path([("s", -w / 2, 0), ("c", 0, d, 0, w * 0.28), ("s", w / 2, 0)]),
        stroke(solid(ink), t),
    ], x=x, y=y)


def arch(xr, xl, top, foot=GROUND, side=12):
    cx = (xr + xl) / 2
    return [("s", xr + 6, foot, 8), ("c", xr, foot - side * 3.2, -math.pi / 2, side),
            ("c", cx, top, math.pi, (xr - xl) * 0.32), ("c", xl, foot - side * 3.2, math.pi / 2, side),
            ("s", xl - 6, foot, 8)]
