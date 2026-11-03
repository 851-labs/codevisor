export interface SliderProps {
  readonly label: string
  readonly value: number
  readonly min: number
  readonly max: number
  readonly step: number
  readonly onChange: (value: number) => void
  readonly disabled?: boolean
}

export function Slider({ label, value, min, max, step, onChange, disabled = false }: SliderProps) {
  return (
    <label className="slider">
      <span>{label}</span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        disabled={disabled}
        onChange={(event) => onChange(Number(event.target.value))}
      />
      <output>{formatted(value, step)}</output>
    </label>
  )
}

const formatted = (value: number, step: number): string =>
  step >= 1 ? String(Math.round(value)) : value.toFixed(2)
