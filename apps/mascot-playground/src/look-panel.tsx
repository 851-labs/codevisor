import {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotMakeup,
  botMascotOutfits,
  defaultBotMascotConfig,
  randomBotMascotConfig,
  type BotMascotEyewear,
  type BotMascotHat,
  type BotMascotOutfit,
  type ColorOption,
  type ItemOption,
  type ResolvedBotMascotConfig,
  type SwatchChoice
} from "@codevisor/bot-mascot"

import { Choice } from "./controls/choice.js"
import { SwatchChips } from "./controls/swatch-chips.js"
import { Toggle } from "./controls/toggle.js"

type Look = ResolvedBotMascotConfig

export interface LookPanelProps {
  readonly look: Look
  readonly onChange: (look: Look) => void
}

interface ItemSlot<Id extends string> {
  readonly label: string
  readonly options: ReadonlyArray<ItemOption<Id>>
  readonly item: (look: Look) => Id | "none"
  readonly color: (look: Look) => SwatchChoice
  readonly patch: (item: Id | "none", color: SwatchChoice) => Partial<Look>
}

const none = { id: "none", title: "None" } as const

const hatSlot: ItemSlot<BotMascotHat> = {
  label: "Hat",
  options: botMascotHats,
  item: (look) => look.hat,
  color: (look) => look.hatColor,
  patch: (hat, hatColor) => ({ hat, hatColor })
}

const eyewearSlot: ItemSlot<BotMascotEyewear> = {
  label: "Eyewear",
  options: botMascotEyewear,
  item: (look) => look.eyewear,
  color: (look) => look.eyewearColor,
  patch: (eyewear, eyewearColor) => ({ eyewear, eyewearColor })
}

const outfitSlot: ItemSlot<BotMascotOutfit> = {
  label: "Outfit",
  options: botMascotOutfits,
  item: (look) => look.outfit,
  color: (look) => look.outfitColor,
  patch: (outfit, outfitColor) => ({ outfit, outfitColor })
}

export function LookPanel({ look, onChange }: LookPanelProps) {
  const patch = (change: Partial<Look>) => onChange({ ...look, ...change })
  return (
    <section className="panel">
      <header>
        <h2>Outfit</h2>
        <button onClick={() => onChange(randomBotMascotConfig(Math.random, look))}>
          Randomize
        </button>
        <button onClick={() => onChange(defaultBotMascotConfig)}>Reset</button>
      </header>
      <ColorPicker value={look.color} onChange={(color) => patch({ color })} />
      <ItemPicker slot={hatSlot} look={look} onChange={patch} />
      <ItemPicker slot={eyewearSlot} look={look} onChange={patch} />
      <ItemPicker slot={outfitSlot} look={look} onChange={patch} />
      <MakeupPicker look={look} onChange={patch} />
    </section>
  )
}

function ColorPicker({
  value,
  onChange
}: {
  readonly value: Look["color"]
  readonly onChange: (color: Look["color"]) => void
}) {
  return (
    <div className="chips colors">
      {botMascotColors.map((color) => (
        <button
          key={color.id}
          className="chip color"
          aria-pressed={value === color.id}
          title={`${color.title}: ${color.note}`}
          style={{ background: gradientOf(color), borderColor: color.outline }}
          onClick={() => onChange(color.id)}
        />
      ))}
    </div>
  )
}

function ItemPicker<Id extends string>({
  slot,
  look,
  onChange
}: {
  readonly slot: ItemSlot<Id>
  readonly look: Look
  readonly onChange: (change: Partial<Look>) => void
}) {
  const item = slot.item(look)
  const option = slot.options.find((o) => o.id === item)
  return (
    <div className="item">
      <Choice
        label={slot.label}
        value={item}
        options={[none, ...slot.options]}
        onChange={(next) => onChange(slot.patch(next, "auto"))}
      />
      <SwatchChips
        swatches={option?.swatches ?? []}
        hasAuto={option?.hasAuto ?? false}
        value={slot.color(look)}
        onChange={(color) => onChange(slot.patch(item, color))}
      />
    </div>
  )
}

function MakeupPicker({
  look,
  onChange
}: {
  readonly look: Look
  readonly onChange: (change: Partial<Look>) => void
}) {
  return (
    <div className="item">
      <span className="label">Makeup</span>
      {botMascotMakeup.map((item) => (
        <div key={item.id} className="makeup">
          <Toggle
            label={item.title}
            checked={look.makeup[item.id]}
            onChange={(on) => onChange({ makeup: { ...look.makeup, [item.id]: on } })}
          />
          <SwatchChips
            swatches={item.swatches}
            hasAuto
            value={look.blushColor}
            onChange={(blushColor) => onChange({ blushColor })}
          />
        </div>
      ))}
    </div>
  )
}

const gradientOf = (color: ColorOption): string =>
  `linear-gradient(${color.gradient.map(([at, hex]) => `${hex} ${at * 100}%`).join(", ")})`
