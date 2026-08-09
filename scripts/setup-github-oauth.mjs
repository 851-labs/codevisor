// One-command GitHub sign-in setup for the Codevisor cloud.
//
//   bun run setup:github-oauth                 # dev app → main clone .dev.vars
//   bun run setup:github-oauth -- --org NAME   # create under an organization
//   bun run setup:github-oauth -- --prod --org NAME --out FILE
//                                              # production app → credentials file
//
// Uses GitHub's app-manifest flow: the script serves a pre-filled manifest,
// the browser shows a single "Create GitHub App" button, GitHub redirects
// back with a one-time code, and the script exchanges it for the client
// id/secret (POST /app-manifests/{code}/conversions). Dev mode writes
// apps/cloud/.dev.vars in the MAIN clone — where every worktree's
// `bun run dev` picks it up automatically. Prod mode writes a credentials
// JSON (default tmp/github-app.json, gitignored) for `wrangler secret put`.
//
// Docs: https://docs.github.com/apps/sharing-github-apps/registering-a-github-app-from-a-manifest
import { execFileSync, spawn } from "node:child_process"
import { randomBytes } from "node:crypto"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { userInfo } from "node:os"
import { dirname, join, resolve } from "node:path"
import process from "node:process"
import { parseArgs } from "node:util"
import { fileURLToPath } from "node:url"

const repoRoot = resolve(fileURLToPath(new URL("..", import.meta.url)))

const { values: options } = parseArgs({
  options: {
    org: { type: "string" },
    prod: { type: "boolean", default: false },
    name: { type: "string" },
    out: { type: "string" },
    "no-open": { type: "boolean", default: false }
  }
})

const mainRoot = (() => {
  try {
    const commonDir = execFileSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot,
      encoding: "utf8"
    }).trim()
    return resolve(repoRoot, commonDir, "..")
  } catch {
    return repoRoot
  }
})()

const devVarsPath = join(mainRoot, "apps/cloud/.dev.vars")
const outPath = options.prod ? resolve(repoRoot, options.out ?? "tmp/github-app.json") : devVarsPath

const existing = options.prod
  ? undefined
  : await readFile(devVarsPath, "utf8").catch(() => undefined)
if (existing !== undefined && /^\s*GITHUB_CLIENT_ID\s*=/m.test(existing)) {
  console.log(`GitHub credentials already configured in ${devVarsPath}`)
  console.log("Delete the GITHUB_CLIENT_ID/GITHUB_CLIENT_SECRET lines first to re-run setup.")
  process.exit(0)
}

// GitHub App names are globally unique and ≤34 chars; dev apps get a random
// suffix so every developer's app can coexist.
const username = userInfo()
  .username.toLowerCase()
  .replaceAll(/[^a-z0-9-]/g, "")
  .slice(0, 16)
const appName =
  options.name ??
  (options.prod ? "Codevisor Cloud" : `codevisor-dev-${username}-${randomBytes(2).toString("hex")}`)
const state = randomBytes(16).toString("hex")

const homepage = options.prod ? "https://codevisor.dev" : "http://localhost:8787"
const callback = options.prod
  ? "https://cloud.codevisor.dev/api/auth/callback/github"
  : "http://localhost:8787/api/auth/callback/github"

const manifest = (redirectUrl) => ({
  name: appName,
  url: homepage,
  // Sign-in callback used by Better Auth's GitHub provider.
  callback_urls: [callback],
  // Where GitHub sends the one-time conversion code after "Create".
  redirect_url: redirectUrl,
  public: options.prod,
  // Read email addresses so sign-in works for private-email accounts.
  default_permissions: { emails: "read" },
  hook_attributes: { url: "https://example.com/unused", active: false }
})

// Org-owned apps are created from the organization's settings URL.
const creationUrl =
  options.org !== undefined
    ? `https://github.com/organizations/${options.org}/settings/apps/new?state=${state}`
    : `https://github.com/settings/apps/new?state=${state}`

