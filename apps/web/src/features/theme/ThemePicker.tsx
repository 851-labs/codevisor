import type { ColorMode } from "@pierre/theming"
import { ChevronsUpDownIcon, PaletteIcon } from "lucide-react"
import { useMemo } from "react"

import {
  Select,
  SelectContent,
  SelectGroup,
  SelectGroupLabel,
  SelectItem,
  SelectTrigger,
  SelectValue
} from "../../components/ui/select"
import { Popover, PopoverContent, PopoverTrigger } from "../../components/ui/popover"
import { ToggleGroup, ToggleGroupItem } from "../../components/ui/toggle-group"
import { cn } from "../../lib/cn"
import { codevisorThemeCatalog } from "../../theme/themeCatalog"
import { useTheme } from "../../theme/ThemeProvider"
import { useThemeSelection } from "../../theme/useThemeSelection"

const MODE_LABELS: Array<{ value: ColorMode; label: string }> = [
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
  { value: "system", label: "System" }
]

// Groups catalog names into pierre-first sections for the select popup.
function useThemeSections(names: readonly string[]) {
  return useMemo(() => {
    const pierre: string[] = []
    const shiki: string[] = []
    for (const name of names) {
      const descriptor = codevisorThemeCatalog.getTheme(name)
      if (descriptor?.collection === "pierre") pierre.push(name)
      else shiki.push(name)
    }
    return [
      { label: "Pierre", names: pierre },
      { label: "Shiki", names: shiki }
    ].filter((section) => section.names.length > 0)
  }, [names])
}

function displayNameOf(name: string): string {
  return codevisorThemeCatalog.getTheme(name)?.displayName ?? name
}

function ThemeSelect({
  label,
  value,
  names,
  onChange
}: {
  label: string
  value: string
  names: readonly string[]
  onChange: (name: string) => void
}) {
  const sections = useThemeSections(names)
  return (
    <label className="flex flex-col gap-1">
      <span className="text-muted-foreground text-xs font-medium">{label}</span>
      <Select
        value={value}
        onValueChange={(next) => {
          if (typeof next === "string") onChange(next)
        }}
      >
        <SelectTrigger>
          <SelectValue>{() => displayNameOf(value)}</SelectValue>
        </SelectTrigger>
        <SelectContent>
          {sections.map((section) => (
            <SelectGroup key={section.label}>
              <SelectGroupLabel>{section.label}</SelectGroupLabel>
              {section.names.map((name) => (
                <SelectItem key={name} value={name}>
                  {displayNameOf(name)}
                </SelectItem>
              ))}
            </SelectGroup>
          ))}
        </SelectContent>
      </Select>
    </label>
  )
}

// The sidebar-footer theme selector: a three-way color-mode toggle plus
// per-scheme theme pickers over the pierre+shiki catalog. Lives where the
// macOS app keeps its machine picker (deferred), so theming stays discoverable
// without a settings window.
export function ThemePicker({ className }: { className?: string }) {
  const selection = useThemeSelection()
  const { resolvedColorScheme } = useTheme()
  const activeThemeName =
    resolvedColorScheme === "dark" ? selection.darkThemeName : selection.lightThemeName

  return (
    <Popover>
      <PopoverTrigger
        className={cn(
          "flex w-full cursor-default items-center gap-2 rounded-md px-2 py-1.5 text-sm outline-none",
          "hover:bg-[var(--codevisor-row-hover-bg)] data-[popup-open]:bg-[var(--codevisor-row-hover-bg)]",
          "focus-visible:ring-ring/50 focus-visible:ring-2",
          className
        )}
      >
        <PaletteIcon className="text-muted-foreground size-4 shrink-0" />
        <span className="min-w-0 flex-1 truncate text-left">{displayNameOf(activeThemeName)}</span>
        <ChevronsUpDownIcon className="text-muted-foreground size-3.5 shrink-0" />
      </PopoverTrigger>
      <PopoverContent side="top" align="start" className="flex w-64 flex-col gap-3">
        <ToggleGroup
          value={[selection.colorMode]}
          onValueChange={(groupValue) => {
            const mode = groupValue[0]
            if (mode === "light" || mode === "dark" || mode === "system") {
              selection.setColorMode(mode)
            }
          }}
          className="w-full"
        >
          {MODE_LABELS.map((mode) => (
            <ToggleGroupItem key={mode.value} value={mode.value}>
              {mode.label}
            </ToggleGroupItem>
          ))}
        </ToggleGroup>
        <ThemeSelect
          label="Light theme"
          value={selection.lightThemeName}
          names={selection.lightThemeNames}
          onChange={selection.setLightThemeName}
        />
        <ThemeSelect
          label="Dark theme"
          value={selection.darkThemeName}
          names={selection.darkThemeNames}
          onChange={selection.setDarkThemeName}
        />
      </PopoverContent>
    </Popover>
  )
}
