import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rml import Ids, el, solid, linear, fill, stroke, logo_path, open_path, ellipse, rect, shape, node
import face_shapes as D
from face_shapes import arch
from rive_motion import keyframes, blink, cycle, smooth, pack, enum_cond, trigger_cond, bool_cond
from palettes import PALETTES

SCENE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bot-mascot", "scene.rml")
P = dict(PALETTES["classic"])
W = H = 500
FEET_X, FEET_Y = 250, 412
BASE_LEN = 110
TOP_LEN = 116
HALF_PI = math.pi / 2
EYE_X, EYE_Y, EYE_S = 282, 270, 0.66

ids = Ids(100)

REG = {}


def reg(key, oid, prop, rest, kind="double"):
    REG[key] = (oid, prop, kind, rest)


def body_vertices():
    return [
        ("s", 162, 186, 64), ("s", 338, 186, 64),

        ("c", 338, 322, HALF_PI, 10),
        ("s", 338, FEET_Y, 20),
        *arch(282, 218, 350, foot=FEET_Y, side=10),
        ("s", 162, FEET_Y, 20),
        ("c", 162, 322, -HALF_PI, 10),
    ]


def top_weight(y):
    return smooth((380 - y) / 170)


def bone_world(along):
    return dict(xx=0, xy=-1, yx=1, yy=0, tx=FEET_X, ty=FEET_Y - along)


def skinned_body(base_id, top_id):
    verts = []
    for v in body_vertices():
        t = round(255 * top_weight(v[2]))
        ws = [(1, 255 - t), (2, t)]
        idx, val = pack([w for w in ws if w[1] > 0])
        if v[0] == "s":
            verts.append(el("StraightVertex", [el("Weight", values=val, indices=idx)],
                            x=v[1], y=v[2], radius=v[3] if len(v) > 3 else None))
        else:
            verts.append(el("CubicMirroredVertex", [el("CubicWeight", values=val, indices=idx, inValues=val,
                                                        inIndices=idx, outValues=val, outIndices=idx)],
                            x=v[1], y=v[2], rotation=round(v[3], 5), distance=v[4]))
    skin = el("Skin", [el("Tendon", boneId=base_id, name="Base", **bone_world(0)),
                       el("Tendon", boneId=top_id, name="Top", **bone_world(BASE_LEN))],
              xx=1, xy=0, yx=0, yy=1, tx=0, ty=0, name="Skin")
    return el("PointsPath", [*verts, skin], isClosed=True, isClockwise=True, name="Body Path")


def anchor(name, kids, bone_along):
    return node(name, kids, x=FEET_Y - bone_along, y=-FEET_X, rotation=HALF_PI)


EYES, MOUTHS = {}, {}


def build_face():
    eye, solo, open_, happy, closed, glints = ids(), ids(), ids(), ids(), ids(), ids()
    EYES.update(open=open_, happy=happy, closed=closed)
    reg("eye.x", eye, "x", EYE_X)
    reg("eye.y", eye, "y", EYE_Y)
    reg("eye.state", solo, "activeComponentId", open_, "id")
    reg("eye.sx", open_, "scaleX", 1)
    reg("eye.sy", open_, "scaleY", 1)
    reg("glints.x", glints, "x", 0)
    reg("glints.y", glints, "y", 0)
    s = EYE_S
    eye_xml = node("Eye", [el("Solo", [
        node("Open", [
            node("Glints", [
                shape("Glint", [ellipse(28 * s, 28 * s), fill(solid(P["glint"]))], x=22 * s, y=-22 * s),
                shape("Glint 2", [ellipse(12 * s, 12 * s), fill(solid(P["glint"]))], x=-18 * s, y=18 * s),
            ], id=glints),
            shape("Hole", [logo_path("hole", sx=s, sy=s, ox=-218 * s, oy=-134 * s), fill(solid(P["eye"]))]),
        ], id=open_),
        node("Happy", [D.arc_eye("Arc", 0, -2, 62, 28, 13, ink=P["eye"])], id=happy),
        node("Closed", [D.arc_eye("Arc", 0, 6, 56, 20, 12, ink=P["eye"], up=False)], id=closed),
    ], activeComponentId=open_, name="Eye State", id=solo)], x=EYE_X, y=EYE_Y, id=eye)

    brow = ids()
    reg("brow.opacity", brow, "opacity", 0)
    reg("brow.rot", brow, "rotation", 0)
    reg("brow.y", brow, "y", EYE_Y - 42)
    brow_xml = shape("Brow", [open_path([("s", -24, 2), ("c", 0, -4, 0, 12), ("s", 24, 2)]),
                              stroke(solid(P["eye"]), 8)], x=EYE_X, y=EYE_Y - 42, opacity=0, id=brow)

    msolo = ids()
    m = {k: ids() for k in ("none", "smile", "oh")}
    MOUTHS.update(m)
    reg("mouth.state", msolo, "activeComponentId", m["none"], "id")
    mouth = el("Solo", [
        node("None", [], id=m["none"]),
        node("Smile", [D.smile("Line", 298, 316, 24, 10, 8, ink=P["eye"])], id=m["smile"]),
        node("Oh", [shape("Shape", [ellipse(14, 18), fill(solid(P["eye"]))], x=290, y=334)], id=m["oh"]),
    ], activeComponentId=m["none"], name="Mouth State", id=msolo)

    cheek = ids()
    reg("cheek.opacity", cheek, "opacity", 1)
    reg("cheek.sx", cheek, "scaleX", 1)
    cheek_xml = shape("Cheek", [ellipse(40, 18), fill(solid(P["cheek"]), feather=dict(strength=6))],
                      x=226, y=304, id=cheek)

    tear = ids()
    reg("tear.y", tear, "y", 296)
    reg("tear.opacity", tear, "opacity", 0)
    reg("tear.sy", tear, "scaleY", 1)
    tear_xml = D.tear("Tear", 258, 296, 12).replace('<Shape name="Tear"', f'<Shape name="Tear" id="{tear}" opacity="0"', 1)
    return [tear_xml, brow_xml, eye_xml, mouth, cheek_xml]


