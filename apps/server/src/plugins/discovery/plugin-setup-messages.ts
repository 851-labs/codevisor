import { attribute, fromMachine } from "../../routes/session-event-messages.js"
import type { PendingSessionEvent } from "../../routes/session-event-outbox.js"
import { sourceSessionIdFor } from "../events/plugin-event-messages.js"
import type { PluginDirectoryItem } from "./plugin-directory.js"

export const pluginSetupFinishedEvent = (
  item: PluginDirectoryItem,
  machine: { readonly id: string; readonly name: string }
): PendingSessionEvent => ({
  message: fromMachine(
    {
      text: [
        `<codevisor-event type="plugin.setup_finished" plugin="${attribute(item.name)}" pluginId="${attribute(item.plugin)}">`,
        `The user finished setting up ${item.name} from the card you showed. It's installed and ready to use.`,
        ...accountLines(item),
        `Carry on with what you needed it for. plugins.describe({ plugin: ${JSON.stringify(item.plugin)} }) lists its tools.`,
        "</codevisor-event>"
      ].join("\n")
    },
    machine
  ),
  sourceSessionId: sourceSessionIdFor(item.plugin)
})

const accountLines = (item: PluginDirectoryItem): ReadonlyArray<string> =>
  item.accounts.length === 0 ? [] : [`Signed-in accounts: ${item.accounts.join(", ")}.`]
