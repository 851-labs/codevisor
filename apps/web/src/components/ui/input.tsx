import { Input as BaseInput } from "@base-ui/react/input"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

function Input({ className, ...props }: ComponentPropsWithRef<typeof BaseInput>) {
  return (
    <BaseInput
      data-slot="input"
      className={cn(
        "border-input bg-transparent text-foreground placeholder:text-muted-foreground h-8 w-full min-w-0 rounded-md border px-2.5 py-1 text-sm transition-colors outline-none",
        "focus-visible:ring-ring/50 focus-visible:border-ring focus-visible:ring-2",
        "disabled:pointer-events-none disabled:opacity-50",
        className
      )}
      {...props}
    />
  )
}

export { Input }