def outlined(path, t=4, ink_t=None):
    return [path, stroke(solid(P["outline"]), ink_t or t + 5), stroke(solid(P["fx"]), t)]


def build_fx():
    kids = []

    def add(key, name, kids_, x, y, rest_scale=1.0, extra=()):
        oid = ids()
        reg(f"{key}.opacity", oid, "opacity", 0)
        reg(f"{key}.sx", oid, "scaleX", rest_scale)
        reg(f"{key}.sy", oid, "scaleY", rest_scale)
        for p, rest in extra:
            reg(f"{key}.{p}", oid, p, rest)
        kids.append(shape(name, kids_, x=x, y=y, opacity=0, scaleX=rest_scale, scaleY=rest_scale, id=oid))

    for i, (x, y, sz) in enumerate([(128, 196, 34), (370, 150, 24), (392, 226, 18)]):
        add(f"sparkle{i}", f"Sparkle {i + 1}",
            [el("Star", width=sz, height=sz, points=4, innerRadius=0.36, name="Path"),
             stroke(solid(P["outline"]), 4), fill(solid(P["fx"]))], x, y)
    for i, (x, y, d) in enumerate([(216, 160, 14), (192, 132, 20), (156, 100, 28)]):
        add(f"dot{i}", f"Thought {i + 1}", [ellipse(d, d), stroke(solid(P["outline"]), 4), fill(solid(P["fx"]))], x, y)
    for i in range(3):
        h = 13
        add(f"z{i}", f"Z {i + 1}", outlined(open_path([("s", -h, -h), ("s", h, -h), ("s", -h, h), ("s", h, h)]), 4),
            330, 190, 0.6, extra=(("x", 330), ("y", 190)))
    for i, (x, y, dx, dy) in enumerate([(352, 170, 8, -20), (370, 196, 22, -8)]):
        add(f"pop{i}", f"Pop {i + 1}", [open_path([("s", 0, 0), ("s", dx, dy)]), stroke(solid(P["eye"]), 7)], x, y)
    return node("FX", kids)


def build_character():
    char, base, top = ids(), ids(), ids()
    reg("char.y", char, "y", FEET_Y)
    reg("char.rot", char, "rotation", 0)
    reg("base.sx", base, "scaleX", 1)
    reg("base.sy", base, "scaleY", 1)
    reg("top.rot", top, "rotation", 0)
    reg("top.sx", top, "scaleX", 1)
    reg("top.sy", top, "scaleY", 1)
    face = anchor("Face Anchor", build_face(), BASE_LEN)
    top_bone = el("Bone", [face], length=TOP_LEN, name="Top", id=top)
    base_bone = el("RootBone", [top_bone], x=0, y=0, length=BASE_LEN, rotation=-HALF_PI, name="Base", id=base)
    body = shape("Body", [
        skinned_body(base, top),
        stroke(solid(P["outline"]), 16, name="Ink Rim"),
        fill(linear(0, 186, 0, FEET_Y, P["body"])),
        fill(solid(P["shade"]), name="Core Shade", feather=dict(strength=18, inner=True, offsetX=-6, offsetY=-10)),
    ], x=-FEET_X, y=-FEET_Y)
    return node("Bot Mascot", [base_bone, body], x=FEET_X, y=FEET_Y, id=char)


