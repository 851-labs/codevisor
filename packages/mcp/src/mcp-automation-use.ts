import type { AutomationToolProvider } from "@codevisor/automation"

/// The automation tool a session's agent touched last: the live preview
/// card shows that tool's view when both have something to show.
export type AutomationTool = "browser" | "computer"

export const makeAutomationUse = () => {
  const latest = new Map<string, AutomationTool>()
  const listeners = new Map<string, Set<(tool: AutomationTool) => void>>()

  const used = (sessionId: string, tool: AutomationTool): void => {
    if (latest.get(sessionId) === tool) return
    latest.set(sessionId, tool)
    for (const listener of listeners.get(sessionId) ?? []) listener(tool)
  }

  /// Calls `listener` with the session's latest tool now, if any, and on
  /// every switch after. Returns the unsubscribe.
  const subscribe = (sessionId: string, listener: (tool: AutomationTool) => void): (() => void) => {
    const current = latest.get(sessionId)
    if (current !== undefined) listener(current)
    const set = listeners.get(sessionId) ?? new Set()
    set.add(listener)
    listeners.set(sessionId, set)
    return () => {
      set.delete(listener)
      if (set.size === 0 && listeners.get(sessionId) === set) listeners.delete(sessionId)
    }
  }

  /// The provider, noting each call as a use of its tool. Every call
  /// counts, whether or not it shows anything: the card only switches to a
  /// tool with a view to show.
  const track = (provider: AutomationToolProvider): AutomationToolProvider => {
    const tool = provider.id
    if (tool === "codevisor") return provider
    return {
      ...provider,
      invoke: (context, toolName, args) => {
        used(context.sessionId, tool)
        return provider.invoke(context, toolName, args)
      },
      closeSession: (sessionId) => {
        latest.delete(sessionId)
        return provider.closeSession(sessionId)
      }
    }
  }

  return { subscribe, track }
}
