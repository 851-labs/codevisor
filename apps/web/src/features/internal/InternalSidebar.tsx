import { Link } from "@tanstack/react-router"
import {
  ArrowLeftIcon,
  BlocksIcon,
  ListTodoIcon,
  MessageSquareIcon,
  PanelBottomIcon,
  SquarePenIcon
} from "lucide-react"

import { cn } from "../../lib/cn"
import { sidebarRowClassName } from "../sidebar/SessionRow"

const internalRoutes = [
  { to: "/internal/storybook", label: "Components", icon: BlocksIcon },
  { to: "/verify/chat-parity", label: "Chat", icon: MessageSquareIcon },
  { to: "/verify/chat-composer", label: "Composer", icon: SquarePenIcon },
  { to: "/verify/session-setup", label: "Session setup", icon: ListTodoIcon },
  { to: "/verify/pane-bar", label: "Pane bar", icon: PanelBottomIcon }
] as const

export function InternalSidebar() {
  return (
    <aside className="flex h-full w-full flex-col">
      <div className="p-2">
        <Link to="/" search={{}} className={cn(sidebarRowClassName, "text-muted-foreground")}>
          <ArrowLeftIcon className="size-4 shrink-0" />
          <span>Back to Codevisor</span>
        </Link>
      </div>

      <div className="border-border-opaque mx-2 border-t" />

      <nav className="flex min-h-0 flex-1 flex-col gap-px overflow-y-auto p-2">
        <div className="text-muted-foreground flex items-center gap-1.5 px-2 py-1.5 text-xs font-semibold">
          <BlocksIcon className="size-3.5" />
          <span>Internal UI</span>
        </div>
        {internalRoutes.map(({ to, label, icon: Icon }) => (
          <Link
            key={to}
            to={to}
            className={cn(sidebarRowClassName, "text-muted-foreground")}
            activeProps={{
              className: "bg-[var(--codevisor-row-selected-bg)] text-foreground"
            }}
          >
            <Icon className="size-4 shrink-0" />
            <span>{label}</span>
          </Link>
        ))}
      </nav>
    </aside>
  )
}
