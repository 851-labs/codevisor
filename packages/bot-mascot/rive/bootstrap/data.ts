import { botMascotEyewear, botMascotHats, botMascotOutfits } from "../../src/index.js"
import { colorTable, slotCounts, slotTables } from "./colors.js"
import { f, newId } from "./emit.js"
import { DOWN_RANGE, TILT_PER_TURN, TURN_RANGE, UP_RANGE } from "./parts.js"

export const mainVm = { id: newId(), inst: newId() }
export const faceVm = { id: newId(), inst: newId() }
export const FACE_CATS = new Set(["face", "blush", "freckles", "eyewear"])
export const slotProps = new Map<string, string[]>()
for (const [cat, n] of slotCounts)
  slotProps.set(
    cat,
    Array.from({ length: n }, () => newId())
  )

export const vmOf = (cat: string) => (FACE_CATS.has(cat) ? faceVm.id : mainVm.id)
export const bindFor = (cat: string, item: string) => {
  const slots = slotTables.get(`${cat}/${item}`)!
  const props = slotProps.get(cat)!
  return (paintIndex: number): string => {
    const k = slots.paintSlot[paintIndex]
    if (k === null || k === undefined) return ""
    return `<DataBindContext sourcePathIds="${vmOf(cat)}-${props[k]}" propertyKey="${paintKeyNote}"/>`
  }
}
export const paintKeyNote = "__PAINT__"
export const fixPaintKeys = (xml: string): string =>
  xml
    .replace(
      /(<SolidColor [^>]*>)<DataBindContext ([^>]*)propertyKey="__PAINT__"/g,
      '$1<DataBindContext $2propertyKey="37"'
    )
    .replace(
      /(<GradientStop [^>]*>)<DataBindContext ([^>]*)propertyKey="__PAINT__"/g,
      '$1<DataBindContext $2propertyKey="38"'
    )

export const enumXml = (name: string, ids: string[]) => {
  const values = ids.map(() => newId())
  const id = newId()
  return {
    id,
    values,
    xml: `<DataEnumCustom name="${name}" id="${id}">${ids.map((v, i) => `<DataEnumValue key="${v}" value="${v}" id="${values[i]}"/>`).join("")}</DataEnumCustom>`
  }
}
export const hatEnum = enumXml("BotMascotHat", ["none", ...botMascotHats.map((h) => h.id)])
export const outfitEnum = enumXml("BotMascotOutfit", ["none", ...botMascotOutfits.map((o) => o.id)])
export const eyewearEnum = enumXml("BotMascotEyewear", [
  "none",
  ...botMascotEyewear.map((e) => e.id)
])
export const modeEnum = enumXml("BotMascotMode", ["idle", "working", "calling"])
export const prop = {
  mode: newId(),
  hangUp: newId(),
  angryHangUp: newId(),
  hat: newId(),
  outfit: newId(),
  gazeX: newId(),
  gazeY: newId(),
  gazeWeight: newId(),
  face: newId(),
  eyewear: newId(),
  lashesOn: newId(),
  blushOn: newId(),
  frecklesOn: newId()
}
export const bindMain = (p: string, key: number, converter?: string) =>
  `<DataBindContext sourcePathIds="${mainVm.id}-${p}" propertyKey="${key}"${converter ? ` converterId="${converter}"` : ""}/>`
export const bindFace = (p: string, key: number) =>
  `<DataBindContext sourcePathIds="${faceVm.id}-${p}" propertyKey="${key}"/>`

export const solo = (
  name: string,
  enumProp: string,
  bindVm: (p: string, k: number) => string,
  children: Array<{ id: string; xml: string }>
) => {
  const sid = newId()
  return `<Solo activeComponentId="${children[0].id}" name="${name}" id="${sid}">${bindVm(enumProp, 296)}${children.map((c) => c.xml).join("\n")}</Solo>`
}

export const conv = {
  time: newId(),
  weight: newId(),
  upMap: newId(),
  downMap: newId(),
  upMix: newId(),
  downMix: newId(),
  tiltMap: newId(),
  tilt: newId(),
  invertWeight: newId()
}
export const convertersXml = `<DataConverterRangeMapper minInput="-1" maxInput="1" minOutput="${f(0.5 - TURN_RANGE / 2)}" maxOutput="${f(0.5 + TURN_RANGE / 2)}" clampLower="true" clampUpper="true" name="Gaze turn to row time" id="${conv.time}"/>
<DataConverterOperationViewModel operationType="multiply" sourcePathIds="${mainVm.id}-${prop.gazeWeight}" name="Times gaze weight" id="${conv.weight}"/>
<DataConverterRangeMapper minInput="-1" maxInput="0" minOutput="${f(UP_RANGE)}" maxOutput="0" clampLower="true" clampUpper="true" name="Gaze up amount" id="${conv.upMap}"/>
<DataConverterRangeMapper minInput="0" maxInput="1" minOutput="0" maxOutput="${f(DOWN_RANGE)}" clampLower="true" clampUpper="true" name="Gaze down amount" id="${conv.downMap}"/>
<DataConverterGroup name="Gaze up mix" id="${conv.upMix}"><DataConverterGroupItem converterId="${conv.upMap}"/><DataConverterGroupItem converterId="${conv.weight}"/></DataConverterGroup>
<DataConverterGroup name="Gaze down mix" id="${conv.downMix}"><DataConverterGroupItem converterId="${conv.downMap}"/><DataConverterGroupItem converterId="${conv.weight}"/></DataConverterGroup>
<DataConverterRangeMapper minInput="-1" maxInput="1" minOutput="${f(-TILT_PER_TURN * TURN_RANGE)}" maxOutput="${f(TILT_PER_TURN * TURN_RANGE)}" clampLower="true" clampUpper="true" name="Gaze tilt" id="${conv.tiltMap}"/>
<DataConverterRangeMapper minInput="0" maxInput="1" minOutput="100" maxOutput="0" clampLower="true" clampUpper="true" name="Idle look weight" id="${conv.invertWeight}"/>
<DataConverterGroup name="Gaze tilt weighted" id="${conv.tilt}"><DataConverterGroupItem converterId="${conv.tiltMap}"/><DataConverterGroupItem converterId="${conv.weight}"/></DataConverterGroup>`

