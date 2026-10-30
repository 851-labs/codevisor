export {
  AttachmentStoreError,
  makeAttachmentStore,
  migrateAttachmentBlobs,
  type AttachmentStore,
  type StoredAttachmentObject
} from "./attachment-store.js"
export { removeUnreferencedAttachments } from "./attachment-sweep.js"
export type { OpenAssistantText } from "./assistant-texts.js"

export * from "./errors.js"

export * from "./identity.js"
export * from "./ids.js"

export {
  FIRST_RUN_PROJECTS_PENDING,
  FIRST_RUN_PROJECTS_SETTING
} from "./machine-settings-service.js"

export {
  botPath,
  botsRoot,
  isBotFolder,
  isManagedFolder,
  isScratchFolder,
  legacyBotsRoot,
  legacyScratchWorkspacesRoot,
  legacyWorktreeTrashRoot,
  defaultCloneBaseFolder,
  scratchWorkspacePath,
  scratchWorkspacesRoot,
  worktreeNameAt,
  worktreePath,
  worktreePathBeside,
  worktreesRoot,
  worktreeTrashRoot
} from "./paths.js"

export * from "./rows.js"

export * from "./service.js"

export { isAgentQuestion, setupQuestionPresentation } from "./setup-questions.js"

export type { AutoResumeRecord, AutoResumeState } from "./auto-resume-service.js"
export type { FleetMessage, FleetPendingTurn, FleetPrompt } from "./fleet-outbox-service.js"
export type { FinishedTurn } from "./turn-finish.js"

export type {
  WorkspaceFileEdit,
  WorkspaceMediaCursor,
  WorkspaceMediaRow,
  WorkspaceMessageText
} from "./workspace-media.js"
export type {
  BotLink,
  CreateWorkspaceWithSessionRecord,
  RemoteBotLink,
  UpsertWorkspaceRecord,
  WorkspaceBotFields
} from "./workspace-service-types.js"
export type {
  DeliveredPluginAppContext,
  PluginAppContextRecord,
  PluginAppContextUpdate
} from "./plugin-app-contexts-service.js"
export type {
  NewPluginEventSubscription,
  PluginEventSubscriptionRecord
} from "./plugin-event-subscriptions-service.js"
export type {
  PendingPluginEventDelivery,
  PluginEventOccurrence,
  PluginEventStored,
  RecordedPluginEvent
} from "./plugin-events-service.js"
