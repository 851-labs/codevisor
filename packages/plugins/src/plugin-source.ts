import { spawn } from "node:child_process"

import { PluginsError } from "./plugins-error.js"

export interface ParsedPluginSource {
  readonly url: string
  readonly ref?: string | undefined
  readonly subpath?: string | undefined
  readonly owner?: string | undefined
  readonly repo?: string | undefined
  readonly local?: boolean | undefined
}

export const parsePluginSource = (input: string): ParsedPluginSource => {
  const source = normalizedSource(input)

  if (source.startsWith("git@") || source.startsWith("ssh://")) {
    const [url, ref] = splitRef(source)
    return { ref, url }
  }

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
    return parseHttpSource(source, input)
  }

  return parseShorthandSource(source, input)
}

const normalizedSource = (input: string): string => {
  let source = input.trim()
  if (source === "") {
    throw new PluginsError("invalid", "A plugin source is required")
  }
  if (source.startsWith("github:")) {
    source = source.slice("github:".length)
  }

  return source
}

const parseHttpSource = (source: string, input: string): ParsedPluginSource => {
  const [withoutRef, ref] = splitRef(source)
  const url = new URL(withoutRef)
  if (url.hostname === "github.com" || url.hostname === "www.github.com") {
    return parseGitHubSource(url, ref, input)
  }
  return { ref, url: withoutRef }
}

const parseGitHubSource = (
  url: URL,
  ref: string | undefined,
  input: string
): ParsedPluginSource => {
  const segments = url.pathname.split("/").filter((part) => part !== "")
  const [owner, repoRaw, marker, treeRef, ...rest] = segments
  if (owner === undefined || repoRaw === undefined) {
    throw new PluginsError("invalid", `Not a repository URL: ${input}`)
  }
  const repo = repoRaw.endsWith(".git") ? repoRaw.slice(0, -4) : repoRaw
  if (marker === "tree" && treeRef !== undefined) {
    return {
      owner,
      repo: `${owner}/${repo}`,
      ref: ref ?? treeRef,
      ...(rest.length === 0 ? {} : { subpath: rest.join("/") }),
      url: `https://github.com/${owner}/${repo}.git`
    }
  }
  const subpath = [marker, treeRef, ...rest].filter((part): part is string => part !== undefined)
  return {
    owner,
    repo: `${owner}/${repo}`,
    ref,
    ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
    url: `https://github.com/${owner}/${repo}.git`
  }
}

const parseShorthandSource = (source: string, input: string): ParsedPluginSource => {
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
    repo: `${owner}/${repo}`,
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

export interface ClonePluginSourceResult {
  readonly resolvedCommit: string
}

export const clonePluginSource = async (
  url: string,
  ref: string | undefined,
  destination: string,
  env: NodeJS.ProcessEnv = process.env
): Promise<ClonePluginSourceResult> => {
  if (ref !== undefined && /^[0-9a-f]{40}$/i.test(ref)) {
    await runGit(["init", "--quiet", destination], env)
    await runGit(["-C", destination, "remote", "add", "origin", url], env)
    await runGit(["-C", destination, "fetch", "--depth", "1", "origin", ref], env)
    await runGit(["-C", destination, "checkout", "--quiet", "--detach", "FETCH_HEAD"], env)
  } else {
    await runGit(
      ["clone", "--depth", "1", ...(ref === undefined ? [] : ["--branch", ref]), url, destination],
      env
    )
  }
  const resolvedCommit = (await runGit(["-C", destination, "rev-parse", "HEAD"], env)).trim()
  /* v8 ignore next 3 */
  if (!/^[0-9a-f]{40}$/i.test(resolvedCommit)) {
    throw new Error("git clone succeeded but HEAD could not be resolved")
  }
  return { resolvedCommit }
}

const runGit = (args: ReadonlyArray<string>, env: NodeJS.ProcessEnv): Promise<string> =>
  new Promise((resolvePromise, rejectPromise) => {
    const child = spawn("git", args, {
      env: {
        ...env,
        GIT_ASKPASS: "true",
        GIT_SSH_COMMAND: env["GIT_SSH_COMMAND"] ?? "ssh -oBatchMode=yes",
        GIT_TERMINAL_PROMPT: "0"
      }
    })
    const stderr: Array<string> = []
    const stdout: Array<string> = []
    child.stderr.setEncoding("utf8")
    child.stdout.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => stderr.push(chunk))
    child.stdout.on("data", (chunk: string) => stdout.push(chunk))
    /* v8 ignore next */
    child.on("error", (cause) => rejectPromise(cause))
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise(stdout.join(""))
        return
      }
      const reason = stderr.join("").trim()
      /* v8 ignore next */
      rejectPromise(new Error(reason === "" ? `git exited with ${code}` : reason))
    })
  })