def build_shadow():
    toggle, inner = ids(), ids()
    reg("shadow.sx", inner, "scaleX", 1)
    reg("shadow.opacity", inner, "opacity", 1)
    SHADOW[0] = toggle
    return node("Ground Shadow", [
        shape("Shadow", [ellipse(196, 22), fill(solid(P["shadow"]), feather=dict(strength=9))], id=inner),
    ], x=FEET_X + 4, y=FEET_Y + 6, id=toggle)


SHADOW = [None]


def animation(name, duration, tracks, loop="loop", fill_rest=True):
    keyed = dict(tracks)
    if fill_rest:
        for k, (_, _, _, rest) in REG.items():
            if not k.startswith("toggle."):
                keyed.setdefault(k, [(0, rest, "hold")])
    by_obj = {}
    for k, keys in keyed.items():
        oid, prop, kind, _ = REG[k]
        by_obj.setdefault(oid, []).append(el("KeyedProperty", keyframes(kind, keys), property=prop))
    objs = [el("KeyedObject", props, objectId=oid) for oid, props in by_obj.items()]
    aid = ids()
    return aid, el("LinearAnimation", objs, loopValue=loop, fps=60, duration=duration, name=name, id=aid)


def both(key, keys):
    return {f"{key}.sx": keys, f"{key}.sy": keys}


