import { createFileRoute } from "@tanstack/react-router"
import { useState } from "react"

import { StatusBar } from "../../features/session/StatusBar"

export const Route = createFileRoute("/_shell/verify/pane-bar")({
  component: PaneBarFixtureRoute
})

const panes = [
  { id: "terminal-1", name: "Terminal 1" },
  { id: "terminal-2", name: "Terminal 2" },
  { id: "agent-dev", name: "bun run dev", attachOnly: true },
  { id: "agent-test", name: "background test runner", attachOnly: true }
]

function PaneBarFixtureRoute() {
  const [isVisible, setIsVisible] = useState(true)
  const [selectedPaneId, setSelectedPaneId] = useState("terminal-1")

  return (
    <div className="bg-background flex h-full flex-col">
      <div className="flex flex-1 items-center justify-center text-sm text-muted-foreground">
        Pane bar fixture
      </div>
      <StatusBar
        terminalVisible={isVisible}
        panes={panes}
        selectedPaneId={selectedPaneId}
        onToggleTerminal={() => setIsVisible((visible) => !visible)}
        onResizeTerminal={() => undefined}
        onSelectPane={setSelectedPaneId}
        onClosePane={() => undefined}
        onAddTerminalPane={() => undefined}
      />
      {isVisible && <div className="bg-terminal h-[280px] shrink-0" />}
    </div>
  )
}
