/// Codevisor dogfood plugin: a git diff viewer pane.
///
/// This file doubles as the reference implementation of the plugin contract:
/// - serve HTTP on $PORT (loopback)
/// - all URLs in served HTML are RELATIVE (they resolve under the proxy prefix)
/// - read pane context from the X-Codevisor-Context header (base64 JSON)
/// - style with the --codevisor-* CSS variables the client injects
///
/// Zero dependencies on purpose — the documented golden path for plugins.

interface PaneContext {
  readonly cwd?: string
  readonly paneId?: string
  readonly themeMode?: string
}

const decodeContext = (header: string | null): PaneContext => {
  if (header === null) return {}
  try {
    return JSON.parse(Buffer.from(header, "base64").toString("utf8")) as PaneContext
  } catch {
    return {}
  }
}

const git = async (cwd: string, args: ReadonlyArray<string>): Promise<string | undefined> => {
  const child = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" })
  const output = await new Response(child.stdout).text()
  return (await child.exited) === 0 ? output : undefined
}

interface DiffResult {
  readonly ok: boolean
  readonly clean: boolean
  /// `git diff --stat` — one line per changed file plus a summary line.
  readonly stat: string
  readonly output: string
}

const gitDiff = async (cwd: string): Promise<DiffResult> => {
  try {
    const [status, stat, diff] = await Promise.all([
      git(cwd, ["status", "--short"]),
      git(cwd, ["diff", "--stat"]),
      git(cwd, ["diff"])
    ])
    if (status === undefined || stat === undefined || diff === undefined) {
      return { ok: false, clean: false, stat: "", output: "Not a git repository (or git failed)." }
    }
    return {
      ok: true,
      clean: status.trim().length === 0 && diff.trim().length === 0,
      stat: stat.trimEnd(),
      output: `# git status --short\n${status}\n# git diff\n${diff}`
    }
  } catch (cause) {
    return { ok: false, clean: false, stat: "", output: `git unavailable: ${String(cause)}` }
  }
}

const page = (): string => `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Git Diff</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0;
    font-family: var(--codevisor-font-family, ui-monospace, monospace);
    background: var(--codevisor-bg, Canvas);
    color: var(--codevisor-fg, CanvasText);
  }
  header {
    display: flex; align-items: center; gap: 8px;
    padding: 8px 12px;
    border-bottom: 1px solid var(--codevisor-border, color-mix(in srgb, CanvasText 15%, transparent));
    font-size: 12px;
  }
  header .cwd { opacity: 0.7; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  header button {
    margin-left: auto;
    background: transparent; color: inherit;
    border: 1px solid var(--codevisor-border, color-mix(in srgb, CanvasText 25%, transparent));
    border-radius: 6px; padding: 3px 10px; font: inherit; cursor: pointer;
  }
  #stat {
    padding: 8px 12px; font-size: 12px; line-height: 1.5;
    background: var(--codevisor-bg-elevated, color-mix(in srgb, CanvasText 4%, Canvas));
    border-bottom: 1px solid var(--codevisor-border, color-mix(in srgb, CanvasText 15%, transparent));
    white-space: pre; overflow-x: auto;
  }
  #stat:empty { display: none; }
  pre { margin: 0; padding: 12px; font-size: 12px; line-height: 1.5; overflow: auto; }
  .add { color: var(--codevisor-diff-added, #2da44e); }
  .del { color: var(--codevisor-diff-removed, #cf222e); }
  .hunk { color: var(--codevisor-accent, #0969da); }
  .meta { opacity: 0.6; }
  .empty {
    padding: 48px 12px; text-align: center;
    color: var(--codevisor-fg-secondary, color-mix(in srgb, CanvasText 60%, transparent));
  }
</style>
</head>
<body>
<header><strong>Git Diff</strong><span class="cwd" id="cwd"></span><button id="refresh">Refresh</button></header>
<div id="stat"></div>
<pre id="diff">Loading…</pre>
<script>
  const escape = (line) =>
    line.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  const render = (text) => {
    document.getElementById("diff").innerHTML = text
      .split("\\n")
      .map((line) => {
        const safe = escape(line)
        if (line.startsWith("+") && !line.startsWith("+++")) return '<span class="add">' + safe + "</span>"
        if (line.startsWith("-") && !line.startsWith("---")) return '<span class="del">' + safe + "</span>"
        if (line.startsWith("@@")) return '<span class="hunk">' + safe + "</span>"
        if (line.startsWith("#") || line.startsWith("diff ")) return '<span class="meta">' + safe + "</span>"
        return safe
      })
      .join("\\n")
  }
  const renderStat = (stat) => {
    document.getElementById("stat").innerHTML = stat
      .split("\\n")
      .map((line) =>
        escape(line)
          .replace(/(\\+)+$/, '<span class="add">$&</span>')
          .replace(/(-)+$/, '<span class="del">$&</span>')
      )
      .join("\\n")
  }
  const refresh = async () => {
    // Relative URL: resolves under the codevisor proxy prefix.
    const response = await fetch("api/diff")
    const body = await response.json()
    document.getElementById("cwd").textContent = body.cwd ?? ""
    if (body.clean) {
      renderStat("")
      document.getElementById("diff").innerHTML = '<div class="empty">Working tree clean — nothing to diff.</div>'
      return
    }
    renderStat(body.stat ?? "")
    render(body.output)
  }
  document.getElementById("refresh").addEventListener("click", refresh)
  refresh()
  setInterval(refresh, 5000)
</script>
</body>
</html>
`

const port = Number(process.env["PORT"] ?? 0)

Bun.serve({
  hostname: "127.0.0.1",
  port,
  fetch: async (request) => {
    const url = new URL(request.url)
    if (url.pathname === "/health") {
      return new Response("ok")
    }
    if (url.pathname === "/panes/diff/") {
      return new Response(page(), { headers: { "Content-Type": "text/html; charset=utf-8" } })
    }
    if (url.pathname === "/panes/diff/api/diff") {
      const context = decodeContext(request.headers.get("x-codevisor-context"))
      const cwd = context.cwd ?? process.cwd()
      const result = await gitDiff(cwd)
      return Response.json({ cwd, ...result })
    }
    return new Response("Not found", { status: 404 })
  }
})

console.log(`git-diff plugin listening on 127.0.0.1:${port}`)
