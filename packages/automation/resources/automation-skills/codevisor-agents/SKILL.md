---
name: codevisor-agents
description: Create and coordinate other Codevisor coding agents as visible chats — beside you in the current workspace, or in new workspaces of their own. Covers starting sessions, sending prompts, waiting for them to finish or ask something, reading transcripts, answering questions, labeling, and archiving. Use when you want another harness or model working alongside you on the same change, separate pieces of work each with their own branch or PR, an agent per issue/PR/task, orchestrate or supervise agents, review another agent's work, or clean up agent workspaces.
---

# Codevisor agents

Every Codevisor chat is a **session**: a coding agent (Claude Code, Codex, …) running in a **workspace** of a **project**. You can create sessions, talk to them, and watch them. Each one is visible to the user in the sidebar.

Paths below are under `tools.codevisor.*`. Ids are passed by name: `sessionId`, `workspaceId`, `projectId` (never a bare `id`). Check exact inputs with `tools.describe.tool({ path: "codevisor.sessions.create" })`.

## Where am I

```js
;async () => tools.codevisor.context.current()
// { sessionId, projectId, workspaceId, worktreeName?, parentSessionId?, machine: { id, name }, clientId? }
```

## Beside you, in this workspace

A new chat in your own workspace shares your checkout, which suits another harness or model working on the same change (a second opinion, a piece to implement, a review of what you just wrote):

```js
;async () => {
  const me = await tools.codevisor.context.current()
  const helper = await tools.codevisor.sessions.create({
    projectId: me.projectId,
    workspaceId: me.workspaceId, // join this workspace
    ...(me.worktreeName ? { worktreeName: me.worktreeName } : {}), // and your checkout
    harnessId: "codex",
    title: "Second opinion on the retry logic"
  })
  await tools.codevisor.sessions.prompt({
    sessionId: helper.id,
    text: "Review the uncommitted changes in src/retry.ts and suggest fixes. Don't edit files."
  })
  return helper.id
}
```

Since the checkout is shared, a scoped task and not editing the same files at the same time keep the two of you from colliding.

## In a workspace of its own

A new workspace, optionally with its own git worktree, suits separate work that ends in its own branch or PR:

```js
;async () => {
  const me = await tools.codevisor.context.current()
  const harnesses = await tools.codevisor.harnesses.list()
  // Optional: an isolated git worktree, so parallel agents don't share a checkout.
  const worktree = await tools.codevisor.worktrees.create({
    projectId: me.projectId,
    name: "abc-123"
  })
  const session = await tools.codevisor.sessions.create({
    projectId: me.projectId, // or another project from projects.list()
    harnessId: "claude-code", // pick a ready harness id from harnesses.list()
    title: "Fix ABC-123: login redirect loop",
    worktreeName: worktree.name, // must name an existing worktree; omit to use the project folder
    labels: { linear: "ABC-123", role: "worker" }
  })
  await tools.codevisor.sessions.prompt({
    sessionId: session.id,
    text: "Fix ABC-123 … then open a PR."
  })
  return session.id
}
```

- Without `workspaceId`, each session gets its own new workspace.
- Sessions you create record you as `parentSessionId`.
- `labels` are free-form key/value pairs. Use them to find your agents again later.

## Wait instead of polling

```js
;async () =>
  tools.codevisor.sessions.wait({
    ids: [a, b, c],
    until: ["idle", "waitingForUser", "errored"],
    timeoutMs: 240000
  })
// → { sessions: [{ id, sidebarState, actionRequiredKind?, pendingQuestion? }], timedOut }
```

- It returns as soon as any listed session reaches one of the `until` states.
- Call it again with the remaining ids to keep waiting.
- `timedOut: true` is normal; check state and wait again.

## Check progress and answer questions

- `sessions.get({ sessionId })`: status, current conversation, queue.
- `sessions.transcript({ sessionId, limit })`: recent items, newest page first. Use `before` for older pages.
- `sessions.list({ parentSessionId: me.sessionId })` or `sessions.list({ label: "linear=ABC-123" })`: rediscover your agents.
- When `sidebarState` is `waitingForUser`:
  - Read `pendingQuestion`.
  - Answer with `sessions.question_answer({ sessionId, questionId, outcome: "answered", answers })`, or send guidance with `sessions.prompt`.
- `sessions.cancel({ sessionId })` stops the active turn.

## If you are the child

If `context.current()` has a `parentSessionId` and you are blocked, ask your parent directly:

```js
;async () => {
  const me = await tools.codevisor.context.current()
  await tools.codevisor.sessions.prompt({
    sessionId: me.parentSessionId,
    text: `Question from ${me.sessionId}: …`
  })
}
```

## Review and clean up

- To review work, start another session on the same project with `labels: { role: "reviewer", for: workerId }` and prompt it with the PR or branch.
- `sessions.branch_diff({ sessionId })` gives a quick size of an agent's changes.
- To archive a workspace, use `workspaces.update({ workspaceId, isArchived: true })` (the session's `workspaceId` is on its summary). `workspaces.list({ label })` finds workspaces by label.
- Archive only workspaces you created, once their work is merged or no longer needed. Archiving keeps a restorable snapshot but releases the branch name, so push or open the PR first if the branch should stay around.

## Agents on other machines

The same tools exist on every machine. `(await machines.get("macbook")).tools.codevisor.sessions.create(…)` starts an agent there. See `codevisor-machines`.