const server = createServer()
await new Promise((ready) => server.listen(0, "127.0.0.1", ready))
const port = server.address().port
const redirectUrl = `http://127.0.0.1:${port}/callback`

const done = new Promise((resolveDone, rejectDone) => {
  server.on("request", async (request, response) => {
    const url = new URL(request.url, redirectUrl)
    if (url.pathname === "/") {
      // Auto-submitting form: the manifest must arrive as a POSTed form field.
      const payload = JSON.stringify(manifest(redirectUrl)).replaceAll("'", "&#39;")
      response.writeHead(200, { "content-type": "text/html" })
      response.end(
        `<!doctype html><meta charset="utf-8"><title>Codevisor GitHub setup</title>
         <body style="font-family:system-ui;padding:2rem">
         <p>Redirecting to GitHub — click <b>Create GitHub App</b> on the next page…</p>
         <form id="f" action="${creationUrl}" method="post">
           <input type="hidden" name="manifest" value='${payload}'>
         </form><script>document.getElementById("f").submit()</script>`
      )
      return
    }
    if (url.pathname === "/callback") {
      try {
        if (url.searchParams.get("state") !== state) throw new Error("state mismatch")
        const code = url.searchParams.get("code")
        if (code === null) throw new Error("missing conversion code")
        const converted = await fetch(`https://api.github.com/app-manifests/${code}/conversions`, {
          method: "POST",
          headers: { accept: "application/vnd.github+json" }
        })
        if (!converted.ok) throw new Error(`conversion failed (${converted.status})`)
        const app = await converted.json()
        await mkdir(dirname(outPath), { recursive: true })
        if (options.prod) {
          await writeFile(
            outPath,
            JSON.stringify(
              {
                name: app.name,
                html_url: app.html_url,
                client_id: app.client_id,
                client_secret: app.client_secret
              },
              null,
              2
            ),
            { mode: 0o600 }
          )
        } else {
          const block = `GITHUB_CLIENT_ID=${app.client_id}\nGITHUB_CLIENT_SECRET=${app.client_secret}\n`
          const content =
            existing !== undefined
              ? `${existing.trimEnd()}\n${block}`
              : `# Created by scripts/setup-github-oauth.mjs (${app.html_url})\n${block}`
          await writeFile(outPath, content, { mode: 0o600 })
        }
        response.writeHead(200, { "content-type": "text/html" })
        response.end(
          `<body style="font-family:system-ui;padding:2rem">
           <p>✅ <b>${app.name}</b> created and configured. You can close this tab.</p>`
        )
        resolveDone(app)
      } catch (error) {
        response.writeHead(500, { "content-type": "text/plain" })
        response.end(`Setup failed: ${error.message}`)
        rejectDone(error)
      }
      return
    }
    response.writeHead(404).end()
  })
})

console.log(`Creating GitHub App "${appName}"${options.org ? ` under ${options.org}` : ""}…`)
const startUrl = `http://127.0.0.1:${port}/`
console.log(`Start URL: ${startUrl}`)
console.log("Click [1mCreate GitHub App[0m when the browser prompts.")
if (!options["no-open"]) {
  const opener = process.platform === "darwin" ? "open" : "xdg-open"
  spawn(opener, [startUrl], { stdio: "ignore" }).on("error", () => {
    console.log(`Could not open a browser automatically. Visit: ${startUrl}`)
  })
}

try {
  const app = await done
  console.log("")
  console.log(`✅ Created ${app.html_url}`)
  console.log(`✅ Wrote credentials to ${outPath}`)
  if (!options.prod) {
    console.log("")
    console.log("GitHub sign-in is configured for a cloud launched with:")
    console.log("  CODEVISOR_DEV_CLOUD_PORT=8787 bun run dev")
    console.log("Ordinary `bun run dev` instances keep their isolated worktree cloud ports.")
  }
} catch (error) {
  console.error(`Setup failed: ${error.message}`)
  process.exitCode = 1
} finally {
  server.close()
}
