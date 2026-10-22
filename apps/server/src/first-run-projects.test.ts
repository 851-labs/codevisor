import type { ProjectRecommendation } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { selectFirstRunProjects, type FirstRunProjectContext } from "./first-run-projects.js"

const now = Date.parse("2026-10-22T12:00:00.000Z")

const context: FirstRunProjectContext = {
  now,
  homeDirectory: "/Users/ada",
  projectFolders: ["/Users/ada/src/existing"],
  excludedRoots: ["/srv/codevisor-data"]
}

const daysAgo = (days: number): string => new Date(now - days * 24 * 60 * 60 * 1_000).toISOString()

const recommendation = (path: string, lastActivity?: string): ProjectRecommendation => ({
  path,
  name: path.split("/").at(-1)!,
  sessionCount: 1,
  ...(lastActivity === undefined ? {} : { lastActivity })
})

describe("first-run project selection", () => {
  it.each([
    { path: "/Users/ada/src/app", activity: daysAgo(1), skip: undefined },
    { path: "/Users/ada/notes", activity: daysAgo(6.9), skip: undefined },
    { path: "/Users/ada/Documents/thesis", activity: daysAgo(1), skip: undefined },
    { path: "/Users/ada/src/old", activity: daysAgo(7.1), skip: "no chats in the last 7 days" },
    { path: "/Users/ada/src/undated", activity: undefined, skip: "no chats in the last 7 days" },
    { path: "/Users/ada", activity: daysAgo(1), skip: "home folder or one of its parents" },
    { path: "/Users", activity: daysAgo(1), skip: "home folder or one of its parents" },
    { path: "/Users/ada/Desktop", activity: daysAgo(1), skip: "personal folder root" },
    { path: "/Users/ada/Documents", activity: daysAgo(1), skip: "personal folder root" },
    { path: "/Users/ada/Downloads", activity: daysAgo(1), skip: "personal folder root" },
    {
      path: "/Users/ada/Library/Application Support/Tool",
      activity: daysAgo(1),
      skip: "inside ~/Library"
    },
    { path: "/srv/codevisor-data/bots", activity: daysAgo(1), skip: "Codevisor data folder" },
    { path: "/Users/ada/src/existing", activity: daysAgo(1), skip: "already inside a project" },
    {
      path: "/Users/ada/src/existing/packages/web",
      activity: daysAgo(1),
      skip: "already inside a project"
    },
    { path: "/Users/ada/src/existing-two", activity: daysAgo(1), skip: undefined }
  ])("$path → $skip", ({ path, activity, skip }) => {
    const selection = selectFirstRunProjects([recommendation(path, activity)], context)

    if (skip === undefined) {
      expect(selection).toEqual({ added: [recommendation(path, activity)], skipped: [] })
    } else {
      expect(selection).toEqual({ added: [], skipped: [{ path, reason: skip }] })
    }
  })

  it("keeps the eight most recent folders and skips folders inside earlier picks", () => {
    const folders = Array.from({ length: 10 }, (_, index) =>
      recommendation(`/Users/ada/src/project-${index}`, daysAgo(index * 0.1))
    )
    const nested = recommendation("/Users/ada/src/project-0/docs", daysAgo(0.05))

    const selection = selectFirstRunProjects([folders[0]!, nested, ...folders.slice(1)], context)

    expect(selection.added.map((project) => project.path)).toEqual(
      folders.slice(0, 8).map((project) => project.path)
    )
    expect(selection.skipped).toEqual([
      { path: nested.path, reason: "already inside a project" },
      { path: "/Users/ada/src/project-8", reason: "over the 8-project limit" },
      { path: "/Users/ada/src/project-9", reason: "over the 8-project limit" }
    ])
  })
})
