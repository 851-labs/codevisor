import { botMascotHats, botMascotOutfits, idleAt } from "../../src/index.js"
import { armIds, armRig, handIds, layerTargets, sleeveIds, type SleevePaint } from "./arms.js"
import { paintsOf } from "./collect.js"
import { planned, plannedItems } from "./colors.js"
import { bindFor, bindMain, conv, mainVm, modeEnum, prop, solo } from "./data.js"
import { emitItems, f, idsFor, newId, pointsPath, type Skinning } from "./emit.js"
import { annoyedAnim, blinkAnim, faceBoard, madAnim, rows } from "./face.js"
import { joinIds, joinRig } from "./join-rig.js"
import { bodyLayer, idlePropsXml, movesXml, propsLayer, restKeys, type MoveIds } from "./moves.js"
import { FEET, PIVOT, mainBodyPart, noMakeup, part, render } from "./parts.js"
import { clipboardItems, phoneItems, restHanging, restRising } from "./props.js"
import { upperWeight } from "./skinning.js"
import { sleepZsAnimationsXml, sleepZsLayer, sleepZsXml } from "./sleep-zs.js"
import { sleevePart } from "./sleeves.js"

export const bone = { base: newId(), lean: newId(), gaze: newId() }
export const tendon = (id: string, ty: number) =>
  `<Tendon boneId="${id}" xx="0" xy="-1" yx="1" yy="0" tx="${f(FEET[0])}" ty="${f(ty)}" name="T"/>`
export const skin: Skinning = {
  tendons: tendon(bone.base, FEET[1]) + tendon(bone.gaze, PIVOT[1]),
  weight: upperWeight
}

export const bodyShapeItems = planned("body/body", mainBodyPart)(render({ makeup: noMakeup }))
export const shadowItems = bodyShapeItems.slice(0, 1)
export const bodyItem = bodyShapeItems.slice(1, 2)
export const shadeItem = bodyShapeItems.slice(2)
export const bodyBind = bindFor("body", "body")
export const bodyIds = idsFor(bodyItem[0])
export const offsetBind = (bind: (i: number) => string, offset: number) => (i: number) =>
  bind(i + offset)
export const shadowRml = emitItems(shadowItems, { bind: bodyBind })
export const bodyRml = emitItems(
  bodyItem,
  { bind: offsetBind(bodyBind, paintsOf(shadowItems).length), skin },
  [bodyIds]
)
export const shadeRml = emitItems(shadeItem, {
  bind: offsetBind(bodyBind, paintsOf([...shadowItems, ...bodyItem]).length),
  skin,
  bodyClip: bodyIds.shape
})

export let clipSources = ""
export const hatChildren = [{ id: newId(), xml: "" }]
hatChildren[0].xml = `<Node name="none" id="${hatChildren[0].id}"/>`
for (const h of botMascotHats) {
  const items = planned(`hat/${h.id}`, part("hat"))(render({ hat: h.id, makeup: noMakeup }))
  const e = emitItems(items, { bind: bindFor("hat", h.id) })
  const id = newId()
  hatChildren.push({ id, xml: `<Node name="${h.id}" id="${id}">${e.rml}${e.clipRml}</Node>` })
}

export const sleevePaints = new Map<string, SleevePaint>()
export const wearChildren = [{ id: newId(), xml: "" }]
export const drapeChildren = [{ id: newId(), xml: "" }]
wearChildren[0].xml = `<Node name="none" id="${wearChildren[0].id}"/>`
drapeChildren[0].xml = `<Node name="none" id="${drapeChildren[0].id}"/>`
for (const o of botMascotOutfits) {
  const root = render({ outfit: o.id, makeup: noMakeup })
  const all = planned(`outfit/${o.id}`, (r) => [
    ...part("wear")(r),
    ...part("drape")(r),
    ...sleevePart(r)
  ])(root)
  const wear = all.slice(0, part("wear")(root).length)
  const drape = all.slice(wear.length, wear.length + part("drape")(root).length)
  const sleeve = all[wear.length + drape.length]
  const bind = bindFor("outfit", o.id)
  if (sleeve?.fill?.kind === "solid")
    sleevePaints.set(o.id, {
      color: sleeve.fill.color,
      bind: bind(paintsOf([...wear, ...drape]).length)
    })
  const w = emitItems(wear, { bind, skin, bodyClip: bodyIds.shape })
  const d = emitItems(drape, {
    bind: offsetBind(bind, paintsOf(wear).length),
    skin,
    bodyClip: bodyIds.shape
  })
  clipSources += w.clipRml + d.clipRml
  const wid = newId()
  const did = newId()
  wearChildren.push({ id: wid, xml: `<Node name="${o.id}" id="${wid}">${w.rml}</Node>` })
  drapeChildren.push({ id: did, xml: `<Node name="${o.id}" id="${did}">${d.rml}</Node>` })
}

