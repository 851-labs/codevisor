import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rml import LOGO
import bot_mascot as BOT
import body_points as RIG
from eye_shapes import EyeShapes, BASELINE_S, N, width_of
from palettes import PALETTES

PACKAGE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(PACKAGE, "src", "data", "bot-mascot-data.json")
FACE_RADIUS = 88
FACE_THETA = math.radians(21)
CHEEK_PHI, CHEEK_Y = math.radians(37), 304


def fmt(p):
    return f"{p[0]:.2f} {p[1]:.2f}".replace(".00", "")


def add(a, b, k=1.0):
    return (a[0] + b[0] * k, a[1] + b[1] * k)


def unit(v):
    n = math.hypot(*v)
    return (v[0] / n, v[1] / n), n


def ideal_distance(to_prev, to_next, radius):
    cross = to_prev[0] * to_next[1] - to_prev[1] * to_next[0]
    dot = to_prev[0] * to_next[0] + to_prev[1] * to_next[1]
    angle = abs(math.atan2(cross, dot))
    k = 1 + math.cos(angle) if angle < math.pi / 2 else 2 - math.sin(angle)
    return min(radius, (4 / 3) * math.tan(math.pi / (2 * ((2 * math.pi) / angle))) * radius * k)


def rive_path(verts):
    pts = []
    for v in verts:
        p = (v[1], v[2])
        if v[0] == "c":
            d = (math.cos(v[3]) * v[4], math.sin(v[3]) * v[4])
            pts.append(dict(p=p, cin=add(p, d, -1), cout=add(p, d), r=0))
        else:
            pts.append(dict(p=p, cin=None, cout=None, r=v[3] if len(v) > 3 else 0))
    n = len(pts)


    segs = []
    for i, v in enumerate(pts):
        prev, nxt = pts[i - 1], pts[(i + 1) % n]
        if v["cin"] is not None:
            segs.append(dict(arrive=v["p"], arrive_ctrl=v["cin"], corner=None, leave=v["p"], leave_ctrl=v["cout"]))
            continue
        if v["r"] > 0:
            to_prev, lp = unit(add(prev["cout"] or prev["p"], v["p"], -1))
            to_next, ln = unit(add(nxt["cin"] or nxt["p"], v["p"], -1))
            r = min(lp / 2, ln / 2, v["r"])
            ideal = ideal_distance(to_prev, to_next, r)
            start, end = add(v["p"], to_prev, r), add(v["p"], to_next, r)
            corner = (add(v["p"], to_prev, r - ideal), add(v["p"], to_next, r - ideal), end)
            segs.append(dict(arrive=start, arrive_ctrl=start, corner=corner, leave=end, leave_ctrl=None))
        else:
            segs.append(dict(arrive=v["p"], arrive_ctrl=v["p"], corner=None, leave=v["p"], leave_ctrl=None))
    d = [f"M{fmt(segs[0]['leave'] if segs[0]['corner'] else segs[0]['arrive'])}"]
    order = list(range(1, n)) + [0]
    prev = segs[0]
    for i in order:
        s = segs[i]
        if prev["leave_ctrl"] is None and pts[i]["cin"] is None:
            d.append(f"L{fmt(s['arrive'])}")
        else:
            c1 = prev["leave_ctrl"] or prev["leave"]
            d.append(f"C{fmt(c1)} {fmt(s['arrive_ctrl'])} {fmt(s['arrive'])}")
        if s["corner"] and i != 0:
            d.append("C" + " ".join(fmt(q) for q in s["corner"]))
        prev = s
    if segs[0]["corner"]:
        d.append("C" + " ".join(fmt(q) for q in segs[0]["corner"]))
    return "".join(d) + "Z"


def logo_path_d(key, cx, cy):
    vs = LOGO[key]["verts"]
    pt = lambda v: (v["x"] - cx, v["y"] - cy)
    d = [f"M{fmt(pt(vs[0]))}"]
    for i in range(len(vs)):
        a, b = vs[i], vs[(i + 1) % len(vs)]
        c1 = add(pt(a), (math.cos(a["rot"]), math.sin(a["rot"])), a["dout"])
        c2 = add(pt(b), (math.cos(b["rot"]), math.sin(b["rot"])), -b["din"])
        d.append(f"C{fmt(c1)} {fmt(c2)} {fmt(pt(b))}")
    return "".join(d) + "Z"


def cyclops_data():
    r = lambda a: [round(float(v), 3) for v in a]
    eyes = EyeShapes(BASELINE_S)
    centre = eyes.softened_hole()
    dirs = eyes.directions
    return dict(
        n=N, right=r(dirs["right"]), left=r(dirs["left"]), up=r(dirs["up"]), down=r(dirs["down"]),
        centre=r(centre), width=round(width_of(centre), 3), y=BOT.EYE_Y, radius=FACE_RADIUS,
        theta=round(FACE_THETA, 6), nudge=[3.84 * BASELINE_S, -1.18 * BASELINE_S],
        cheek=dict(phi=round(CHEEK_PHI, 6), y=CHEEK_Y, rx=20, ry=9),
        glint=dict(light=-45, parallax=0.3, main=0.125, along=0.24, bounce=0.05, bounce_along=0.25),
    )


def main():
    body = rive_path(BOT.body_vertices())
    data = dict(
        body=body,
        hole=logo_path_d("hole", 218, 134),
        mark=dict(left=logo_path_d("left", 0, 0), body=logo_path_d("body", 0, 0), hole=logo_path_d("hole", 0, 0)),
        eye=dict(x=BOT.EYE_X, y=BOT.EYE_Y, s=BOT.EYE_S),
        feet=dict(x=BOT.FEET_X, y=BOT.FEET_Y),
        palettes={k: {**v, "body": [[pos, c] for pos, c in v["body"]]} for k, v in PALETTES.items()},
        cyclops=cyclops_data(),
        rig=dict(points=[[round(x, 2), round(y, 2)] for x, y in RIG.rig_points(body)],
                 hip=RIG.HIP, waist=RIG.WAIST, centre=RIG.CENTRE),
    )
    with open(DATA, "w") as f:
        f.write(json.dumps(data, indent=2) + "\n")
    print(DATA)


if __name__ == "__main__":
    main()
