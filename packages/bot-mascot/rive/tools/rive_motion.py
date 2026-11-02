from rml import el

EASE = {"io": (0.42, 0, 0.58, 1), "o": (0.2, 0, 0.4, 1), "i": (0.6, 0, 0.8, 1), "s": (0.45, 0, 0.55, 1)}


def smooth(t):
    t = min(1, max(0, t))
    return t * t * (3 - 2 * t)


def pack(ws):
    idx = val = 0
    for i, (t, v) in enumerate(ws):
        idx |= t << (8 * i)
        val |= v << (8 * i)
    return idx, val


def keyframes(kind, keys):
    out = []
    for k in keys:
        frame, value = k[0], k[1]
        ease = k[2] if len(k) > 2 else "io"
        if kind == "id":
            out.append(el("KeyFrameId", value=value, frame=frame, interpolationType="hold"))
        elif ease in ("hold", "linear"):
            out.append(el("KeyFrameDouble", value=value, frame=frame, interpolationType=ease))
        else:
            x1, y1, x2, y2 = EASE[ease]
            out.append(el("KeyFrameDouble", [el("CubicEaseInterpolator", x1=x1, y1=y1, x2=x2, y2=y2)],
                          value=value, frame=frame, interpolationType="cubic"))
    return out


def blink(at, closed=0.08, length=10):
    return [(at, 1), (at + length // 2, closed, "o"), (at + length, 1)]


def cycle(frames, values, ease="s"):
    return [(f, v, ease) for f, v in zip(frames, values)]


def enum_cond(vm, prop, value_id):
    return el("TransitionViewModelCondition", [
        el("TransitionPropertyViewModelComparator", [el("BindablePropertyEnum", [
            el("DataBindContext", sourcePathIds=f"{vm}-{prop}", propertyKey=637)])]),
        el("TransitionValueEnumComparator", value=value_id),
    ])


def trigger_cond(vm, prop):
    return el("TransitionViewModelCondition", [
        el("TransitionPropertyViewModelComparator", [el("BindablePropertyTrigger", [
            el("DataBindContext", sourcePathIds=f"{vm}-{prop}", propertyKey=686)])]),
        el("TransitionValueTriggerComparator"),
    ])


def bool_cond(vm, prop, value):
    return el("TransitionViewModelCondition", [
        el("TransitionPropertyViewModelComparator", [el("BindablePropertyBoolean", [
            el("DataBindContext", sourcePathIds=f"{vm}-{prop}", propertyKey=634)])]),
        el("TransitionValueBooleanComparator", value=value),
    ])
