import { Menu as BaseMenu } from "@base-ui/react/menu"
import { CheckIcon, ChevronRightIcon } from "lucide-react"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

// Shared popup surface classes for menu-family popups (menu, context menu,
// select). Reads the chrome-derived popover tokens.
export const popupSurfaceClassName = cn(
  "z-50 min-w-36 rounded-lg border py-1",
  "bg-[var(--codevisor-popover-bg)] text-[var(--codevisor-popover-fg)]",
  "border-[var(--codevisor-popover-border)] shadow-[var(--codevisor-popover-shadow)]",
  "outline-none transition-[transform,scale,opacity] duration-100",
  "data-[starting-style]:scale-95 data-[starting-style]:opacity-0",
  "data-[ending-style]:scale-95 data-[ending-style]:opacity-0"
)

export const popupViewportClassName =
  "max-h-[min(24rem,var(--available-height))] max-w-[var(--available-width)] overflow-y-auto overscroll-contain"

export const menuItemClassName = cn(
  "flex cursor-default items-center gap-2 px-2.5 py-1.5 text-sm outline-none select-none",
  "data-[highlighted]:bg-[var(--codevisor-popover-hover-bg)]",
  "data-[disabled]:pointer-events-none data-[disabled]:opacity-50",
  "[&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0"
)

const Menu = BaseMenu.Root
const MenuTrigger = BaseMenu.Trigger
const MenuGroup = BaseMenu.Group
const MenuRadioGroup = BaseMenu.RadioGroup
const MenuSubmenuRoot = BaseMenu.SubmenuRoot

function MenuContent({
  className,
  sideOffset = 4,
  align = "start",
  side,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseMenu.Popup> & {
  sideOffset?: number
  align?: ComponentPropsWithRef<typeof BaseMenu.Positioner>["align"]
  side?: ComponentPropsWithRef<typeof BaseMenu.Positioner>["side"]
}) {
  return (
    <BaseMenu.Portal>
      <BaseMenu.Positioner align={align} side={side} sideOffset={sideOffset} className="z-50">
        <BaseMenu.Popup
          data-slot="menu-content"
          className={cn(popupSurfaceClassName, popupViewportClassName, className)}
          {...props}
        >
          {children}
        </BaseMenu.Popup>
      </BaseMenu.Positioner>
    </BaseMenu.Portal>
  )
}

function MenuItem({ className, ...props }: ComponentPropsWithRef<typeof BaseMenu.Item>) {
  return (
    <BaseMenu.Item data-slot="menu-item" className={cn(menuItemClassName, className)} {...props} />
  )
}

function MenuCheckboxItem({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseMenu.CheckboxItem>) {
  return (
    <BaseMenu.CheckboxItem
      data-slot="menu-checkbox-item"
      className={cn(menuItemClassName, "pl-7", className)}
      {...props}
    >
      <BaseMenu.CheckboxItemIndicator className="absolute left-2 inline-flex">
        <CheckIcon className="size-3.5" />
      </BaseMenu.CheckboxItemIndicator>
      {children}
    </BaseMenu.CheckboxItem>
  )
}

function MenuRadioItem({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseMenu.RadioItem>) {
  return (
    <BaseMenu.RadioItem
      data-slot="menu-radio-item"
      className={cn(menuItemClassName, "relative pl-7", className)}
      {...props}
    >
      <BaseMenu.RadioItemIndicator className="absolute left-2 inline-flex">
        <CheckIcon className="size-3.5" />
      </BaseMenu.RadioItemIndicator>
      {children}
    </BaseMenu.RadioItem>
  )
}

function MenuGroupLabel({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseMenu.GroupLabel>) {
  return (
    <BaseMenu.GroupLabel
      data-slot="menu-group-label"
      className={cn(
        "px-2.5 py-1.5 text-xs font-medium text-[var(--codevisor-popover-muted-fg)]",
        className
      )}
      {...props}
    />
  )
}

function MenuSeparator({ className, ...props }: ComponentPropsWithRef<typeof BaseMenu.Separator>) {
  return (
    <BaseMenu.Separator
      data-slot="menu-separator"
      className={cn("my-1 h-px bg-[var(--codevisor-popover-border)]", className)}
      {...props}
    />
  )
}

function MenuSubmenuTrigger({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseMenu.SubmenuTrigger>) {
  return (
    <BaseMenu.SubmenuTrigger
      data-slot="menu-submenu-trigger"
      className={cn(
        menuItemClassName,
        "data-[popup-open]:bg-[var(--codevisor-popover-hover-bg)]",
        className
      )}
      {...props}
    >
      {children}
      <ChevronRightIcon className="ml-auto size-3.5" />
    </BaseMenu.SubmenuTrigger>
  )
}

export {
  Menu,
  MenuTrigger,
  MenuContent,
  MenuItem,
  MenuCheckboxItem,
  MenuRadioGroup,
  MenuRadioItem,
  MenuGroup,
  MenuGroupLabel,
  MenuSeparator,
  MenuSubmenuRoot,
  MenuSubmenuTrigger
}
