import type { UsageInfo } from "../../lib/session-events"
import { useEffect, useRef, useState } from "react"
import { cn } from "../../lib/cn"

export function abbreviateUsageValue(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return `${value}`
}

export function formatUsageCost(amount: number, currency: string | undefined): string {
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: currency ?? "USD",
      maximumFractionDigits: amount < 1 ? 4 : 2
    }).format(amount)
  } catch {
    return amount.toFixed(4)
  }
}

export function formatUsageTokens(used: number, size: number | undefined): string {
  if (size != null && size > 0) {
    return `${abbreviateUsageValue(used)} / ${abbreviateUsageValue(size)} tokens`
  }
  return `${abbreviateUsageValue(used)} tokens`
}

export function usageAccessibilityLabel(usage: UsageInfo): string {
  const parts: string[] = []
  if (usage.costAmount != null)
    parts.push(`Cost ${formatUsageCost(usage.costAmount, usage.costCurrency)}`)
  if (usage.used != null) parts.push(formatUsageTokens(usage.used, usage.size))
  return parts.join(", ")
}

export function usageFraction(usage: UsageInfo): number {
  if (usage.used == null || usage.size == null || usage.size <= 0) return 0
  return Math.min(usage.used / usage.size, 1)
}

export function usageContextPercent(usage: UsageInfo): number {
  return Math.round(usageFraction(usage) * 100)
}

export function UsageRingButton({
  usage,
  forcePopover = false
}: {
  usage?: UsageInfo
  forcePopover?: boolean
}) {
  const [isPopoverShown, setIsPopoverShown] = useState(false)
  const hideTimeout = useRef<number | undefined>(undefined)

  useEffect(() => {
    return () => {
      if (hideTimeout.current != null) window.clearTimeout(hideTimeout.current)
    }
  }, [])

  if (usage == null || (usage.used == null && usage.costAmount == null)) return null

  const showPopover = () => {
    if (hideTimeout.current != null) window.clearTimeout(hideTimeout.current)
    setIsPopoverShown(true)
  }
  const scheduleHidePopover = () => {
    if (hideTimeout.current != null) window.clearTimeout(hideTimeout.current)
    hideTimeout.current = window.setTimeout(() => setIsPopoverShown(false), 120)
  }

  const fraction = usageFraction(usage)
  const circumference = 2 * Math.PI * 7
  const contextPercent = usageContextPercent(usage)
  const ringColor = fraction > 0.85 ? "var(--herdman-status-warn)" : "var(--herdman-accent)"

  return (
    <div
      className="relative flex size-[26px] cursor-default items-center justify-center rounded-full outline-none"
      onMouseEnter={showPopover}
      onMouseLeave={scheduleHidePopover}
    >
      <svg
        aria-label={usageAccessibilityLabel(usage)}
        role="img"
        viewBox="0 0 18 18"
        className="size-[18px]"
      >
        <circle
          cx="9"
          cy="9"
          r="7"
          fill="none"
          stroke="currentColor"
          strokeOpacity="0.25"
          strokeWidth="2.5"
          className="text-muted-foreground"
        />
        <circle
          cx="9"
          cy="9"
          r="7"
          fill="none"
          stroke={ringColor}
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - fraction)}
          transform="rotate(-90 9 9)"
        />
      </svg>
      <div
        className={cn(
          "border-border bg-popover text-popover-foreground pointer-events-none absolute right-0 bottom-full z-40 mb-2 min-w-44 rounded-lg border p-2.5 text-xs shadow-lg",
          forcePopover || isPopoverShown ? "block" : "hidden"
        )}
      >
        <div className="grid grid-cols-[52px_1fr] gap-x-3 gap-y-1.5">
          {usage.costAmount != null && (
            <>
              <span className="text-muted-foreground">Cost</span>
              <span className="font-medium">
                {formatUsageCost(usage.costAmount, usage.costCurrency)}
              </span>
            </>
          )}
          {usage.used != null && (
            <>
              <span className="text-muted-foreground">Tokens</span>
              <span className="font-medium">{formatUsageTokens(usage.used, usage.size)}</span>
            </>
          )}
          {usage.used != null && usage.size != null && usage.size > 0 && (
            <>
              <span className="text-muted-foreground">Context</span>
              <span className="font-medium">{contextPercent}% used</span>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
