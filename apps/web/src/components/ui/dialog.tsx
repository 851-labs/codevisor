import { Dialog as BaseDialog } from "@base-ui/react/dialog"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

const Dialog = BaseDialog.Root
const DialogTrigger = BaseDialog.Trigger
const DialogClose = BaseDialog.Close

function DialogContent({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseDialog.Popup>) {
  return (
    <BaseDialog.Portal>
      <BaseDialog.Backdrop className="fixed inset-0 z-50 bg-black/40 transition-opacity duration-150 data-[ending-style]:opacity-0 data-[starting-style]:opacity-0" />
      <BaseDialog.Popup
        data-slot="dialog-content"
        className={cn(
          "fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border p-5",
          "bg-[var(--herdman-popover-bg)] text-[var(--herdman-popover-fg)]",
          "border-[var(--herdman-popover-border)] shadow-[var(--herdman-popover-shadow)]",
          "outline-none transition-[transform,scale,opacity] duration-150",
          "data-[starting-style]:scale-95 data-[starting-style]:opacity-0",
          "data-[ending-style]:scale-95 data-[ending-style]:opacity-0",
          className
        )}
        {...props}
      >
        {children}
      </BaseDialog.Popup>
    </BaseDialog.Portal>
  )
}

function DialogTitle({ className, ...props }: ComponentPropsWithRef<typeof BaseDialog.Title>) {
  return (
    <BaseDialog.Title
      data-slot="dialog-title"
      className={cn("text-base font-semibold", className)}
      {...props}
    />
  )
}

function DialogDescription({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseDialog.Description>) {
  return (
    <BaseDialog.Description
      data-slot="dialog-description"
      className={cn("text-muted-foreground mt-1.5 text-sm", className)}
      {...props}
    />
  )
}

export { Dialog, DialogTrigger, DialogContent, DialogTitle, DialogDescription, DialogClose }
