import { SkillsError } from "./skills-store.js"

/// A skill source: something git can clone, or a site publishing skills via
/// RFC 8615 well-known endpoints.
export type ParsedSkillSource =
  | {
      readonly kind: "git"
      readonly url: string
      readonly ref?: string | undefined
      readonly subpath?: string | undefined
    }
  | { readonly kind: "wellKnown"; readonly url: string }

/// Parse the `npx skills` source formats: GitHub/GitLab `owner/repo`
/// shorthand (with optional `#ref` and `/subpath`), `github:`/`gitlab:`
/// prefixes, repository URLs (including `/tree/...` and GitLab `/-/tree/...`
/// paths), raw git/ssh URLs, local paths — and any other HTTP(S) URL, which
/// resolves through the site's `/.well-known/agent-skills` endpoint.
export const parseSkillSource = (input: string): ParsedSkillSource => {
  let source = input.trim()
  if (source === "") throw new SkillsError("A skill source is required", "invalid")
  let forcedHost: "github.com" | "gitlab.com" = "github.com"
  if (source.startsWith("github:")) source = source.slice("github:".length)
  if (source.startsWith("gitlab:")) {
    forcedHost = "gitlab.com"
    source = source.slice("gitlab:".length)
  }
  return parseNormalizedSkillSource(source, forcedHost, input)
}

const parseNormalizedSkillSource = (
  source: string,
  forcedHost: "github.com" | "gitlab.com",
  input: string
): ParsedSkillSource => {
  // Raw git/ssh URLs pass straight through (with optional #ref).
  if (source.startsWith("git@") || source.startsWith("ssh://")) {
    const [url, ref] = splitRef(source)
    return { kind: "git", ref, url }
  }

  // Local filesystem paths clone directly (useful for testing and local
  // skill repositories), with the same optional #ref suffix.
  if (source.startsWith("/") || source.startsWith("./") || source.startsWith("../")) {
    const [url, ref] = splitRef(source)
    return { kind: "git", ref, url }
  }

  if (source.startsWith("http://") || source.startsWith("https://")) {
    return parseHttpSkillSource(source, input)
  }
  return parseShorthandSkillSource(source, forcedHost, input)
}

const parseHttpSkillSource = (source: string, input: string): ParsedSkillSource => {
  const [withoutRef, ref] = splitRef(source)
  const url = new URL(withoutRef)
  if (url.hostname === "github.com" || url.hostname === "www.github.com") {
    return parseGitHubSkillSource(url, ref, input)
  }
  if (url.hostname === "gitlab.com" || url.hostname === "www.gitlab.com") {
    return parseGitLabSkillSource(url, ref, input)
  }
  // Explicit git remotes clone; anything else is a site that may publish
  // skills via its well-known endpoint.
  if (withoutRef.endsWith(".git")) {
    return { kind: "git", ref, url: withoutRef }
  }
  return { kind: "wellKnown", url: withoutRef }
}

const parseGitHubSkillSource = (
  url: URL,
  ref: string | undefined,
  input: string
): ParsedSkillSource => {
  const segments = url.pathname.split("/").filter((part) => part !== "")
  const [owner, repoRaw, marker, treeRef, ...rest] = segments
  if (owner === undefined || repoRaw === undefined) {
    throw new SkillsError(`Not a repository URL: ${input}`, "invalid")
  }
  const repo = repoRaw.endsWith(".git") ? repoRaw.slice(0, -4) : repoRaw
  // github.com/o/r/tree/<ref>/<subpath...>
  if (marker === "tree" && treeRef !== undefined) {
    return {
      kind: "git",
      ref: ref ?? treeRef,
      ...(rest.length === 0 ? {} : { subpath: rest.join("/") }),
      url: `https://github.com/${owner}/${repo}.git`
    }
  }
  return parseGitHubPathSource(owner, repo, marker, treeRef, rest, ref)
}

const parseGitHubPathSource = (
  owner: string,
  repo: string,
  marker: string | undefined,
  treeRef: string | undefined,
  rest: Array<string>,
  ref: string | undefined
): ParsedSkillSource => {
  const subpath = [marker, treeRef, ...rest].filter((part): part is string => part !== undefined)
  return {
    kind: "git",
    ref,
    ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
    url: `https://github.com/${owner}/${repo}.git`
  }
}

const parseGitLabSkillSource = (
  url: URL,
  ref: string | undefined,
  input: string
): ParsedSkillSource => {
  const segments = url.pathname.split("/").filter((part) => part !== "")
  // GitLab tree URLs use a `/-/tree/<ref>/<subpath...>` marker, with the
  // repository path (including subgroups) before the `-`.
  const dashIndex = segments.indexOf("-")
  const repoSegments = dashIndex === -1 ? segments : segments.slice(0, dashIndex)
  const repoPath = gitLabRepositoryPath(repoSegments, input)
  if (dashIndex !== -1 && segments[dashIndex + 1] === "tree") {
    return parseGitLabTreeSource(segments, dashIndex, repoPath, ref)
  }
  return { kind: "git", ref, url: `https://gitlab.com/${repoPath}.git` }
}

const gitLabRepositoryPath = (repoSegments: Array<string>, input: string): string => {
  if (repoSegments.length < 2) {
    throw new SkillsError(`Not a repository URL: ${input}`, "invalid")
  }
  const last = repoSegments[repoSegments.length - 1] as string
  return [...repoSegments.slice(0, -1), last.endsWith(".git") ? last.slice(0, -4) : last].join("/")
}

const parseGitLabTreeSource = (
  segments: Array<string>,
  dashIndex: number,
  repoPath: string,
  ref: string | undefined
): ParsedSkillSource => {
  const treeRef = segments[dashIndex + 2]
  const rest = segments.slice(dashIndex + 3)
  return {
    kind: "git",
    ref: ref ?? treeRef,
    ...(rest.length === 0 ? {} : { subpath: rest.join("/") }),
    url: `https://gitlab.com/${repoPath}.git`
  }
}

const parseShorthandSkillSource = (
  source: string,
  forcedHost: "github.com" | "gitlab.com",
  input: string
): ParsedSkillSource => {
  // owner/repo[#ref][/subpath] shorthand.
  const [withoutRef, ref] = splitRef(source)
  const segments = withoutRef.split("/").filter((part) => part !== "")
  const [owner, repo, ...subpath] = segments
  if (owner === undefined || repo === undefined) {
    throw new SkillsError(
      `Unrecognized skill source: ${input} — use owner/repo, owner/repo/path, or a git URL`,
      "invalid"
    )
  }
  return {
    kind: "git",
    ref,
    ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
    url: `https://${forcedHost}/${owner}/${repo}.git`
  }
}

const splitRef = (source: string): readonly [string, string | undefined] => {
  const index = source.indexOf("#")
  if (index === -1) return [source, undefined]
  const ref = source.slice(index + 1)
  return [source.slice(0, index), ref === "" ? undefined : ref]
}