def moods():
    Y = FEET_Y
    A = {}

    A["idle"] = animation("Idle", 300, {
        "base.sx": cycle([0, 75, 150, 225, 300], [1, 1.03, 1, 1.03, 1]),
        "base.sy": cycle([0, 75, 150, 225, 300], [1, 0.985, 1, 0.985, 1]),
        "top.rot": cycle([0, 150, 300], [-0.015, 0.02, -0.015]),
        "eye.sy": [(0, 1, "hold"), *blink(110), *blink(250), *blink(264), (300, 1, "hold")],
        "eye.x": [(0, EYE_X, "hold"), (160, EYE_X, "o"), (170, EYE_X - 7), (214, EYE_X - 7, "o"), (226, EYE_X), (300, EYE_X, "hold")],
        "glints.x": [(0, 0, "hold"), (160, 0, "o"), (170, -6), (214, -6, "o"), (226, 0), (300, 0, "hold")],
    })

    A["thinking"] = animation("Thinking", 240, {
        "top.rot": cycle([0, 120, 240], [-0.06, -0.075, -0.06]),
        "base.sx": cycle([0, 120, 240], [1.01, 1.025, 1.01]),
        "eye.y": [(0, EYE_Y - 5, "hold")],
        "eye.x": cycle([0, 100, 120, 220, 240], [EYE_X + 2, EYE_X + 2, EYE_X - 3, EYE_X - 3, EYE_X + 2]),
        "glints.x": cycle([0, 100, 120, 220, 240], [3, 3, -5, -5, 3]),
        "glints.y": [(0, -5, "hold")],
        "eye.sy": [(0, 0.82, "hold"), (196, 0.82), (201, 0.08, "o"), (206, 0.82), (240, 0.82, "hold")],
        "brow.opacity": [(0, 1, "hold")],
        "brow.rot": [(0, -0.16, "hold")],
        "brow.y": cycle([0, 120, 240], [EYE_Y - 46, EYE_Y - 50, EYE_Y - 46]),
        "cheek.opacity": [(0, 0.5, "hold")],
        **{k: v for i in range(3) for k, v in {
            f"dot{i}.opacity": [(0, 0, "hold"), (20 + i * 30, 0), (30 + i * 30, 1), (190, 1), (215, 0), (240, 0, "hold")],
            **both(f"dot{i}", [(0, 0.3, "hold"), (20 + i * 30, 0.3, "o"), (34 + i * 30, 1.15), (42 + i * 30, 1), (240, 1, "hold")]),
        }.items()},
    })

    hop = 60
    A["happy"] = animation("Happy", hop, {
        "char.y": [(0, Y, "o"), (8, Y - 8, "o"), (28, Y - 40, "i"), (46, Y - 4, "linear"), (50, Y, "o"), (hop, Y)],
        "base.sx": [(0, 0.88, "o"), (8, 1.1, "io"), (28, 1.02, "i"), (46, 1.08, "linear"), (50, 0.86, "o"), (hop, 0.88)],
        "base.sy": [(0, 1.1, "o"), (8, 0.94, "io"), (28, 0.99, "i"), (46, 0.95, "linear"), (50, 1.12, "o"), (hop, 1.1)],
        "top.rot": [(0, 0.04), (14, -0.05), (34, 0.03), (50, 0.06), (hop, 0.04)],
        "shadow.sx": [(0, 1.06, "o"), (8, 0.95, "io"), (28, 0.7, "i"), (46, 0.97, "linear"), (50, 1.08), (hop, 1.06)],
        "shadow.opacity": [(0, 1), (28, 0.45, "i"), (50, 1), (hop, 1)],
        "eye.state": [(0, EYES["happy"])],
        "mouth.state": [(0, MOUTHS["smile"])],
        "cheek.sx": [(0, 1.15, "hold")],
        **{f"sparkle{i}.opacity": [(0, 1, "hold")] for i in range(3)},
        **{k: v for i, (a, b) in enumerate([(1, 0.55), (0.5, 1.1), (0.8, 0.45)])
           for k, v in both(f"sparkle{i}", [(0, a), (30, b), (60, a)]).items()},
    })

    A["sad"] = animation("Sad", 240, {
        "top.rot": cycle([0, 120, 240], [0.09, 0.12, 0.09]),
        "base.sx": cycle([0, 120, 240], [0.93, 0.95, 0.93]),
        "base.sy": [(0, 1.05, "hold")],
        "eye.y": [(0, EYE_Y + 8, "hold")],
        "eye.sy": [(0, 0.7, "hold"), (200, 0.7), (206, 0.08, "o"), (212, 0.7), (240, 0.7, "hold")],
        "glints.y": [(0, 4, "hold")],
        "brow.opacity": [(0, 1, "hold")],
        "brow.rot": [(0, -0.32, "hold")],
        "brow.y": [(0, EYE_Y - 26, "hold")],
        "cheek.opacity": [(0, 0.35, "hold")],
        "tear.opacity": [(0, 0, "hold"), (30, 0), (45, 1), (135, 1), (165, 0), (240, 0, "hold")],
        "tear.y": [(0, 292, "hold"), (30, 292, "i"), (175, 336), (240, 336, "hold")],
        "tear.sy": [(0, 0.6, "hold"), (30, 0.6), (60, 1.1), (240, 1.1, "hold")],
    })

    zs = {}
    for i in range(3):
        keys = {"opacity": [], "x": [], "y": [], "sx": [], "sy": []}
        for c in (0, 180):
            t = c + i * 60
            keys["opacity"] += [(t, 0), (t + 20, 1), (t + 90, 0.9), (t + 120, 0)]
            keys["x"] += [(t, 322, "linear"), (t + 120, 382, "hold")]
            keys["y"] += [(t, 196, "o"), (t + 120, 96, "hold")]
            keys["sx"] += [(t, 0.55, "o"), (t + 120, 1.15, "hold")]
            keys["sy"] += [(t, 0.55, "o"), (t + 120, 1.15, "hold")]
        for p, ks in keys.items():
            if ks[0][0] != 0:
                ks.insert(0, (0, REG[f"z{i}.{p}"][3], "hold"))
            zs[f"z{i}.{p}"] = ks
    A["sleeping"] = animation("Sleeping", 360, {
        "base.sx": cycle([0, 90, 180, 270, 360], [0.95, 1.02, 0.95, 1.02, 0.95]),
        "base.sy": cycle([0, 90, 180, 270, 360], [1.03, 0.99, 1.03, 0.99, 1.03]),
        "top.rot": cycle([0, 90, 180, 270, 360], [0.08, 0.05, 0.08, 0.05, 0.08]),
        "shadow.sx": cycle([0, 90, 180, 270, 360], [1.04, 0.98, 1.04, 0.98, 1.04]),
        "eye.state": [(0, EYES["closed"])],
        "cheek.opacity": [(0, 0.75, "hold")],
        **zs,
    })

    A["surprised"] = animation("Surprised", 90, {
        "char.y": [(0, Y, "o"), (8, Y - 22, "i"), (18, Y, "o"), (26, Y), (90, Y, "hold")],
        "base.sx": [(0, 0.86, "o"), (8, 1.12, "io"), (18, 0.94, "o"), (28, 1.06), (40, 1.04), (90, 1.04, "hold")],
        "base.sy": [(0, 1.1, "o"), (8, 0.92, "io"), (18, 1.05, "o"), (28, 0.96), (40, 0.97), (90, 0.97, "hold")],
        "top.rot": [(0, 0), (8, -0.08), (22, -0.03), (26, -0.06), (30, -0.035), (34, -0.055), (40, -0.045), (90, -0.045, "hold")],
        "eye.sx": [(0, 1, "o"), (8, 1.28), (18, 1.18), (90, 1.18, "hold")],
        "eye.sy": [(0, 1, "o"), (8, 1.32), (18, 1.2), (90, 1.2, "hold")],
        "glints.x": [(0, 0, "hold")],
        "mouth.state": [(0, MOUTHS["oh"])],
        "cheek.opacity": [(0, 0.6, "hold")],
        **{f"pop{i}.opacity": [(0, 0, "hold"), (6, 0), (10, 1), (90, 1, "hold")] for i in range(2)},
        **{k: v for i in range(2) for k, v in both(f"pop{i}", [(0, 0.4, "hold"), (6, 0.4, "o"), (14, 1.15), (20, 1), (90, 1, "hold")]).items()},
    }, loop="oneShot")
    return A


