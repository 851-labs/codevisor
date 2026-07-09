import { CheckIcon, CopyIcon } from "lucide-react"
import { memo, type SVGProps } from "react"
import { Streamdown, type ThemeInput } from "streamdown"

import { cn } from "../../lib/cn"
import { herdmanThemeResolver } from "../../theme/themeController"
import { useThemeSelection } from "../../theme/useThemeSelection"

// The resolved pierre/shiki theme object for a catalog name, falling back to
// a stock shiki theme until the resolver has it (the active scheme's theme is
// always resolved by the controller before it paints).
function shikiThemeFor(name: string, fallback: ThemeInput): ThemeInput {
  const resolved = herdmanThemeResolver.getResolvedTheme(name)
  return (resolved as ThemeInput | undefined) ?? fallback
}

function StreamdownCopyIcon({ size = 14 }: SVGProps<SVGSVGElement> & { size?: number }) {
  return (
    <CopyIcon
      className="shrink-0"
      data-herdman-streamdown-copy-state="copy"
      style={{ width: size, height: size }}
    />
  )
}

function StreamdownCheckIcon({ size = 14 }: SVGProps<SVGSVGElement> & { size?: number }) {
  return (
    <CheckIcon
      className="shrink-0"
      data-herdman-streamdown-copy-state="copied"
      style={{ width: size, height: size }}
    />
  )
}

// Streaming-safe markdown rendering (open fences/emphasis render gracefully
// mid-stream, block-level memoization keeps appends cheap). Streamdown is
// wrapped here so the renderer stays swappable; code blocks follow the
// selected pierre/shiki themes.
export const StreamingMarkdown = memo(function StreamingMarkdown({
  markdown,
  className
}: {
  markdown: string
  className?: string
}) {
  const { lightThemeName, darkThemeName } = useThemeSelection()
  return (
    <Streamdown
      className={cn("herdman-prose min-w-0 text-sm leading-relaxed", className)}
      shikiTheme={[
        shikiThemeFor(lightThemeName, "github-light"),
        shikiThemeFor(darkThemeName, "github-dark")
      ]}
      controls={{ code: { copy: true, download: false }, table: false, mermaid: false }}
      icons={{
        CheckIcon: StreamdownCheckIcon,
        CopyIcon: StreamdownCopyIcon
      }}
      parseIncompleteMarkdown
    >
      {markdown}
    </Streamdown>
  )
})
