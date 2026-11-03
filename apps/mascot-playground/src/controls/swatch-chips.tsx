import { botMascotSwatches, type SwatchChoice } from "@codevisor/bot-mascot"

export interface SwatchChipsProps {
  readonly swatches: ReadonlyArray<string>
  readonly hasAuto: boolean
  readonly value: SwatchChoice
  readonly onChange: (value: SwatchChoice) => void
}

export function SwatchChips({ swatches, hasAuto, value, onChange }: SwatchChipsProps) {
  if (swatches.length === 0) return null

  return (
    <div className="chips">
      {hasAuto ? (
        <button
          className="chip auto"
          aria-pressed={value === "auto"}
          title="Auto"
          onClick={() => onChange("auto")}
        >
          A
        </button>
      ) : null}
      {swatchesOf(swatches).map((swatch) => (
        <button
          key={swatch.id}
          className="chip"
          aria-pressed={value === swatch.id}
          title={swatch.id}
          style={{ background: swatch.hex }}
          onClick={() => onChange(swatch.id)}
        />
      ))}
    </div>
  )
}

const swatchesOf = (ids: ReadonlyArray<string>) =>
  botMascotSwatches.filter((swatch) => ids.includes(swatch.id))
