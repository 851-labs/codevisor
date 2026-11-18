import type { PluginAppContextsService } from "./plugin-app-contexts-service.js"
import type { PluginEventSubscriptionsService } from "./plugin-event-subscriptions-service.js"
import type { PluginEventsService } from "./plugin-events-service.js"
import type { PluginSetupsService } from "./plugin-setups-service.js"

export interface PluginDatabaseService
  extends
    PluginEventSubscriptionsService,
    PluginAppContextsService,
    PluginEventsService,
    PluginSetupsService {}
