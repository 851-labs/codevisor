import { join, resolve } from "node:path"

import type { ProjectRecommendation } from "@codevisor/api"

import { isPathInside } from "./project-recommendations.js"

export const firstRunProjectLimit = 8

export const firstRunActivityWindowMs = 7 * 24 * 60 * 60 * 1_000

export interface FirstRunProjectContext {
  readonly now: number
  readonly homeDirectory: string
  readonly projectFolders: ReadonlyArray<string>
  readonly excludedRoots: ReadonlyArray<string>
}

export interface SkippedFirstRunProject {
  readonly path: string
  readonly reason: string
}

export interface FirstRunProjectSelection {
  readonly added: ReadonlyArray<ProjectRecommendation>
  readonly skipped: ReadonlyArray<SkippedFirstRunProject>
}

export const selectFirstRunProjects = (
  recommendations: ReadonlyArray<ProjectRecommendation>,
  context: FirstRunProjectContext
): FirstRunProjectSelection => {
  const added: Array<ProjectRecommendation> = []
  const skipped: Array<SkippedFirstRunProject> = []
  for (const recommendation of recommendations) {
    const candidate = { recommendation, path: resolve(recommendation.path), added, context }
    const rule = skipRules.find((skipRule) => skipRule.applies(candidate))
    if (rule === undefined) added.push(recommendation)
    else skipped.push({ path: recommendation.path, reason: rule.reason })
  }
  return { added, skipped }
}

interface Candidate {
  readonly recommendation: ProjectRecommendation
  readonly path: string
  readonly added: ReadonlyArray<ProjectRecommendation>
  readonly context: FirstRunProjectContext
}

interface SkipRule {
  readonly reason: string
  readonly applies: (candidate: Candidate) => boolean
}

const personalFolderNames = ["Desktop", "Documents", "Downloads"]

const isRecentlyActive = ({ recommendation, context }: Candidate): boolean => {
  const activity = Date.parse(recommendation.lastActivity ?? "")
  return activity >= context.now - firstRunActivityWindowMs
}

const containsHome = ({ path, context }: Candidate): boolean =>
  isPathInside(resolve(context.homeDirectory), path)

const isPersonalFolderRoot = ({ path, context }: Candidate): boolean =>
  personalFolderNames.some((name) => path === resolve(context.homeDirectory, name))

const isInsideLibrary = ({ path, context }: Candidate): boolean =>
  isPathInside(path, join(resolve(context.homeDirectory), "Library"))

const isExcludedRoot = ({ path, context }: Candidate): boolean =>
  context.excludedRoots.some((root) => isPathInside(path, resolve(root)))

const isClaimed = ({ path, added, context }: Candidate): boolean =>
  [...context.projectFolders, ...added.map((project) => project.path)].some((folder) =>
    isPathInside(path, resolve(folder))
  )

const isOverLimit = ({ added }: Candidate): boolean => added.length >= firstRunProjectLimit

const skipRules: ReadonlyArray<SkipRule> = [
  { reason: "no chats in the last 7 days", applies: (candidate) => !isRecentlyActive(candidate) },
  { reason: "home folder or one of its parents", applies: containsHome },
  { reason: "personal folder root", applies: isPersonalFolderRoot },
  { reason: "inside ~/Library", applies: isInsideLibrary },
  { reason: "Codevisor data folder", applies: isExcludedRoot },
  { reason: "already inside a project", applies: isClaimed },
  { reason: `over the ${firstRunProjectLimit}-project limit`, applies: isOverLimit }
]
