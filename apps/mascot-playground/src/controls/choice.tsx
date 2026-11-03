export interface ChoiceOption<Id extends string> {
  readonly id: Id
  readonly title: string
}

export interface ChoiceProps<Id extends string> {
  readonly label: string
  readonly value: Id
  readonly options: ReadonlyArray<ChoiceOption<Id>>
  readonly onChange: (value: Id) => void
}

export function Choice<Id extends string>({ label, value, options, onChange }: ChoiceProps<Id>) {
  return (
    <label className="choice">
      <span>{label}</span>
      <select
        value={value}
        onChange={(event) => onChange(chosen(options, event.target.value) ?? value)}
      >
        {options.map((option) => (
          <option key={option.id} value={option.id}>
            {option.title}
          </option>
        ))}
      </select>
    </label>
  )
}

export const titled = <Id extends string>(
  ids: ReadonlyArray<Id>
): ReadonlyArray<ChoiceOption<Id>> => ids.map((id) => ({ id, title: id }))

const chosen = <Id extends string>(
  options: ReadonlyArray<ChoiceOption<Id>>,
  id: string
): Id | undefined => options.find((option) => option.id === id)?.id
