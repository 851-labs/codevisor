import { spawn } from "node:child_process"
import { PluginsError } from "./plugins-error.js"

/// A plugin source resolved to something `git clone` understands, forked from
/// packages/skills' skills-remote-source.ts. v1 contract: GitHub `owner/repo`
/// shorthand (with optional `#ref` and `/subpath`), git URLs, and local
/// filesystem paths. No GitLab shorthand and no well-known endpoints —
/// plugins install from repositories only.
export interface ParsedPluginSource {
  /// Clone target: an https/ssh git URL or a local repository path.
  readonly url: string
  readonly ref?: string | undefined
  /// Plugin directory inside the repository, when the source names one.
  readonly subpath?: string | undefined
  /// GitHub owner when the source names one (`owner/repo` shorthand or a
  /// github.com URL). Drives anti-impersonation: a managed install's
  /// manifest id must be namespaced under this owner.
  readonly owner?: string | undefined
  /// Local filesystem sources (dev installs) are exempt from the owner
  /// namespace check — there is no owner to validate against.
  readonly local?: boolean | undefined
}

/// Parse the plugin source formats: GitHub `owner/repo` shorthand (with
/// optional `#ref` and `/subpath`), a `github:` prefix, github.com URLs
/// (including `/tree/<ref>/<subpath>`), raw git/ssh/https remotes, and local
/// filesystem paths (cloned via git, so tests never hit the network).
export const parsePluginSource = (input: string): ParsedPluginSource => {
  let source = input.trim()
  if (source === "") {
    throw new PluginsError("invalid", "A plugin source is required")
  }
  if (source.startsWith("github:")) {
    source = source.slice("github:".length)
  }

  // Raw git/ssh remotes pass straight through (with optional #ref).
  if (source.startsWith("git@") || source.startsWith("ssh://")) {
    const [url, ref] = splitRef(source)
    return { ref, url }
  }

  // Local filesystem paths clone directly — useful for tests and local
  // plugin repositories. file:// is git's explicit local-remote syntax.
  if (
    source.startsWith("/") ||
    source.startsWith("./") ||
    source.startsWith("../") ||
    source.startsWith("file://")
  ) {
    const [url, ref] = splitRef(source)
    return { local: true, ref, url }
  }

  if (source.startsWith("http://") || source.startsWith("https://")) {
    const [withoutRef, ref] = splitRef(source)
    const url = new URL(withoutRef)
    if (url.hostname === "github.com" || url.hostname === "www.github.com") {
      const segments = url.pathname.split("/").filter((part) => part !== "")
      const [owner, repoRaw, marker, treeRef, ...rest] = segments
      if (owner === undefined || repoRaw === undefined) {
        throw new PluginsError("invalid", `Not a repository URL: ${input}`)
      }
      const repo = repoRaw.endsWith(".git") ? repoRaw.slice(0, -4) : repoRaw
      // github.com/o/r/tree/<ref>/<subpath...>
      if (marker === "tree" && treeRef !== undefined) {
        return {
          owner,
          ref: ref ?? treeRef,
          ...(rest.length === 0 ? {} : { subpath: rest.join("/") }),
          url: `https://github.com/${owner}/${repo}.git`
        }
      }
      const subpath = [marker, treeRef, ...rest].filter(
        (part): part is string => part !== undefined
      )
      return {
        owner,
        ref,
        ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
        url: `https://github.com/${owner}/${repo}.git`
      }
    }
    // Any other http(s) URL is handed to git verbatim — self-hosted remotes
    // work, and a non-repository URL fails fast at clone time.
    return { ref, url: withoutRef }
  }

  // owner/repo[#ref][/subpath] shorthand.
  const [withoutRef, ref] = splitRef(source)
  const segments = withoutRef.split("/").filter((part) => part !== "")
  const [owner, repo, ...subpath] = segments
  if (owner === undefined || repo === undefined) {
    throw new PluginsError(
      "invalid",
      `Unrecognized plugin source: ${input} — use owner/repo, owner/repo/path, a git URL, or a local path`
    )
  }
  return {
    owner,
    ref,
    ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
    url: `https://github.com/${owner}/${repo}.git`
  }
}

const splitRef = (source: string): readonly [string, string | undefined] => {
  const index = source.indexOf("#")
  if (index === -1) {
    return [source, undefined]
  }
  const ref = source.slice(index + 1)
  return [source.slice(0, index), ref === "" ? undefined : ref]
}

/// Default clone: shallow, optionally pinned to a branch or tag, with
/// interactive prompts disabled so a bad URL fails fast instead of hanging.
/// Same discipline as skills' cloneSkillSource.
export const clonePluginSource = (
  url: string,
  ref: string | undefined,
  destination: string
): Promise<void> =>
  new Promise((resolvePromise, rejectPromise) => {
    const args = [
      "clone",
      "--depth",
      "1",
      ...(ref === undefined ? [] : ["--branch", ref]),
      url,
      destination
    ]
    const child = spawn("git", args, {
      env: {
        ...process.env,
        GIT_ASKPASS: "true",
        GIT_SSH_COMMAND: process.env["GIT_SSH_COMMAND"] ?? "ssh -oBatchMode=yes",
        GIT_TERMINAL_PROMPT: "0"
      }
    })
    const stderr: Array<string> = []
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => stderr.push(chunk))
    /* v8 ignore next -- spawn-level failures (git missing) need an environment tests can't fake. */
    child.on("error", (cause) => rejectPromise(cause))
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise()
        return
      }
      const reason = stderr.join("").trim()
      /* v8 ignore next -- git always writes a failure reason to stderr; exit-code fallback is a backstop. */
      rejectPromise(new Error(reason === "" ? `git clone exited with ${code}` : reason))
    })
  })
