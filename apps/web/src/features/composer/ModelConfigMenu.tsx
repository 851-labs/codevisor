import type { SessionConfigOption } from "@herdman/api"
import { BoltIcon } from "lucide-react"

import {
  Menu,
  MenuContent,
  MenuGroup,
  MenuGroupLabel,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  MenuTrigger
} from "../../components/ui/menu"

function flatOptions(option: SessionConfigOption) {
  return option.options.flatMap((entry) => ("group" in entry ? entry.options : [entry]))
}

function currentName(option: SessionConfigOption): string {
  return (
    flatOptions(option).find((entry) => entry.value === option.currentValue)?.name ??
    option.currentValue
  )
}

function sectionTitle(option: SessionConfigOption): string {
  switch (option.category) {
    case "model":
      return "Model"
    case "thought_level":
      return "Reasoning"
    case "speed":
      return "Speed"
    default:
      return option.name
  }
}

// The combined model dropdown: one chip for model, thinking level, and speed
// (ComposerView.swift ModelConfigMenu).
export function ModelConfigMenu({
  modelOption,
  thoughtLevelOption,
  speedOption,
  onSelect
}: {
  modelOption?: SessionConfigOption
  thoughtLevelOption?: SessionConfigOption
  speedOption?: SessionConfigOption
  onSelect: (configId: string, value: string) => void
}) {
  const sections = [modelOption, thoughtLevelOption, speedOption].filter(
    (option): option is SessionConfigOption => option != null && flatOptions(option).length > 0
  )
  if (sections.length === 0) return null

  const isFastSpeed = speedOption?.currentValue === "fast"

  return (
    <Menu>
      <MenuTrigger
        title="Model, thinking level, and speed"
        aria-label="Model settings"
        className="-mx-1.5 -my-1 flex min-h-[26px] cursor-default items-center gap-1.5 rounded-full px-1.5 py-1 text-sm text-muted-foreground outline-none hover:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] hover:text-foreground active:opacity-80 data-[popup-open]:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] data-[popup-open]:text-foreground"
      >
        {isFastSpeed && <BoltIcon className="size-3 fill-current" aria-label="Fast speed" />}
        {modelOption != null && <span className="text-foreground">{currentName(modelOption)}</span>}
        {thoughtLevelOption != null && <span>{currentName(thoughtLevelOption)}</span>}
      </MenuTrigger>
      <MenuContent align="start" side="top" className="min-w-48">
        {sections.map((option, index) => (
          <MenuGroup key={option.id}>
            {index > 0 && <MenuSeparator />}
            <MenuGroupLabel>{sectionTitle(option)}</MenuGroupLabel>
            <MenuRadioGroup
              value={option.currentValue}
              onValueChange={(value) => onSelect(option.id, value)}
            >
              {flatOptions(option).map((entry) => (
                <MenuRadioItem key={entry.value} value={entry.value}>
                  {entry.name}
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          </MenuGroup>
        ))}
      </MenuContent>
    </Menu>
  )
}
