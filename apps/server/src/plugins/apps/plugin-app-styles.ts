export type AppPlatform = "desktop" | "mobile"

export interface AppHostStyles {
  readonly variables: Readonly<Record<string, string>>
}

export const appHostStyles = (platform: AppPlatform): AppHostStyles => ({
  variables: { ...colorVariables, ...fontVariables, ...textSizes[platform], ...shapeVariables }
})

const lightDark = (light: string, dark: string): string => `light-dark(${light}, ${dark})`

const accent = { blue: ["#007aff", "#0a84ff"], red: ["#ff3b30", "#ff453a"] } as const

const colorVariables: Readonly<Record<string, string>> = {
  "--color-background-primary": lightDark("#ffffff", "#1e1e1e"),
  "--color-background-secondary": lightDark("#f5f5f7", "#2a2a2c"),
  "--color-background-tertiary": lightDark("#e8e8ed", "#3a3a3c"),
  "--color-background-inverse": lightDark("#1d1d1f", "#f5f5f7"),
  "--color-background-ghost": "transparent",
  "--color-background-info": lightDark("rgba(0, 122, 255, 0.12)", "rgba(10, 132, 255, 0.2)"),
  "--color-background-danger": lightDark("rgba(255, 59, 48, 0.12)", "rgba(255, 69, 58, 0.2)"),
  "--color-background-success": lightDark("rgba(52, 199, 89, 0.14)", "rgba(48, 209, 88, 0.2)"),
  "--color-background-warning": lightDark("rgba(255, 149, 0, 0.14)", "rgba(255, 159, 10, 0.2)"),
  "--color-background-disabled": lightDark("rgba(0, 0, 0, 0.04)", "rgba(255, 255, 255, 0.05)"),
  "--color-text-primary": lightDark("rgba(0, 0, 0, 0.85)", "rgba(255, 255, 255, 0.85)"),
  "--color-text-secondary": lightDark("rgba(0, 0, 0, 0.5)", "rgba(255, 255, 255, 0.55)"),
  "--color-text-tertiary": lightDark("rgba(0, 0, 0, 0.26)", "rgba(255, 255, 255, 0.25)"),
  "--color-text-inverse": lightDark("rgba(255, 255, 255, 0.95)", "rgba(0, 0, 0, 0.85)"),
  "--color-text-info": lightDark(...accent.blue),
  "--color-text-danger": lightDark("#d70015", "#ff6961"),
  "--color-text-success": lightDark("#248a3d", "#30d158"),
  "--color-text-warning": lightDark("#c93400", "#ff9f0a"),
  "--color-text-disabled": lightDark("rgba(0, 0, 0, 0.25)", "rgba(255, 255, 255, 0.25)"),
  "--color-text-ghost": lightDark("rgba(0, 0, 0, 0.5)", "rgba(255, 255, 255, 0.55)"),
  "--color-border-primary": lightDark("rgba(0, 0, 0, 0.1)", "rgba(255, 255, 255, 0.1)"),
  "--color-border-secondary": lightDark("rgba(0, 0, 0, 0.16)", "rgba(255, 255, 255, 0.16)"),
  "--color-border-tertiary": lightDark("rgba(0, 0, 0, 0.05)", "rgba(255, 255, 255, 0.05)"),
  "--color-border-inverse": lightDark("rgba(255, 255, 255, 0.3)", "rgba(0, 0, 0, 0.3)"),
  "--color-border-ghost": "transparent",
  "--color-border-info": lightDark("rgba(0, 122, 255, 0.5)", "rgba(10, 132, 255, 0.5)"),
  "--color-border-danger": lightDark("rgba(255, 59, 48, 0.5)", "rgba(255, 69, 58, 0.5)"),
  "--color-border-success": lightDark("rgba(52, 199, 89, 0.5)", "rgba(48, 209, 88, 0.5)"),
  "--color-border-warning": lightDark("rgba(255, 149, 0, 0.5)", "rgba(255, 159, 10, 0.5)"),
  "--color-border-disabled": lightDark("rgba(0, 0, 0, 0.05)", "rgba(255, 255, 255, 0.05)"),
  "--color-ring-primary": lightDark(...accent.blue),
  "--color-ring-secondary": lightDark("rgba(0, 122, 255, 0.5)", "rgba(10, 132, 255, 0.5)"),
  "--color-ring-inverse": lightDark("#ffffff", "#000000"),
  "--color-ring-info": lightDark(...accent.blue),
  "--color-ring-danger": lightDark(...accent.red),
  "--color-ring-success": lightDark("#34c759", "#30d158"),
  "--color-ring-warning": lightDark("#ff9500", "#ff9f0a")
}

const fontVariables: Readonly<Record<string, string>> = {
  "--font-sans": '-apple-system, BlinkMacSystemFont, "Helvetica Neue", system-ui, sans-serif',
  "--font-mono": 'ui-monospace, "SF Mono", Menlo, monospace',
  "--font-weight-normal": "400",
  "--font-weight-medium": "500",
  "--font-weight-semibold": "600",
  "--font-weight-bold": "700"
}

const typeScale = (sizes: ReadonlyArray<readonly [string, number, number]>) =>
  Object.fromEntries(
    sizes.flatMap(([name, size, lineHeight]) => [
      [`--font-${name}-size`, `${size}px`],
      [`--font-${name}-line-height`, `${lineHeight}px`]
    ])
  )

const textSizes: Readonly<Record<AppPlatform, Readonly<Record<string, string>>>> = {
  desktop: typeScale([
    ["text-xs", 11, 14],
    ["text-sm", 12, 16],
    ["text-md", 13, 18],
    ["text-lg", 15, 20],
    ["heading-xs", 13, 16],
    ["heading-sm", 15, 20],
    ["heading-md", 17, 22],
    ["heading-lg", 20, 25],
    ["heading-xl", 22, 28],
    ["heading-2xl", 26, 32],
    ["heading-3xl", 30, 36]
  ]),
  mobile: typeScale([
    ["text-xs", 12, 16],
    ["text-sm", 15, 20],
    ["text-md", 17, 22],
    ["text-lg", 20, 25],
    ["heading-xs", 15, 20],
    ["heading-sm", 17, 22],
    ["heading-md", 20, 25],
    ["heading-lg", 22, 28],
    ["heading-xl", 28, 34],
    ["heading-2xl", 34, 41],
    ["heading-3xl", 40, 48]
  ])
}

const shadow = (geometry: string, light: number, dark: number): string =>
  `${geometry} ${lightDark(`rgba(0, 0, 0, ${light})`, `rgba(0, 0, 0, ${dark})`)}`

const shapeVariables: Readonly<Record<string, string>> = {
  "--border-radius-xs": "4px",
  "--border-radius-sm": "6px",
  "--border-radius-md": "8px",
  "--border-radius-lg": "10px",
  "--border-radius-xl": "14px",
  "--border-radius-full": "9999px",
  "--border-width-regular": "1px",
  "--shadow-hairline": shadow("0 0 0 0.5px", 0.12, 0.5),
  "--shadow-sm": shadow("0 1px 2px", 0.08, 0.3),
  "--shadow-md": shadow("0 4px 12px", 0.12, 0.4),
  "--shadow-lg": shadow("0 12px 32px", 0.18, 0.5)
}
