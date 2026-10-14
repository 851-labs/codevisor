export const PLAN_TOOLS = new Set(["TodoWrite", "ExitPlanMode"])

export const TASK_TOOLS = new Set(["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"])

export const HIDDEN_TOOLS = new Set([...PLAN_TOOLS, ...TASK_TOOLS, "AskUserQuestion"])
