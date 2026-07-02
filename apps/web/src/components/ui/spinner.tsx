import { LoaderCircleIcon } from "lucide-react"

import { cn } from "../../lib/cn"

function Spinner({ className }: { className?: string }) {
  return (
    <LoaderCircleIcon
      data-slot="spinner"
      aria-label="Loading"
      className={cn("text-muted-foreground size-3.5 animate-spin", className)}
    />
  )
}

export { Spinner }
