import { CheckIcon } from "lucide-react"
import type { ReactNode } from "react"

import { Menu, MenuContent, MenuItem, MenuTrigger } from "../../components/ui/menu"

export interface ChipMenuOption {
  value: string
  label: string
  description?: string
  disabled?: boolean
  icon?: ReactNode
}

// The quiet chip-label dropdown shared by the harness, config, and mode
// pickers in the composer toolbar (ComposerView.swift chipLabel + menus).
export function ChipMenu({
  label,
  title,
  icon,
  options,
  selectedValue,
  onSelect
}: {
  label: string
  title?: string
  icon?: ReactNode
  options: readonly ChipMenuOption[]
  selectedValue: string | undefined
  onSelect: (value: string) => void
}) {
  return (
    <Menu>
      <MenuTrigger
        title={title}
        className="-mx-1.5 -my-1 flex min-h-[26px] cursor-default items-center gap-1.5 rounded-full px-1.5 py-1 text-sm text-muted-foreground outline-none hover:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] hover:text-foreground active:opacity-80 data-[popup-open]:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] data-[popup-open]:text-foreground"
      >
        {icon}
        {label}
      </MenuTrigger>
      <MenuContent align="start" side="top">
        {options.map((option) => (
          <MenuItem
            key={option.value}
            disabled={option.disabled}
            title={option.description}
            onClick={() => onSelect(option.value)}
          >
            <span className="flex size-4 items-center justify-center">
              {option.value === selectedValue && <CheckIcon className="size-3.5" />}
            </span>
            {option.icon != null && (
              <span className="text-muted-foreground flex size-4 items-center justify-center">
                {option.icon}
              </span>
            )}
            <span className="flex min-w-0 flex-col">
              <span>{option.label}</span>
              {option.description != null && (
                <span className="text-xs text-[var(--codevisor-popover-muted-fg)]">
                  {option.description}
                </span>
              )}
            </span>
          </MenuItem>
        ))}
      </MenuContent>
    </Menu>
  )
}
