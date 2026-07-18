/* Usage gauge and popover are temporarily disabled.
import type { HarnessUsageLimits } from "@codevisor/api"
import type { UsageInfo } from "../../lib/session-events"
import { useEffect, useRef, useState } from "react"
import { cn } from "../../lib/cn"
import { Spinner } from "../../components/ui/spinner"

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
  if (usage.used != null) {
    if (usage.size != null && usage.size > 0) {
      parts.push(`Context ${usageContextPercent(usage)} percent used`)
    }
    parts.push(formatUsageTokens(usage.used, usage.size))
  }
  if (usage.totalTokens != null)
    parts.push(`${abbreviateUsageValue(usage.totalTokens)} total session tokens`)
  if (usage.costAmount != null)
    parts.push(`Cost ${formatUsageCost(usage.costAmount, usage.costCurrency)}`)
  return parts.join(", ")
}

export function usageFraction(usage: UsageInfo): number {
  if (usage.used == null || usage.size == null || usage.size <= 0) return 0
  return Math.min(usage.used / usage.size, 1)
}

export function usageContextPercent(usage: UsageInfo): number {
  return Math.round(usageFraction(usage) * 100)
}

export function shouldShowCreditsBalance(balance: string | undefined): balance is string {
  if (balance == null || balance.trim() === "") return false
  const numericCharacters = balance.replace(/[^\d.+-]/g, "")
  if (!/\d/.test(numericCharacters)) return true
  const numericValue = Number(numericCharacters)
  return !Number.isFinite(numericValue) || numericValue !== 0
}

export function UsageRingButton({
  usage,
  limits,
  isLoadingLimits = false,
  limitsError,
  onRequestLimits,
  forcePopover = false
}: {
  usage?: UsageInfo
  limits?: HarnessUsageLimits
  isLoadingLimits?: boolean
  limitsError?: string
  onRequestLimits?: () => void
  forcePopover?: boolean
}) {
  const [isPopoverShown, setIsPopoverShown] = useState(false)
  const hideTimeout = useRef<number | undefined>(undefined)

  useEffect(() => {
    return () => {
      if (hideTimeout.current != null) window.clearTimeout(hideTimeout.current)
    }
  }, [])

  if (usage == null || !hasVisibleUsage(usage)) return null

  const showPopover = () => {
    if (hideTimeout.current != null) window.clearTimeout(hideTimeout.current)
    setIsPopoverShown(true)
    onRequestLimits?.()
  }
  const scheduleHidePopover = () => {
    if (hideTimeout.current != null) window.clearTimeout(hideTimeout.current)
    hideTimeout.current = window.setTimeout(() => setIsPopoverShown(false), 200)
  }

  const fraction = usageFraction(usage)
  const circumference = 2 * Math.PI * 7
  const contextPercent = usageContextPercent(usage)
  const ringColor = fraction > 0.85 ? "var(--codevisor-status-warn)" : "var(--codevisor-accent)"

  return (
    <div
      className="relative flex size-[26px] cursor-default items-center justify-center rounded-full outline-none"
      onMouseEnter={showPopover}
      onMouseLeave={scheduleHidePopover}
    >
      <svg
        aria-label={usageAccessibilityLabel(usage)}
        role={usage.used != null && usage.size != null && usage.size > 0 ? "progressbar" : "img"}
        aria-valuemin={usage.used != null && usage.size != null && usage.size > 0 ? 0 : undefined}
        aria-valuemax={usage.used != null && usage.size != null && usage.size > 0 ? 100 : undefined}
        aria-valuenow={
          usage.used != null && usage.size != null && usage.size > 0 ? contextPercent : undefined
        }
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
        role="tooltip"
        onMouseEnter={showPopover}
        onMouseLeave={scheduleHidePopover}
        className={cn(
          "border-border bg-popover text-popover-foreground absolute right-0 bottom-full z-40 mb-2 w-72 rounded-xl border p-3.5 text-xs shadow-xl",
          forcePopover || isPopoverShown ? "block" : "hidden"
        )}
      >
        <SessionUsageContent usage={usage} contextPercent={contextPercent} />
        <AccountLimitsContent limits={limits} isLoading={isLoadingLimits} error={limitsError} />
      </div>
    </div>
  )
}

function SessionUsageContent({
  usage,
  contextPercent
}: {
  usage: UsageInfo
  contextPercent: number
}) {
  return (
    <section aria-label="Session usage">
      <dl className="grid grid-cols-[1fr_auto] gap-x-4 gap-y-1.5">
        {usage.totalTokens != null && (
          <UsageMetric label="Total tokens" value={abbreviateUsageValue(usage.totalTokens)} />
        )}
        {usage.inputTokens != null && (
          <UsageMetric label="Input" value={abbreviateUsageValue(usage.inputTokens)} />
        )}
        {usage.cachedInputTokens != null && (
          <UsageMetric label="Cached input" value={abbreviateUsageValue(usage.cachedInputTokens)} />
        )}
        {usage.outputTokens != null && (
          <UsageMetric label="Output" value={abbreviateUsageValue(usage.outputTokens)} />
        )}
        {usage.reasoningOutputTokens != null && (
          <UsageMetric
            label="Reasoning output"
            value={abbreviateUsageValue(usage.reasoningOutputTokens)}
          />
        )}
        {usage.costAmount != null && (
          <UsageMetric label="Cost" value={formatUsageCost(usage.costAmount, usage.costCurrency)} />
        )}
      </dl>
      {usage.used != null && usage.size != null && usage.size > 0 && (
        <div className="mt-3 space-y-1.5">
          <div className="flex items-baseline justify-between gap-3">
            <span className="text-muted-foreground">Session usage</span>
            <span className="font-medium tabular-nums">
              {formatUsageTokens(usage.used, usage.size)}
            </span>
          </div>
          <div className="h-1.5 overflow-hidden rounded-full bg-[color-mix(in_srgb,var(--foreground)_10%,transparent)]">
            <div
              className="h-full rounded-full bg-[var(--codevisor-accent)] transition-[width] duration-300"
              style={{ width: `${contextPercent}%` }}
            />
          </div>
        </div>
      )}
    </section>
  )
}

function AccountLimitsContent({
  limits,
  isLoading,
  error
}: {
  limits?: HarnessUsageLimits
  isLoading: boolean
  error?: string
}) {
  if (!isLoading && error == null && limits?.state !== "available") return null

  return (
    <section aria-label="Account limits" className="mt-3.5">
      {isLoading && limits == null ? (
        <div className="flex items-center gap-2 py-2 text-muted-foreground">
          <Spinner />
          <span>Loading harness limits…</span>
        </div>
      ) : error != null && limits == null ? (
        <p className="text-[var(--codevisor-status-error)]">{error}</p>
      ) : limits?.state === "available" ? (
        <div className="space-y-3">
          {limits.windows.map((window) => (
            <LimitWindow key={window.id} window={window} />
          ))}
          {shouldShowCreditsBalance(limits.credits?.balance) && (
            <dl className="grid grid-cols-[1fr_auto] gap-x-4">
              <UsageMetric label="Credits" value={limits.credits.balance} />
            </dl>
          )}
        </div>
      ) : null}
    </section>
  )
}

function LimitWindow({ window }: { window: HarnessUsageLimits["windows"][number] }) {
  const percent = Math.max(0, Math.min(100, window.usedPercent))
  return (
    <div className="space-y-1.5">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-muted-foreground">{window.label}</span>
        <span className="font-medium tabular-nums">{Math.round(percent)}% used</span>
      </div>
      <div className="h-1 overflow-hidden rounded-full bg-[color-mix(in_srgb,var(--foreground)_10%,transparent)]">
        <div
          className="h-full rounded-full bg-[var(--codevisor-accent)]"
          style={{ width: `${percent}%` }}
        />
      </div>
      {formatReset(window.resetsAt) != null && (
        <p className="text-muted-foreground text-[11px]">{formatReset(window.resetsAt)}</p>
      )}
    </div>
  )
}

function UsageMetric({ label, value }: { label: string; value: string }) {
  return (
    <>
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="text-right font-medium tabular-nums">{value}</dd>
    </>
  )
}

function hasVisibleUsage(usage: UsageInfo): boolean {
  return (
    usage.used != null ||
    usage.inputTokens != null ||
    usage.cachedInputTokens != null ||
    usage.outputTokens != null ||
    usage.reasoningOutputTokens != null ||
    usage.totalTokens != null ||
    usage.costAmount != null
  )
}

function formatReset(value: string | undefined): string | undefined {
  if (value == null) return undefined
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return undefined
  return `Resets ${new Intl.DateTimeFormat(undefined, {
    weekday: "short",
    hour: "numeric",
    minute: "2-digit"
  }).format(date)}`
}
*/

export {}
