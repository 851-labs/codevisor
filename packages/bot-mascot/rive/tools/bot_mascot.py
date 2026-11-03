import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rml import Ids, el, solid, linear, fill, stroke, logo_path, ellipse, rect, shape, node
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
    eye, solo, open_, happy, glints = ids(), ids(), ids(), ids(), ids()
    EYES.update(open=open_, happy=happy)
    reg("eye.x", eye, "x", EYE_X)
    reg("eye.state", solo, "activeComponentId", open_, "id")
    reg("eye.sy", open_, "scaleY", 1)
    reg("glints.x", glints, "x", 0)
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
    ], activeComponentId=open_, name="Eye State", id=solo)], x=EYE_X, y=EYE_Y, id=eye)

    msolo = ids()
    m = {k: ids() for k in ("none", "smile")}
    MOUTHS.update(m)
    reg("mouth.state", msolo, "activeComponentId", m["none"], "id")
    mouth = el("Solo", [
        node("None", [], id=m["none"]),
        node("Smile", [D.smile("Line", 298, 316, 24, 10, 8, ink=P["eye"])], id=m["smile"]),
    ], activeComponentId=m["none"], name="Mouth State", id=msolo)

    cheek = ids()
    reg("cheek.sx", cheek, "scaleX", 1)
    cheek_xml = shape("Cheek", [ellipse(40, 18), fill(solid(P["cheek"]), feather=dict(strength=6))],
                      x=226, y=304, id=cheek)

    return [eye_xml, mouth, cheek_xml]


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


def moods():
    A = {}
    A["idle"] = animation("Idle", 300, {
        "base.sx": cycle([0, 75, 150, 225, 300], [1, 1.03, 1, 1.03, 1]),
        "base.sy": cycle([0, 75, 150, 225, 300], [1, 0.985, 1, 0.985, 1]),
        "top.rot": cycle([0, 150, 300], [-0.015, 0.02, -0.015]),
        "eye.sy": [(0, 1, "hold"), *blink(110), *blink(250), *blink(264), (300, 1, "hold")],
        "eye.x": [(0, EYE_X, "hold"), (160, EYE_X, "o"), (170, EYE_X - 7), (214, EYE_X - 7, "o"), (226, EYE_X), (300, EYE_X, "hold")],
        "glints.x": [(0, 0, "hold"), (160, 0, "o"), (170, -6), (214, -6, "o"), (226, 0), (300, 0, "hold")],
    })
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


MOODS = ["idle"]


def main(out, backdrop=None, palette="classic"):
    P.clear()
    P.update(PALETTES[palette])
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
    pos = {"idle": (300, 0)}
    states = []
    for m in MOODS:
        trans = [el("StateTransition", [enum_cond(vm, p_mood, vals[o])], stateToId=sids[o], duration=300)
                 for o in MOODS if o != m]
        states.append(el("AnimationState", trans, animationId=anims[m][0],
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
    kids = [el("LayoutComponentStyle", name="Artboard Style", id=style), machine, character, shadow, hit_area,
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
