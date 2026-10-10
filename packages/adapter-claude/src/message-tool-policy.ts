/// Snapshot-style tools rendered as plans instead of tool calls: TodoWrite
/// carries the step checklist (`input.todos`), ExitPlanMode the plan-mode plan
/// document (`input.plan`).
export const PLAN_TOOLS = new Set(["TodoWrite", "ExitPlanMode"])

/// Newer headless Claude sessions use an incremental task API in every
/// permission mode instead of TodoWrite's full snapshots. Codevisor accumulates
/// these mutations into the same plan wire shape clients use for checklists.
export const TASK_TOOLS = new Set(["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"])

/// Tools whose generic tool-call lifecycle never reaches the wire: plan tools
/// and task tools surface as plan updates, AskUserQuestion as a blocking
/// `question` event handled through canUseTool.
export const HIDDEN_TOOLS = new Set([...PLAN_TOOLS, ...TASK_TOOLS, "AskUserQuestion"])
