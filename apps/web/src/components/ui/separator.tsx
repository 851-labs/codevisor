import { Separator as BaseSeparator } from "@base-ui/react/separator"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

function Separator({
  className,
  orientation = "horizontal",
  ...props
}: ComponentPropsWithRef<typeof BaseSeparator>) {
  return (
    <BaseSeparator
      data-slot="separator"
      orientation={orientation}
      className={cn(
        "bg-border-opaque shrink-0",
        orientation === "horizontal" ? "h-px w-full" : "h-full w-px",
        className
      )}
      {...props}
    />
  )
}

export { Separator }
