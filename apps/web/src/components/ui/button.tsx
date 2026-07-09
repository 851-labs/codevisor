import { cva, type VariantProps } from "class-variance-authority"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

const buttonVariants = cva(
  "inline-flex shrink-0 cursor-default items-center justify-center gap-1.5 rounded-md text-sm font-medium whitespace-nowrap transition-colors outline-none focus-visible:ring-2 focus-visible:ring-ring/50 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground hover:bg-primary/90",
        secondary: "bg-secondary text-secondary-foreground hover:bg-secondary/80",
        outline: "border border-border bg-transparent hover:bg-accent hover:text-accent-foreground",
        ghost: "text-foreground hover:bg-accent hover:text-accent-foreground",
        destructive: "bg-destructive text-white hover:bg-destructive/90"
      },
      size: {
        default: "h-8 px-3 [&_svg]:size-4",
        sm: "h-7 rounded-md px-2 text-xs [&_svg]:size-3.5",
        lg: "h-9 px-4 [&_svg]:size-4",
        icon: "size-8 rounded-md [&_svg]:size-4",
        "icon-sm": "size-6 rounded-sm [&_svg]:size-3.5"
      }
    },
    defaultVariants: {
      variant: "default",
      size: "default"
    }
  }
)

type ButtonProps = ComponentPropsWithRef<"button"> & VariantProps<typeof buttonVariants>

function Button({ className, variant, size, type = "button", ...props }: ButtonProps) {
  return (
    <button
      data-slot="button"
      type={type}
      className={cn(buttonVariants({ variant, size }), className)}
      {...props}
    />
  )
}

export { Button, buttonVariants }
