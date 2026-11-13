import { startArchiveRetention } from "./archive-retention.js"
import { removeBot } from "./routes/bot-remove.js"
import { deleteServerSession } from "./routes/sessions.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "./server-context-types.js"
import { forgetUnrestorableSnapshots } from "./unrestorable-snapshots.js"

export const startServerArchiveRetention = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState
): (() => void) =>
  startArchiveRetention({
    db: services.db,
    attachments: services.attachments,
    deleteChat: (chat) => deleteServerSession(services, fanout, chat.id),
    removeBot: (bot) => removeBot(services, config, fanout, routeState, bot),
    forgetUnrestorableSnapshots: () => forgetUnrestorableSnapshots(services, config.id)
  })
