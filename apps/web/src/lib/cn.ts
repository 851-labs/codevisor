import { type ClassValue, clsx } from "clsx"
import { twMerge } from "tailwind-merge"

// Merges conditional class values and resolves Tailwind conflicts (the shadcn
// `cn` idiom). Every kit component funnels className composition through this.
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs))
}
