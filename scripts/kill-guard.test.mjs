import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, rmSync, symlinkSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { broadKillReason } from "./agent-hooks/kill-guard.mjs"

const guard = fileURLToPath(new URL("./agent-hooks/kill-guard.mjs", import.meta.url))

const blocked = (command) => broadKillReason(command) !== undefined

const runGuard = (payload, script = guard) =>
  spawnSync(process.execPath, [script], { input: JSON.stringify(payload), encoding: "utf8" })

test("pattern kills are blocked wherever the shell would run them", () => {
  for (const command of [
    'pkill -f "opencode serve --stdio --port 0" -U $(id -u) -n',
    "killall node",
    "/usr/bin/pkill -x claude",
    "cd tmp && pkill -f vite || true",
    "sudo -u dylan pkill -f server",
    "env FOO=1 timeout 5 pkill -9 -f dist/main.js",
    "pgrep -f vite | xargs kill -9",
    "ps aux | grep '[v]ite' | awk '{print $2}' | xargs -r kill",
    "kill -9 $(pgrep -f codevisor-server)",
    "kill `lsof -ti :3000`",
    'kill -TERM "$(pidof node)"',
    "pids=$(pgrep -f vite); kill $pids",
    "for pid in $(pgrep -f vite); do kill -9 $pid; done",
    "kill -9 -1",
    "kill -- -1",
    "bash -lc 'pkill -f vite'",
    "bash --norc -c 'pkill -f vite'",
    'eval "killall Dock"',
    "ssh -p 22 studio 'pkill -f claude'",
    'echo "$(pkill -f vite)"',
    "(cd apps/server; killall -9 node)"
  ]) {
    assert.ok(blocked(command), command)
  }
})

test("looking up processes, killing known PIDs, and mentioning pkill are allowed", () => {
  for (const command of [
    "pgrep -fl 'opencode serve'",
    "ps -o pid,ppid,command -p 4242",
    "lsof -ti :3000",
    "kill 4242 4243",
    "kill -TERM -- -4242",
    'kill "$!"',
    "kill $(cat tmp/dev.pid)",
    "kill -l",
    "kill -1 4242",
    "grep -rn pkill scripts",
    'git commit -m "Stop agents from running pkill -f"',
    "echo killall # pkill -f vite",
    "command -v pkill",
    "cat > stop.sh <<'EOF'\npkill -f vite\nEOF\nchmod +x stop.sh",
    "docker exec dev pgrep -fl node"
  ]) {
    assert.ok(!blocked(command), command)
  }
})

test("the hook blocks with exit code 2 and the reason on stderr", () => {
  const claude = runGuard({
    hook_event_name: "PreToolUse",
    tool_input: { command: "killall node" }
  })
  assert.equal(claude.status, 2)
  assert.match(claude.stderr, /^Blocked `killall`: .*AGENTS\.md\n$/)

  const grok = runGuard({ hookEventName: "pre_tool_use", toolInput: { command: "pkill -f vite" } })
  assert.equal(grok.status, 2)

  const allowed = runGuard({ tool_input: { command: "pgrep -fl vite" } })
  assert.deepEqual([allowed.status, allowed.stdout, allowed.stderr], [0, "", ""])
})

test("the hook still runs when the repo reaches it through a symlink", () => {
  const directory = mkdtempSync(join(tmpdir(), "kill-guard-"))
  try {
    const linked = join(directory, "kill-guard.mjs")
    symlinkSync(guard, linked)
    assert.equal(runGuard({ tool_input: { command: "killall node" } }, linked).status, 2)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test("Antigravity gets a deny decision on stdout", () => {
  const result = runGuard({
    toolCall: { name: "run_command", args: { CommandLine: "pkill -f x" } }
  })
  assert.equal(result.status, 0)
  assert.equal(JSON.parse(result.stdout).decision, "deny")
})

test("a payload the hook can't read lets the command run", () => {
  const result = spawnSync(process.execPath, [guard], { input: "not json", encoding: "utf8" })
  assert.deepEqual([result.status, result.stderr], [0, ""])
})
