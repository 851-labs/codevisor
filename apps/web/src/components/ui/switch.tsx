import { Switch as BaseSwitch } from "@base-ui/react/switch"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

function Switch({ className, ...props }: ComponentPropsWithRef<typeof BaseSwitch.Root>) {
  return (
    <BaseSwitch.Root
      data-slot="switch"
      className={cn(
        "bg-input inline-flex h-5 w-8.5 shrink-0 cursor-default items-center rounded-full p-0.5 transition-colors outline-none",
        "focus-visible:ring-ring/50 focus-visible:ring-2",
        "data-[checked]:bg-primary",
        "disabled:pointer-events-none disabled:opacity-50",
        className
      )}
      {...props}
    >
      <BaseSwitch.Thumb
        className={cn(
          "bg-background size-4 rounded-full shadow-sm transition-transform",
          "data-[checked]:translate-x-3.5"
        )}
      />
    </BaseSwitch.Root>
  )
}

export { Switch }
