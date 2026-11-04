import type { McpManager } from "@codevisor/mcp"

export const settles = async (manager: McpManager, id: string, state: string) => {
  while (true) {
    const changed = Promise.withResolvers<void>()
    const unsubscribe = manager.subscribeServersChanged((changedId) => {
      if (changedId === id) changed.resolve()
    })
    try {
      const current = (await manager.list()).find((server) => server.id === id)
      if (current?.connectionState === state) return current
      await changed.promise
    } finally {
      unsubscribe()
    }
  }
}
