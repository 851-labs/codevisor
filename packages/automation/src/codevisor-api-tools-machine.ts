import { WorkspaceMirrorStartRequest, WorkspaceMirrorWaitRequest } from "@codevisor/api"
import { Schema } from "effect"

import {
  apiTool,
  integerQuery,
  stringQuery,
  type CodevisorApiToolSpec
} from "./codevisor-api-tool-spec.js"

export const MIRROR_WAIT_DEFAULT_MS = 60_000

export const ExecToolRequest = Schema.Struct({
  command: Schema.String,
  description: Schema.optional(Schema.String),
  timeout: Schema.optional(Schema.Number),
  run_in_background: Schema.optional(Schema.Boolean),
  cwd: Schema.optional(Schema.String)
})

export const codevisorMachineApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "shell.exec",
    "Run a shell command on this machine, like a terminal: `command`, a short `description`, `timeout` in ms (default 120000, max 600000), `run_in_background`, and `cwd` (default the home folder; pass a workspace mirror's path to run against your workspace). Foreground returns { exitCode, output, timedOut, durationMs, outputPath }, with stdout and stderr combined and only the last 30000 characters kept. run_in_background returns { taskId, outputPath } at once; when it exits you get an exec.task_finished event. Read outputPath with files.read, and stop it with shell.task_stop.",
    "POST",
    "/v1/exec",
    { body: ExecToolRequest }
  ),
  apiTool(
    "shell.task_get",
    "Get a background shell task started with shell.exec: state (running, exited, stopped), exitCode, outputPath.",
    "GET",
    "/v1/exec/tasks/:taskId"
  ),
  apiTool(
    "shell.task_stop",
    "Stop a background shell task started with shell.exec, and everything it started. Returns the task's final state.",
    "POST",
    "/v1/exec/tasks/:taskId/stop"
  ),
  apiTool(
    "shell.activity",
    "How busy this machine's shell commands are: { running, lastActiveAt? }, where running counts background commands still going and lastActiveAt is when one last finished.",
    "GET",
    "/v1/exec/activity"
  ),
  apiTool(
    "files.read",
    "Read a text file on this machine. Returns { content, startLine, endLine, totalLines } with each line prefixed by its number. `offset` is the first line (1-based) and `limit` the line count (default 2000).",
    "GET",
    "/v1/fs/read",
    {
      query: [
        stringQuery("path", "Absolute path, or ~/ for the home folder"),
        integerQuery("offset", "First line to read, 1-based"),
        integerQuery("limit", "How many lines to read (default 2000)")
      ]
    }
  ),
  apiTool(
    "workspaces.mirrors",
    "List your workspace's mirrors: the machines it is mirrored to, with each mirror's path and state.",
    "GET",
    "/v1/sessions/:id/mirrors"
  ),
  apiTool(
    "workspaces.mirror_start",
    "Mirror your workspace to another machine (machineId or name): a one-way copy kept current in the background. It keeps running in the background until stopped or the workspace is archived, pushing your edits within about a second. One-way: files the other machine creates stay there. Returns { path, state }: run commands in path with that machine's shell.exec.",
    "POST",
    "/v1/sessions/:id/mirrors",
    { body: WorkspaceMirrorStartRequest }
  ),
  apiTool(
    "workspaces.mirror_status",
    "Check a workspace mirror: state (syncing, synced, failed), pendingChanges (edits that haven't reached that machine yet), lastSyncedAt, lastSync stats, skipped files over 50 MB, and error.",
    "GET",
    "/v1/sessions/:id/mirrors/:machine"
  ),
  apiTool(
    "workspaces.mirror_wait",
    "Wait until your latest edits have reached the other machine. Returns the mirror's status, with timedOut when it is still syncing. Cheap when already up to date.",
    "POST",
    "/v1/sessions/:id/mirrors/:machine/wait",
    {
      body: WorkspaceMirrorWaitRequest,
      budgetedWait: { field: "timeoutMs", defaultMs: MIRROR_WAIT_DEFAULT_MS }
    }
  ),
  apiTool(
    "workspaces.mirror_stop",
    "Stop a workspace mirror and delete it from that machine. If that machine is offline, it is deleted when the machine comes back.",
    "DELETE",
    "/v1/sessions/:id/mirrors/:machine"
  )
]
