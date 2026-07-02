// Compact relative time like "9h", "2d", "now" — port of the Swift
// RelativeTime.short helper.
export function relativeTimeShort(iso: string, now: Date = new Date()): string {
  const date = new Date(iso)
  const seconds = Math.max(0, (now.getTime() - date.getTime()) / 1000)
  if (seconds < 60) return "now"
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`
  return `${Math.floor(seconds / 86_400)}d`
}
