import { Select as BaseSelect } from "@base-ui/react/select"
import { CheckIcon, ChevronsUpDownIcon } from "lucide-react"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"
import { menuItemClassName, popupSurfaceClassName, popupViewportClassName } from "./menu"

const Select = BaseSelect.Root
const SelectValue = BaseSelect.Value
const SelectGroup = BaseSelect.Group

function SelectTrigger({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseSelect.Trigger>) {
  return (
    <BaseSelect.Trigger
      data-slot="select-trigger"
      className={cn(
        "border-input flex h-8 w-full cursor-default items-center justify-between gap-2 rounded-md border bg-transparent px-2.5 text-sm outline-none",
        "focus-visible:ring-ring/50 focus-visible:ring-2",
        "data-[popup-open]:bg-accent",
        "disabled:pointer-events-none disabled:opacity-50",
        className
      )}
      {...props}
    >
      {children}
      <BaseSelect.Icon className="flex">
        <ChevronsUpDownIcon className="text-muted-foreground size-3.5" />
      </BaseSelect.Icon>
    </BaseSelect.Trigger>
  )
}

function SelectContent({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseSelect.Popup>) {
  return (
    <BaseSelect.Portal>
      <BaseSelect.Positioner className="z-50 outline-none" sideOffset={4}>
        <BaseSelect.ScrollUpArrow className="top-0 z-10 flex h-5 w-full items-center justify-center rounded-t-lg bg-[var(--codevisor-popover-bg)] text-xs" />
        <BaseSelect.Popup
          data-slot="select-content"
          className={cn(popupSurfaceClassName, popupViewportClassName, className)}
          {...props}
        >
          {children}
        </BaseSelect.Popup>
        <BaseSelect.ScrollDownArrow className="bottom-0 z-10 flex h-5 w-full items-center justify-center rounded-b-lg bg-[var(--codevisor-popover-bg)] text-xs" />
      </BaseSelect.Positioner>
    </BaseSelect.Portal>
  )
}

function SelectItem({
  className,
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseSelect.Item>) {
  return (
    <BaseSelect.Item
      data-slot="select-item"
      className={cn(menuItemClassName, "relative pl-7", className)}
      {...props}
    >
      <BaseSelect.ItemIndicator className="absolute left-2 inline-flex">
        <CheckIcon className="size-3.5" />
      </BaseSelect.ItemIndicator>
      <BaseSelect.ItemText>{children}</BaseSelect.ItemText>
    </BaseSelect.Item>
  )
}

function SelectGroupLabel({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseSelect.GroupLabel>) {
  return (
    <BaseSelect.GroupLabel
      data-slot="select-group-label"
      className={cn(
        "px-2.5 py-1.5 text-xs font-medium text-[var(--codevisor-popover-muted-fg)]",
        className
      )}
      {...props}
    />
  )
}

function SelectSeparator({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseSelect.Separator>) {
  return (
    <BaseSelect.Separator
      data-slot="select-separator"
      className={cn("my-1 h-px bg-[var(--codevisor-popover-border)]", className)}
      {...props}
    />
  )
}

export {
  Select,
  SelectTrigger,
  SelectValue,
  SelectContent,
  SelectItem,
  SelectGroup,
  SelectGroupLabel,
  SelectSeparator
}
