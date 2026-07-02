import { CheckIcon, ChevronDownIcon } from "lucide-react"

import { Menu, MenuContent, MenuItem, MenuTrigger } from "../../components/ui/menu"

export interface ChipMenuOption {
  value: string
  label: string
  description?: string
}

// The quiet chip-label dropdown shared by the harness, config, and mode
// pickers in the composer toolbar (ComposerView.swift chipLabel + menus).
export function ChipMenu({
  label,
  title,
  options,
  selectedValue,
  onSelect
}: {
  label: string
  title?: string
  options: readonly ChipMenuOption[]
  selectedValue: string | undefined
  onSelect: (value: string) => void
}) {
  return (
    <Menu>
      <MenuTrigger
        title={title}
        className="text-muted-foreground hover:text-foreground flex cursor-default items-center gap-1 text-sm outline-none data-[popup-open]:text-foreground"
      >
        {label}
        <ChevronDownIcon className="size-3" />
      </MenuTrigger>
      <MenuContent align="start" side="top">
        {options.map((option) => (
          <MenuItem key={option.value} onClick={() => onSelect(option.value)}>
            <span className="flex size-4 items-center justify-center">
              {option.value === selectedValue && <CheckIcon className="size-3.5" />}
            </span>
            {option.label}
          </MenuItem>
        ))}
      </MenuContent>
    </Menu>
  )
}
