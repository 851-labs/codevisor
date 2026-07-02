import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

// Keyboard shortcut hint (⌘J, ↩). Rendered muted and slightly raised so it
// reads as a key cap next to menu items and buttons.
function Kbd({ className, ...props }: ComponentPropsWithRef<"kbd">) {
  return (
    <kbd
      data-slot="kbd"
      className={cn(
        "text-muted-foreground bg-muted inline-flex h-4.5 min-w-4.5 items-center justify-center rounded-sm px-1 font-sans text-[10px] font-medium",
        className
      )}
      {...props}
    />
  )
}

export { Kbd }
