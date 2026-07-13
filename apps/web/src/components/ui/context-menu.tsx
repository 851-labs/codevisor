import { ContextMenu as BaseContextMenu } from "@base-ui/react/context-menu"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"
import { menuItemClassName, popupSurfaceClassName, popupViewportClassName } from "./menu"

const ContextMenu = BaseContextMenu.Root
const ContextMenuTrigger = BaseContextMenu.Trigger

function ContextMenuContent({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseContextMenu.Popup>) {
  return (
    <BaseContextMenu.Portal>
      <BaseContextMenu.Positioner className="z-50">
        <BaseContextMenu.Popup
          data-slot="context-menu-content"
          className={cn(popupSurfaceClassName, popupViewportClassName, className)}
          {...props}
        >
          {children}
        </BaseContextMenu.Popup>
      </BaseContextMenu.Positioner>
    </BaseContextMenu.Portal>
  )
}

function ContextMenuItem({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseContextMenu.Item>) {
  return (
    <BaseContextMenu.Item
      data-slot="context-menu-item"
      className={cn(menuItemClassName, className)}
      {...props}
    />
  )
}

function ContextMenuSeparator({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseContextMenu.Separator>) {
  return (
    <BaseContextMenu.Separator
      data-slot="context-menu-separator"
      className={cn("my-1 h-px bg-[var(--codevisor-popover-border)]", className)}
      {...props}
    />
  )
}

export {
  ContextMenu,
  ContextMenuTrigger,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator
}