export const remapId = {
  wanderMid: newId(),
  wanderUp: newId(),
  wanderDown: newId(),
  blink: newId(),
  annoyed: newId(),
  mad: newId()
}
export const remap = (
  name: string,
  anim: string,
  mix: number,
  binds = "",
  id = newId(),
  time = 0.5
) =>
  `<NestedRemapAnimation animationId="${anim}" time="${time}" mix="${mix}" name="${name}" id="${id}">${binds}</NestedRemapAnimation>`
export const gazeTime = bindMain(prop.gazeX, 202, conv.time)
export const faceNested = `<NestedArtboard artboardId="${faceBoard}" dataBindPathIds="${mainVm.id}-${prop.face}" x="0" y="0" name="Face" id="${newId()}">
${remap("Wander mid", rows.mid.id, 1, "", remapId.wanderMid)}
${remap("Wander up", rows.up.id, 0, "", remapId.wanderUp)}
${remap("Wander down", rows.down.id, 0, "", remapId.wanderDown)}
${remap("Gaze mid", rows.mid.id, 0, gazeTime + bindMain(prop.gazeWeight, 200))}
${remap("Gaze up", rows.up.id, 0, gazeTime + bindMain(prop.gazeY, 200, conv.upMix))}
${remap("Gaze down", rows.down.id, 0, gazeTime + bindMain(prop.gazeY, 200, conv.downMix))}
${remap("Blink", blinkAnim, 1, "", remapId.blink, 0)}
${remap("Annoyed", annoyedAnim, 1, "", remapId.annoyed, 0)}
${remap("Mad", madAnim, 1, "", remapId.mad, 0)}
</NestedArtboard>`

export const head = `<Node x="${f(PIVOT[1])}" y="${f(-PIVOT[0])}" rotation="${f(Math.PI / 2)}" name="Head space" id="${newId()}">
${solo("Hat", prop.hat, bindMain, hatChildren)}
<Node name="Face clip" id="${newId()}">${faceNested}<ClippingShape sourceId="${bodyIds.shape}" name="Body clip"/></Node>
</Node>`

export const character = newId()
export const IDLE_FRAMES = 600
export const sample = (every: number, value: (t: number) => number) =>
  Array.from({ length: IDLE_FRAMES / every + 1 }, (_, k) => {
    const frame = k * every
    return `<KeyFrameDouble value="${f(value(frame / 60))}" frame="${frame}" interpolationType="linear"/>`
  }).join("")
export const keyed = (obj: string, props: Array<[string, number, (t: number) => number]>) =>
  `<KeyedObject objectId="${obj}">${props.map(([p, every, v]) => `<KeyedProperty property="${p}">${sample(every, v)}</KeyedProperty>`).join("")}</KeyedObject>`
export const idleFace = (t: number) => idleAt(t).face ?? {}
export const idleSy = (t: number) => idleAt(t).sy ?? 1
export const blinkTime = (t: number) =>
  Math.max(0, Math.min(1, (1 - (idleFace(t).blink ?? 1)) / 0.92))
