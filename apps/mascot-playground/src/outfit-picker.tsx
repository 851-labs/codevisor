import {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotMakeup,
  botMascotOutfits,
  botMascotSwatches,
  defaultBotMascotConfig,
  FIGURE_VIEW_BOX,
  portraitViewBox,
  randomBotMascotConfig,
  renderBotMascotSvg,
  type BotMascotEyewear,
  type BotMascotHat,
  type BotMascotOutfit,
  type ColorOption,
  type ItemOption,
  type ResolvedBotMascotConfig,
  type SwatchChoice
} from "@codevisor/bot-mascot"
import { useMemo, type ReactNode } from "react"

type Look = ResolvedBotMascotConfig

export interface OutfitPickerProps {
  readonly look: Look
  readonly onChange: (look: Look) => void
}

interface Section<Id extends string> {
  readonly title: string
  readonly options: ReadonlyArray<ItemOption<Id>>
  readonly framing: "portrait" | "figure"
  readonly item: (look: Look) => Id | "none"
  readonly color: (look: Look) => SwatchChoice
  readonly patch: (item: Id | "none", color: SwatchChoice) => Partial<Look>
}

const hatSection: Section<BotMascotHat> = {
  title: "Hat",
  options: botMascotHats,
  framing: "portrait",
  item: (look) => look.hat,
  color: (look) => look.hatColor,
  patch: (hat, hatColor) => ({ hat, hatColor })
}

const glassesSection: Section<BotMascotEyewear> = {
  title: "Glasses",
  options: botMascotEyewear,
  framing: "portrait",
  item: (look) => look.eyewear,
  color: (look) => look.eyewearColor,
  patch: (eyewear, eyewearColor) => ({ eyewear, eyewearColor })
}

const clothesSection: Section<BotMascotOutfit> = {
  title: "Clothes",
  options: botMascotOutfits,
  framing: "figure",
  item: (look) => look.outfit,
  color: (look) => look.outfitColor,
  patch: (outfit, outfitColor) => ({ outfit, outfitColor })
}

const TILE = 64

export function OutfitPicker({ look, onChange }: OutfitPickerProps) {
  const patch = (change: Partial<Look>) => onChange({ ...look, ...change })
  return (
    <div className="picker">
      <div className="picker-actions">
        <button className="soft" onClick={() => onChange(randomBotMascotConfig(Math.random, look))}>
          Surprise me
        </button>
        <button className="soft" onClick={() => onChange(defaultBotMascotConfig)}>
          Start over
        </button>
      </div>
      <PickerSection title="Color">
        <ColorRow value={look.color} onChange={(color) => patch({ color })} />
      </PickerSection>
      <ItemSection section={hatSection} look={look} onChange={patch} />
      <ItemSection section={glassesSection} look={look} onChange={patch} />
      <ItemSection section={clothesSection} look={look} onChange={patch} />
      <PickerSection title="Face">
        <MakeupRow look={look} onChange={patch} />
      </PickerSection>
    </div>
  )
}

function PickerSection({
  title,
  children
}: {
  readonly title: string
  readonly children: ReactNode
}) {
  return (
    <section className="picker-section">
      <h3>{title}</h3>
      {children}
    </section>
  )
}

function ColorRow({
  value,
  onChange
}: {
  readonly value: Look["color"]
  readonly onChange: (color: Look["color"]) => void
}) {
  return (
    <div className="color-row">
      {botMascotColors.map((color) => (
        <button
          key={color.id}
          className="color-swatch"
          aria-pressed={value === color.id}
          onClick={() => onChange(color.id)}
        >
          <span style={{ background: gradientOf(color), borderColor: color.outline }} />
          {color.title}
        </button>
      ))}
    </div>
  )
}

function ItemSection<Id extends string>({
  section,
  look,
  onChange
}: {
  readonly section: Section<Id>
  readonly look: Look
  readonly onChange: (change: Partial<Look>) => void
}) {
  const chosen = section.item(look)
  const option = section.options.find((o) => o.id === chosen)
  const tiles = useMemo(
    () =>
      ["none" as const, ...section.options.map((o) => o.id)].map((id) => ({
        id,
        title: id === "none" ? "None" : (section.options.find((o) => o.id === id)?.title ?? id),
        art: {
          __html: thumbnail(
            { ...look, ...section.patch(id, "auto") },
            section.framing,
            `${section.title}${id}`
          )
        }
      })),
    [look, section]
  )
  return (
    <PickerSection title={section.title}>
      <div className="tiles">
        {tiles.map((tile) => (
          <button
            key={tile.id}
            className="tile"
            aria-pressed={chosen === tile.id}
            onClick={() => onChange(section.patch(tile.id, "auto"))}
          >
            <span className="tile-art" dangerouslySetInnerHTML={tile.art} />
            {tile.title}
          </button>
        ))}
      </div>
      {option && option.swatches.length > 0 ? (
        <Swatches
          swatches={option.swatches}
          hasAuto={option.hasAuto}
          value={section.color(look)}
          onChange={(color) => onChange(section.patch(chosen, color))}
        />
      ) : null}
    </PickerSection>
  )
}

function MakeupRow({
  look,
  onChange
}: {
  readonly look: Look
  readonly onChange: (change: Partial<Look>) => void
}) {
  const labels: Readonly<Record<string, string>> = {
    blush: "Rosy cheeks",
    freckles: "Freckles",
    lashes: "Eyelashes"
  }
  return (
    <div className="makeup">
      <div className="toggles">
        {botMascotMakeup.map((item) => (
          <label key={item.id} className="pill-toggle">
            <input
              type="checkbox"
              checked={look.makeup[item.id]}
              onChange={(event) =>
                onChange({ makeup: { ...look.makeup, [item.id]: event.target.checked } })
              }
            />
            {labels[item.id] ?? item.title}
          </label>
        ))}
      </div>
      {look.makeup.blush ? (
        <Swatches
          swatches={botMascotMakeup.find((m) => m.id === "blush")?.swatches ?? []}
          hasAuto
          value={look.blushColor}
          onChange={(blushColor) => onChange({ blushColor })}
        />
      ) : null}
    </div>
  )
}

function Swatches({
  swatches,
  hasAuto,
  value,
  onChange
}: {
  readonly swatches: ReadonlyArray<string>
  readonly hasAuto: boolean
  readonly value: SwatchChoice
  readonly onChange: (value: SwatchChoice) => void
}) {
  const choices = botMascotSwatches.filter((s) => swatches.includes(s.id))
  return (
    <div className="swatches">
      {hasAuto ? (
        <button
          className="swatch auto"
          aria-pressed={value === "auto"}
          onClick={() => onChange("auto")}
        >
          Matching
        </button>
      ) : null}
      {choices.map((s) => (
        <button
          key={s.id}
          className="swatch"
          aria-pressed={value === s.id}
          aria-label={s.id}
          title={titleCase(s.id)}
          style={{ background: s.hex }}
          onClick={() => onChange(s.id)}
        />
      ))}
    </div>
  )
}

const thumbnail = (look: Look, framing: "portrait" | "figure", uid: string): string =>
  renderBotMascotSvg({
    ...look,
    size: TILE,
    viewBox: framing === "figure" ? FIGURE_VIEW_BOX : portraitViewBox(look.hat),
    uid
  })

const gradientOf = (color: ColorOption): string =>
  `linear-gradient(${color.gradient.map(([at, hex]) => `${hex} ${at * 100}%`).join(", ")})`

const titleCase = (id: string): string => id.charAt(0).toUpperCase() + id.slice(1)
