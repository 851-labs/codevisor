import { execFileSync } from "node:child_process"

export function terminateExactDevelopmentApp(executable: string): void {
  for (const processID of processesMatching(executable)) {
    if (commandOf(processID) === executable) signalQuietly(processID)
  }
}

function processesMatching(executable: string): Array<number> {
  try {
    return execFileSync("/usr/bin/pgrep", ["-f", `^${escapeRegularExpression(executable)}$`], {
      encoding: "utf8"
    })
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map(Number)
  } catch (error) {
    if (exitStatusOf(error) === 1) return []
    throw error
  }
}

function commandOf(processID: number): string | undefined {
  try {
    return execFileSync("/bin/ps", ["-p", String(processID), "-o", "command="], {
      encoding: "utf8"
    }).trim()
  } catch (error) {
    if (exitStatusOf(error) === 1) return undefined
    throw error
  }
}

function signalQuietly(processID: number): void {
  try {
    process.kill(processID, "SIGTERM")
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error
  }
}

function exitStatusOf(error: unknown): unknown {
  return error instanceof Error && "status" in error ? error.status : undefined
}

function escapeRegularExpression(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}