export const turnTime = (t: number) => ((idleFace(t).turn ?? 0) + 1) / 2
export const idleBody = newId()
export const idleLook = newId()
export const idleXml = `<LinearAnimation duration="${IDLE_FRAMES}" loopValue="loop" name="Idle body" id="${idleBody}">
${keyed(character, [
  ["rotation", 2, (t) => ((idleAt(t).lean ?? 0) * Math.PI) / 180],
  ["scaleX", 2, (t) => 2 - idleSy(t)],
  ["scaleY", 2, idleSy]
])}
${keyed(shadowRml.ids[0].shape, [["scaleX", 2, (t) => 2 - idleSy(t)]])}
${keyed(remapId.blink, [["time", 1, blinkTime]])}
</LinearAnimation>
<LinearAnimation duration="${IDLE_FRAMES}" loopValue="loop" name="Idle look" id="${idleLook}">
${keyed(bone.lean, [["rotation", 2, (t) => ((idleAt(t).tilt ?? 0) * Math.PI) / 180]])}
${keyed(remapId.wanderMid, [["time", 2, turnTime]])}
${keyed(remapId.wanderUp, [
  ["time", 2, turnTime],
  ["mix", 2, (t) => Math.max(0, -(idleFace(t).up ?? 0))]
])}
${keyed(remapId.wanderDown, [
  ["time", 2, turnTime],
  ["mix", 2, (t) => Math.max(0, idleFace(t).up ?? 0)]
])}
</LinearAnimation>`
const bodyFill = bodyItem[0].fill
const fillBase = paintsOf(shadowItems).length
const fillStops = bodyFill && bodyFill.kind !== "solid" ? bodyFill.stops.length : 0
const outlineColor =
  bodyItem[0].stroke?.paint.kind === "solid" ? bodyItem[0].stroke.paint.color : "FF3B2410"
const phoneNode = newId()
const phone = emitItems(plannedItems("phone/phone", phoneItems({ color: "sunny" })), {
  bind: bindFor("phone", "phone")
})
const clipboardNode = newId()
const clipboard = emitItems(
  plannedItems("clipboard/clipboard", clipboardItems({ color: "sunny" })),
  {
    bind: bindFor("clipboard", "clipboard")
  }
)
const armPaints = {
  fill: bodyFill ?? { kind: "solid", color: "FFFFE27A" },
  fillBinds: Array.from({ length: fillStops }, (_, k) => bodyBind(fillBase + k)),
  outline: outlineColor,
  outlineBind: bodyBind(fillBase + fillStops),
  shade: shadeItem[0].fill?.kind === "solid" ? shadeItem[0].fill.color : "40C46A00",
  shadeBind: bodyBind(paintsOf([...shadowItems, ...bodyItem]).length)
}
const topOfBody =
  armPaints.fill.kind === "solid" ? armPaints.fill.color : armPaints.fill.stops[0].color
const zInk = {
  ...armPaints,
  core: topOfBody,
  coreBind: armPaints.fillBinds[0] ?? ""
}
const joins = joinRig(armPaints)
const arms = armRig(
  armPaints,
  {
    top: clipboard.ids[clipboard.ids.length - 1].shape,
    bottom: clipboard.ids[0].shape
  },
  sleevePaints
)
const pageRef = (contours: typeof restRising) => ({
  shape: newId(),
  dim: newId(),
  vertices: contours[0].vertices.map(() => newId()),
  dimVertices: contours[0].vertices.map(() => newId())
})
const page = { rising: pageRef(restRising), hanging: pageRef(restHanging) }
const abovePage = (shape: string) =>
  `<DrawRules drawTargetId="${shape}" name="Above the face" id="${newId()}"><DrawTarget drawableId="${armIds.left.shape}" placementValue="after" name="Under the arms" id="${shape}"/></DrawRules>`
