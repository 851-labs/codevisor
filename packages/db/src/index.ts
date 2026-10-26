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

export type { AutoResumeRecord, AutoResumeState } from "./auto-resume-service.js"
export type { FleetMessage, FleetPendingTurn, FleetPrompt } from "./fleet-outbox-service.js"

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
