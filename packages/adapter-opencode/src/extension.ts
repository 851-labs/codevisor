import type { AcpStdioExtensionFactory } from "@codevisor/adapter-acp"

import { withSkillRead } from "./skill-tool.js"
import {
  CHILD_SESSION_UPDATES_CAPABILITY,
  CHILD_UPDATE_METHOD,
  OpenCodeSubagents
} from "./subagents.js"

/// OpenCode's additions to an ACP chat connection: its subagents' own
/// sessions stream in (see `OpenCodeSubagents`), and its own `skill` tool
/// reads like a Codevisor skill read (see `skillReadUpdate`).
export const makeOpenCodeExtension: AcpStdioExtensionFactory = ({ emit }) => {
  const subagents = new OpenCodeSubagents()
  const childUpdate = (params: unknown): void => {
    for (const event of subagents.childUpdate(withSkillRead(params))) emit(event)
  }
  return {
    customizeClientCapabilities: (capabilities) => ({
      ...capabilities,
      _meta: { ...capabilities._meta, [CHILD_SESSION_UPDATES_CAPABILITY]: true }
    }),
    configureClientApp: (app) => {
      app.onNotification<unknown>(
        CHILD_UPDATE_METHOD,
        (params) => params,
        ({ params }) => childUpdate(params)
      )
      return app
    },
    mapSessionNotification: (notification) => subagents.mapNotification(withSkillRead(notification))
  }
}
