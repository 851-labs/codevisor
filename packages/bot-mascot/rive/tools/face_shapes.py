import math

from rml import el, solid, linear, fill, stroke, open_path, closed_path, shape

INK_SOFT = "FF2B2C36"
GROUND = 412


def arc_eye(name, x, y, w, h, t, ink=INK_SOFT, up=True):
    e = h / 2 if up else -h / 2
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


def tear(name, x, y, s, color="FF7DB7FF"):
    return shape(name, [closed_path([("s", 0, -s * 1.1, 2),
                                     ("c", s * 0.62, s * 0.25, 1.5708, s * 0.32),
                                     ("c", 0, s * 0.85, 3.14159, s * 0.36),
                                     ("c", -s * 0.62, s * 0.25, -1.5708, s * 0.32)]),
                        fill(linear(0, -s, 0, s, [(0, "FFBFE0FF"), (1, color)]))], x=x, y=y)


def arch(xr, xl, top, foot=GROUND, side=12):
    cx = (xr + xl) / 2
    return [("s", xr + 6, foot, 8), ("c", xr, foot - side * 3.2, -math.pi / 2, side),
            ("c", cx, top, math.pi, (xr - xl) * 0.32), ("c", xl, foot - side * 3.2, math.pi / 2, side),
            ("s", xl - 6, foot, 8)]
