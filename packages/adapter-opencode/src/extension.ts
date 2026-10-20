import type { AcpStdioExtensionFactory } from "@codevisor/adapter-acp"

import { skillReadUpdate, withSkillRead } from "./skill-tool.js"
import {
  CHILD_SESSION_UPDATES_CAPABILITY,
  CHILD_UPDATE_METHOD,
  OpenCodeSubagents
} from "./subagents.js"
import { isOpenCodeUsageLimit } from "./usage-limits.js"

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
    mapSessionNotification: (notification) =>
      subagents.mapNotification({ ...notification, update: skillReadUpdate(notification.update) }),
    sdkConnectionCustomization: { isUsageLimitFailure: isOpenCodeUsageLimit }
  }
}
