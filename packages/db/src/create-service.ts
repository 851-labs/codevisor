import type Database from "better-sqlite3"
import { Effect } from "effect"

import { makeAuthService } from "./auth-service.js"
import { makeAutoResumeService } from "./auto-resume-service.js"
import { makeBotMessagesService } from "./bot-messages-service.js"
import { makeBotsService } from "./bots-service.js"
import { makeBrowserStateService } from "./browser-state-service.js"
import { runDatabaseMigrations } from "./database-migrations.js"
import { attempt } from "./errors.js"
import { makeEventsService } from "./events-service.js"
import { makeFilesService } from "./files-service.js"
import { makeHarnessService } from "./harness-service.js"
import { makeMachineSettingsService } from "./machine-settings-service.js"
import { makeMcpService } from "./mcp-service.js"
import { makeNavigationService } from "./navigation-service.js"
import { makeProjectsService } from "./projects-service.js"
import { makePromptQueueService } from "./prompt-queue-service.js"
import { createServiceContext } from "./service-context.js"
import type { CodevisorDatabaseConfig, CodevisorDatabaseService } from "./service.js"
import { makeSessionSubscriptionsService } from "./session-subscriptions-service.js"
import { makeSessionsService } from "./sessions-service.js"
import { makeStreamingReconciliationService } from "./streaming-reconciliation-service.js"
import { makeSyncService } from "./sync-service.js"
import { makeTerminalPaneTitlesService } from "./terminal-pane-titles.js"
import { makeTranscriptService } from "./transcript-service.js"
import { makeUpdatesService } from "./updates-service.js"
import { makeWorkspaceCreationService } from "./workspace-creation-service.js"
import { makeWorkspaceGitService } from "./workspace-git.js"
import { makeWorkspaceMediaService } from "./workspace-media.js"
import { makeWorkspacesService } from "./workspaces-service.js"
import { makeWorktreesService } from "./worktrees-service.js"

export const createService = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): CodevisorDatabaseService => {
  const migrate = attempt("migrate", () => runDatabaseMigrations(sqlite, config))

  const context = createServiceContext(sqlite, config)

  return {
    migrate,
    close: Effect.sync(() => sqlite.close()),
    ...makeNavigationService(context),
    ...makeProjectsService(context),
    ...makeWorktreesService(context),
    ...makeBotsService(context),
    ...makeBotMessagesService(context),
    ...makeWorkspacesService(context),
    ...makeTerminalPaneTitlesService(context),
    ...makeWorkspaceGitService(context),
    ...makeWorkspaceCreationService(context),
    ...makeSessionsService(context),
    ...makeTranscriptService(context),
    ...makeStreamingReconciliationService(context),
    ...makeEventsService(context),
    ...makePromptQueueService(context),
    ...makeSessionSubscriptionsService(context),
    ...makeAutoResumeService(context),
    ...makeFilesService(context),
    ...makeWorkspaceMediaService(context),
    ...makeHarnessService(context),
    ...makeMcpService(context),
    ...makeAuthService(context),
    ...makeBrowserStateService(context),
    ...makeMachineSettingsService(context),
    ...makeUpdatesService(context),
    ...makeSyncService(context)
  }
}