def wave_anim():
    Y = FEET_Y
    return animation("Wave", 120, {
        "char.rot": [(0, 0), (10, -0.12), (30, 0.12), (50, -0.12), (70, 0.12), (92, -0.05), (112, 0), (120, 0)],
        "top.rot": [(0, 0), (14, -0.1), (34, 0.1), (54, -0.1), (74, 0.1), (96, -0.03), (114, 0), (120, 0)],
        "char.y": [(0, Y), (20, Y, "o"), (30, Y - 18, "i"), (40, Y, "o"), (60, Y, "o"), (70, Y - 18, "i"), (80, Y), (120, Y)],
        "base.sx": [(0, 1), (18, 0.92, "o"), (28, 1.07), (40, 0.92, "o"), (48, 1), (58, 0.92, "o"), (68, 1.07),
                    (80, 0.92, "o"), (90, 1), (120, 1)],
        "base.sy": [(0, 1), (18, 1.06, "o"), (28, 0.96), (40, 1.06, "o"), (48, 1), (58, 1.06, "o"), (68, 0.96),
                    (80, 1.06, "o"), (90, 1), (120, 1)],
        "eye.state": [(0, EYES["happy"]), (106, EYES["open"])],
        "mouth.state": [(0, MOUTHS["smile"]), (106, MOUTHS["none"])],
        "cheek.sx": [(0, 1.15), (100, 1.15), (120, 1)],
    }, loop="oneShot", fill_rest=False)


MOODS = ["idle", "thinking", "happy", "sad", "sleeping", "surprised"]


