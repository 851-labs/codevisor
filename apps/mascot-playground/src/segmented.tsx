export interface SegmentedOption<Id extends string> {
  readonly id: Id
  readonly title: string
}

export interface SegmentedProps<Id extends string> {
  readonly value: Id
  readonly options: ReadonlyArray<SegmentedOption<Id>>
  readonly onChange: (value: Id) => void
}

export function Segmented<Id extends string>({ value, options, onChange }: SegmentedProps<Id>) {
  return (
    <div className="segmented" role="tablist">
      {options.map((option) => (
        <button
          key={option.id}
          role="tab"
          aria-selected={value === option.id}
          onClick={() => onChange(option.id)}
        >
          {option.title}
        </button>
      ))}
    </div>
  )
}