const pageShade = (contours: typeof restRising) => {
  const xs = contours[0].vertices.map((v) => v.p[0])
  const ys = contours[0].vertices.map((v) => v.p[1])
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)]
  return `<Fill name="Shade"><LinearGradient startX="${f(x0 + 0.8 * (x1 - x0))}" startY="${f(y0)}" endX="${f(x0 + 0.2 * (x1 - x0))}" endY="${f(y1)}" name="G"><GradientStop colorValue="001B2140" position="0.35"/><GradientStop colorValue="291B2140" position="1"/></LinearGradient></Fill>`
}
const pageXml = (kind: "rising" | "hanging", contours: typeof restRising) => {
  const ref = page[kind]
  return `<Shape opacity="0" name="Page dim ${kind}" id="${ref.dim}">${pointsPath(contours[0], [...ref.dimVertices])}<Fill name="F"><SolidColor colorValue="FF1B2140" name="C"/></Fill>${abovePage(newId())}</Shape>
<Shape opacity="0" name="Page ${kind}" id="${ref.shape}">${pointsPath(contours[0], [...ref.vertices])}<Fill name="Paper"><SolidColor colorValue="FFFBF8F1" name="C"/></Fill>${pageShade(contours)}<Stroke thickness="3" join="round" name="Ink"><SolidColor colorValue="${outlineColor}" name="C">${bodyBind(fillBase + fillStops)}</SolidColor></Stroke>${abovePage(newId())}</Shape>`
}
export const moveIds: MoveIds = {
  character,
  shadow: shadowRml.ids[0].shape,
  shadowSquash: shadowItems[0].squash ?? 1,
  lean: bone.lean,
  remaps: remapId,
  arms: armIds,
  hand: handIds,
  sleeves: sleeveIds,
  joins: joinIds,
  bodyVertices: bodyIds.vertices[0],
  layers: layerTargets,
  phone: phoneNode,
  clipboard: clipboardNode,
  page
}
const idleState = newId()
const idleBlend = `<BlendStateDirect x="260" y="0" id="${idleState}"><BlendAnimationDirect animationId="${idleBody}" blendSource="1" mixValue="100"/><BlendAnimationDirect animationId="${idleLook}" blendSource="2"><BindablePropertyNumber><DataBindContext sourcePathIds="${mainVm.id}-${prop.gazeWeight}" propertyKey="636" converterId="${conv.invertWeight}"/></BindablePropertyNumber></BlendAnimationDirect><!--transitions--></BlendStateDirect>`
const stateRefs = {
  vm: mainVm.id,
  mode: prop.mode,
  modeValues: {
    idle: modeEnum.values[0],
    working: modeEnum.values[1],
    calling: modeEnum.values[2],
    sleeping: modeEnum.values[3]
  },
  hangUp: prop.hangUp,
  angryHangUp: prop.angryHangUp,
  idleState
}
const states = bodyLayer(stateRefs, idleBlend)
const props = propsLayer(stateRefs)
export const lookWeight = newId()
export const mainBoard = newId()
export const mainSm = newId()
export const mainStyle = newId()
export const restAnim = newId()
export const restState = newId()
export const mainArtboard = `<Artboard width="500" height="500" styleId="${mainStyle}" defaultStateMachineId="${mainSm}" viewModelId="${mainVm.id}" viewModelInstanceId="${mainVm.inst}" name="Bot Mascot" id="${mainBoard}">
<LayoutComponentStyle name="Artboard Style" id="${mainStyle}"/>
<StateMachine name="Bot Mascot" id="${mainSm}">
<StateMachineLayer name="Face" id="${newId()}"><AnyState x="60" y="-120"/><ExitState x="1000" y="-120"/><EntryState x="60" y="0"><StateTransition stateToId="${idleState}"/></EntryState>
${states}
</StateMachineLayer>
<StateMachineLayer name="Body" id="${newId()}"><AnyState x="60" y="-120"/><ExitState x="1000" y="-120"/><EntryState x="60" y="0"><StateTransition stateToId="${props.idleState}"/></EntryState>
${props.xml}
</StateMachineLayer>
${sleepZsLayer(stateRefs)}
</StateMachine>
${sleepZsXml(zInk)}
<Node x="${f(FEET[0])}" y="${f(FEET[1])}" name="Character" id="${character}">
<Node x="${f(-FEET[0])}" y="${f(-FEET[1])}" name="Arms" id="${newId()}">
${arms.hand}
<Node opacity="0" name="Phone" id="${phoneNode}">${phone.rml}${phone.clipRml}</Node>
${arms.arms}
</Node>
<RootBone x="0" y="0" rotation="${f(-Math.PI / 2)}" length="${f(FEET[1] - PIVOT[1] - 1)}" name="Base" id="${bone.base}">
<Bone length="1" name="Lean" id="${bone.lean}">
<Bone length="100" name="Gaze" id="${bone.gaze}">${bindMain(prop.gazeX, 15, conv.tilt)}
${head}
</Bone>
</Bone>
</RootBone>
<Node x="${f(-FEET[0])}" y="${f(-FEET[1])}" name="Torso" id="${newId()}">
<Node opacity="0" name="Clipboard" id="${clipboardNode}">
${pageXml("rising", restRising)}
${pageXml("hanging", restHanging)}
${clipboard.rml}${clipboard.clipRml}
</Node>
${solo("Drape", prop.outfit, bindMain, drapeChildren)}
${solo("Wear", prop.outfit, bindMain, wearChildren)}
${shadeRml.rml}
${joins.joins}
${bodyRml.rml}
${clipSources}${shadeRml.clipRml}
</Node>
</Node>
${shadowRml.rml}
${idleXml.replace("</LinearAnimation>", `${restKeys(moveIds)}</LinearAnimation>`)}
${idlePropsXml(moveIds)}
${movesXml(moveIds)}
${sleepZsAnimationsXml()}
</Artboard>`