def main(out, backdrop=None, palette="classic"):
    P.clear()
    P.update(PALETTES[palette])
    fx = build_fx()
    character = build_character()
    shadow = build_shadow()
    hit = ids()
    hit_area = shape("Hit Area", [rect(200, 250), fill(solid("00000000"))], x=FEET_X, y=FEET_Y - 115, id=hit)

    anims = moods()
    wave_id, wave_xml = wave_anim()
    rest_id, rest_xml = animation("Wave Rest", 1, {}, loop="oneShot", fill_rest=False)
    reg("toggle.opacity", SHADOW[0], "opacity", 1)
    on_id, on_xml = animation("Shadow On", 1, {"toggle.opacity": [(0, 1, "hold")]}, loop="oneShot", fill_rest=False)
    off_id, off_xml = animation("Shadow Off", 1, {"toggle.opacity": [(0, 0, "hold")]}, loop="oneShot", fill_rest=False)

    enum_id, vm, inst, p_mood, p_wave, p_shadow = ids(), ids(), ids(), ids(), ids(), ids()
    vals = {m: ids() for m in MOODS}
    data = [
        el("DataEnumCustom", [el("DataEnumValue", key=m, value=m.capitalize(), id=vals[m]) for m in MOODS],
           name="BotMascotMood", id=enum_id),
        el("ViewModel", [
            el("ViewModelPropertyEnumCustom", enumId=enum_id, name="mood", id=p_mood),
            el("ViewModelPropertyTrigger", name="wave", id=p_wave),
            el("ViewModelPropertyBoolean", name="shadow", id=p_shadow),
            el("ViewModelInstance", [
                el("ViewModelInstanceEnum", propertyValue=vals["idle"], viewModelPropertyId=p_mood),
                el("ViewModelInstanceTrigger", viewModelPropertyId=p_wave),
                el("ViewModelInstanceBoolean", propertyValue=True, viewModelPropertyId=p_shadow),
            ], exports=True, name="Default", id=inst),
        ], defaultInstanceId=inst, name="BotMascot", id=vm),
    ]

    sids = {m: ids() for m in MOODS}
    pos = {"idle": (300, 0), "thinking": (560, -240), "happy": (840, -80), "sad": (840, 160),
           "sleeping": (300, 300), "surprised": (560, 360)}
    states = []
    for m in MOODS:
        trans = [el("StateTransition", [enum_cond(vm, p_mood, vals[o])], stateToId=sids[o], duration=300)
                 for o in MOODS if o != m]
        states.append(el("AnimationState", trans, animationId=anims[m][0], reset=m == "surprised",
                         x=pos[m][0], y=pos[m][1], id=sids[m]))
    mood_layer = el("StateMachineLayer", [
        el("AnyState", x=60, y=-240), el("ExitState", x=1100, y=0),
        el("EntryState", [el("StateTransition", stateToId=sids["idle"])], x=60, y=0),
        *states,
    ], name="Mood", id=ids())

    rest_state, wave_state = ids(), ids()
    wave_layer = el("StateMachineLayer", [
        el("AnyState", x=60, y=-120), el("ExitState", x=700, y=-120),
        el("EntryState", [el("StateTransition", stateToId=rest_state)], x=60, y=0),
        el("AnimationState", [el("StateTransition", [trigger_cond(vm, p_wave)], stateToId=wave_state, duration=150)],
           animationId=rest_id, x=300, y=0, id=rest_state),
        el("AnimationState", [el("StateTransition", stateToId=rest_state, duration=250, enableExitTime=True,
                                 exitTimeIsPercetange=True, exitTime=100)],
           animationId=wave_id, reset=True, x=500, y=120, id=wave_state),
    ], name="Wave", id=ids())

    on_state, off_state = ids(), ids()
    shadow_layer = el("StateMachineLayer", [
        el("AnyState", x=60, y=-120), el("ExitState", x=700, y=-120),
        el("EntryState", [el("StateTransition", stateToId=on_state)], x=60, y=0),
        el("AnimationState", [el("StateTransition", [bool_cond(vm, p_shadow, False)], stateToId=off_state, duration=200)],
           animationId=on_id, x=300, y=0, id=on_state),
        el("AnimationState", [el("StateTransition", [bool_cond(vm, p_shadow, True)], stateToId=on_state, duration=200)],
           animationId=off_id, x=300, y=160, id=off_state),
    ], name="Shadow", id=ids())

    tap = el("StateMachineListenerSingle", [el("ListenerViewModelChange", [
        el("BindablePropertyTrigger", [
            el("DataBindContext", sourcePathIds=f"{vm}-{p_wave}", propertyKey=686, direction=True)],
           propertyValue=1)])], targetId=hit, listenerTypeValue="click", name="Tap To Wave")

    sm, style = ids(), ids()
    machine = el("StateMachine", [tap, mood_layer, wave_layer, shadow_layer], name="Bot Mascot", id=sm)
    kids = [el("LayoutComponentStyle", name="Artboard Style", id=style), machine, fx, character, shadow, hit_area,
            *[a[1] for a in anims.values()], wave_xml, rest_xml, on_xml, off_xml]
    if backdrop:
        kids.append(fill(solid(backdrop), name="Preview Backdrop"))
    board = el("Artboard", kids, width=W, height=H, styleId=style, defaultStateMachineId=sm, viewModelId=vm,
               viewModelInstanceId=inst, name="Bot Mascot", id=ids())
    open(out, "w").write(el("Rive", [board, *data], version="1", kind="fragment") + "\n")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "") for a in sys.argv[1:] if a.startswith("--"))
    backdrop = opts.get("backdrop")
    main(args[0] if args else SCENE, backdrop=(backdrop or "FFF3F3F6") if backdrop is not None else None,
         palette=opts.get("palette", "classic"))
