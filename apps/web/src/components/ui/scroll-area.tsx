import { ScrollArea as BaseScrollArea } from "@base-ui/react/scroll-area"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

function ScrollArea({
  className,
  children,
  viewportClassName,
  ...props
}: ComponentPropsWithRef<typeof BaseScrollArea.Root> & { viewportClassName?: string }) {
  return (
    <BaseScrollArea.Root
      data-slot="scroll-area"
      className={cn("relative overflow-hidden", className)}
      {...props}
    >
      <BaseScrollArea.Viewport className={cn("size-full overscroll-contain", viewportClassName)}>
        {children}
      </BaseScrollArea.Viewport>
      <BaseScrollArea.Scrollbar
        orientation="vertical"
        className="flex w-2.5 justify-center px-0.5 py-1 opacity-0 transition-opacity data-[hovering]:opacity-100 data-[scrolling]:opacity-100"
      >
        <BaseScrollArea.Thumb className="w-full rounded-full bg-[var(--codevisor-scrollbar-thumb-bg)]" />
      </BaseScrollArea.Scrollbar>
    </BaseScrollArea.Root>
  )
}

export { ScrollArea }