export const colorProps = (cat: string) =>
  (slotProps.get(cat) ?? [])
    .map((id, k) => `<ViewModelPropertyColor name="${cat}${k}" id="${id}"/>`)
    .join("")
export const colorValues = (cat: string, item: string) => {
  const values =
    colorTable[cat][item].auto?.sunny ?? Object.values(Object.values(colorTable[cat][item])[0])[0]
  return (slotProps.get(cat) ?? [])
    .map(
      (id, k) =>
        `<ViewModelInstanceColor propertyValue="${values[k] ?? "FF000000"}" viewModelPropertyId="${id}"/>`
    )
    .join("")
}
export const num = (id: string, v: number) =>
  `<ViewModelInstanceNumber propertyValue="${v}" viewModelPropertyId="${id}"/>`
export const vmXml = `<ViewModel defaultInstanceId="${faceVm.inst}" name="BotMascotFace" id="${faceVm.id}">
<ViewModelPropertyEnumCustom enumId="${eyewearEnum.id}" name="eyewear" id="${prop.eyewear}"/>
<ViewModelPropertyNumber name="lashesOn" id="${prop.lashesOn}"/>
<ViewModelPropertyNumber name="blushOn" id="${prop.blushOn}"/>
<ViewModelPropertyNumber name="frecklesOn" id="${prop.frecklesOn}"/>
${["face", "blush", "freckles", "eyewear"].map(colorProps).join("")}
<ViewModelInstance exports="true" name="Default" id="${faceVm.inst}">
<ViewModelInstanceEnum propertyValue="${eyewearEnum.values[0]}" viewModelPropertyId="${prop.eyewear}"/>
${num(prop.lashesOn, 0)}${num(prop.blushOn, 1)}${num(prop.frecklesOn, 0)}
${colorValues("face", "face")}${colorValues("blush", "blush")}${colorValues("freckles", "freckles")}${colorValues("eyewear", "specs")}
</ViewModelInstance>
</ViewModel>
<ViewModel defaultInstanceId="${mainVm.inst}" name="BotMascot" id="${mainVm.id}">
<ViewModelPropertyEnumCustom enumId="${modeEnum.id}" name="mode" id="${prop.mode}"/>
<ViewModelPropertyTrigger name="hangUp" id="${prop.hangUp}"/>
<ViewModelPropertyTrigger name="angryHangUp" id="${prop.angryHangUp}"/>
<ViewModelPropertyEnumCustom enumId="${hatEnum.id}" name="hat" id="${prop.hat}"/>
<ViewModelPropertyEnumCustom enumId="${outfitEnum.id}" name="outfit" id="${prop.outfit}"/>
<ViewModelPropertyNumber name="gazeX" id="${prop.gazeX}"/>
<ViewModelPropertyNumber name="gazeY" id="${prop.gazeY}"/>
<ViewModelPropertyNumber name="gazeWeight" id="${prop.gazeWeight}"/>
<ViewModelPropertyViewModel viewModelReferenceId="${faceVm.id}" name="face" id="${prop.face}"/>
${["body", "hat", "outfit", "phone", "clipboard"].map(colorProps).join("")}
<ViewModelInstance exports="true" name="Default" id="${mainVm.inst}">
<ViewModelInstanceEnum propertyValue="${modeEnum.values[0]}" viewModelPropertyId="${prop.mode}"/>
<ViewModelInstanceTrigger viewModelPropertyId="${prop.hangUp}"/>
<ViewModelInstanceTrigger viewModelPropertyId="${prop.angryHangUp}"/>
<ViewModelInstanceEnum propertyValue="${hatEnum.values[0]}" viewModelPropertyId="${prop.hat}"/>
<ViewModelInstanceEnum propertyValue="${outfitEnum.values[0]}" viewModelPropertyId="${prop.outfit}"/>
${num(prop.gazeX, 0)}${num(prop.gazeY, 0)}${num(prop.gazeWeight, 0)}
<ViewModelInstanceViewModel propertyValue="${faceVm.inst}" viewModelPropertyId="${prop.face}"/>
${colorValues("body", "body")}${colorValues("hat", "beanie")}${colorValues("outfit", "tie")}${colorValues("phone", "phone")}${colorValues("clipboard", "clipboard")}
</ViewModelInstance>
</ViewModel>`
