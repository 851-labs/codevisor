import { FitAddon } from "@xterm/addon-fit"
import { Terminal } from "@xterm/xterm"
import { useEffect, useRef } from "react"
import "@xterm/xterm/css/xterm.css"

import { useApi } from "../../lib/api"
import { TerminalTransport } from "../../lib/terminal"
import { useThemeSource } from "../../theme/useThemeSource"
import { xtermThemeFrom } from "./xtermTheme"

// The embedded terminal panel: an xterm surface over the server's PTY
// WebSocket, themed to the active pierre/shiki theme, refit on resize.
export function TerminalPanel({ sessionId, cwd }: { sessionId: string; cwd: string }) {
  const { client, config } = useApi()
  const containerRef = useRef<HTMLDivElement>(null)
  const terminalRef = useRef<Terminal | undefined>(undefined)
  const { activeTheme } = useThemeSource()

  useEffect(() => {
    const container = containerRef.current
    if (container == null) return

    const terminal = new Terminal({
      fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace",
      fontSize: 12,
      cursorBlink: true,
      allowProposedApi: true
    })
    terminalRef.current = terminal
    const fit = new FitAddon()
    terminal.loadAddon(fit)
    terminal.open(container)
    fit.fit()

    const transport = new TerminalTransport(client, config, {
      onOutput: (data) => terminal.write(data),
      onExit: (exitCode) => {
        terminal.writeln(`\r\n[process exited${exitCode != null ? ` with code ${exitCode}` : ""}]`)
      },
      onError: (message) => {
        terminal.writeln(`\r\n[terminal error: ${message}]`)
      }
    })

    const inputDisposable = terminal.onData((data) => transport.sendInput(data))
    const resizeDisposable = terminal.onResize(({ cols, rows }) => transport.sendResize(cols, rows))

    void transport.open({ sessionId, cwd, cols: terminal.cols, rows: terminal.rows })

    const observer = new ResizeObserver(() => fit.fit())
    observer.observe(container)

    terminal.focus()

    return () => {
      observer.disconnect()
      inputDisposable.dispose()
      resizeDisposable.dispose()
      transport.close()
      terminal.dispose()
      terminalRef.current = undefined
    }
    // The terminal lives for the panel's lifetime; theme updates are applied
    // by the effect below without recreating the PTY.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, cwd, client, config])

  useEffect(() => {
    const terminal = terminalRef.current
    if (terminal == null) return
    terminal.options.theme = xtermThemeFrom(activeTheme.theme)
  }, [activeTheme.theme])

  return <div ref={containerRef} className="bg-terminal h-full w-full px-2 pt-1" />
}
