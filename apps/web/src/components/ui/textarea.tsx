import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

// Kit styling only — autosize behavior lives in the composer feature.
function Textarea({ className, ...props }: ComponentPropsWithRef<"textarea">) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        "text-foreground placeholder:text-muted-foreground w-full resize-none bg-transparent text-sm outline-none",
        "disabled:pointer-events-none disabled:opacity-50",
        className
      )}
      {...props}
    />
  )
}

export { Textarea }
