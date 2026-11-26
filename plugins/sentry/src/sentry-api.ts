import { z } from "zod"

import { rejectedSentrySignIn } from "./sentry-account.js"
import {
  sentryIssue,
  type SentryOrganization,
  sentryOrganization,
  sentryPerson,
  sentryTeam
} from "./sentry-api-schemas.js"

export type {
  SentryActivity,
  SentryAssignee,
  SentryIssue,
  SentryOrganization,
  SentryPerson,
  SentryTeam
} from "./sentry-api-schemas.js"

export type Fetch = (url: string, init: RequestInit) => Promise<Response>

export interface SentryHosts {
  apiUrl: string
  mcpUrl: string
}

export const sentryCloudHosts: SentryHosts = {
  apiUrl: "https://sentry.io",
  mcpUrl: "https://mcp.sentry.dev/mcp"
}

export class SentryApiError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}

export interface IssueSearch {
  query: string
  sort: "new" | "date"
  limit: number
}

export const sentryRequestTimeoutMs = 30_000

export const sentryApi = (fetcher: Fetch, hosts: SentryHosts, accessToken: string) => {
  const get = getter(fetcher, accessToken)
  const regionOf = (organization: SentryOrganization) =>
    organization.links?.regionUrl || hosts.apiUrl
  const orgPath = (organization: SentryOrganization, path: string) =>
    `${regionOf(organization)}/api/0/organizations/${encodeURIComponent(organization.slug)}/${path}`

  return {
    me: () => get(`${hosts.apiUrl}/api/0/users/me/`, sentryPerson),
    organizations: () =>
      get(`${hosts.apiUrl}/api/0/organizations/?member=1`, z.array(sentryOrganization)),
    myTeams: (organization: SentryOrganization) =>
      get(orgPath(organization, "user-teams/"), z.array(sentryTeam)),
    issues: (organization: SentryOrganization, search: IssueSearch) =>
      get(orgPath(organization, `issues/?${searchParams(search)}`), z.array(sentryIssue)),
    issue: (organization: SentryOrganization, issueId: string) =>
      get(orgPath(organization, `issues/${encodeURIComponent(issueId)}/`), sentryIssue).catch(
        missingAsUndefined
      )
  }
}

export type SentryApi = ReturnType<typeof sentryApi>

type Getter = <T>(url: string, schema: z.ZodType<T>) => Promise<T>

const getter =
  (fetcher: Fetch, accessToken: string): Getter =>
  async (url, schema) => {
    const response = await fetcher(url, {
      headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" },
      signal: AbortSignal.timeout(sentryRequestTimeoutMs)
    })
    if (response.status === unauthorized)
      throw new SentryApiError(unauthorized, rejectedSentrySignIn)
    if (!response.ok)
      throw new SentryApiError(response.status, `Sentry returned ${response.status}`)

    return schema.parse(await response.json())
  }

const searchParams = (search: IssueSearch): string =>
  new URLSearchParams({
    query: search.query,
    sort: search.sort,
    limit: String(search.limit)
  }).toString()

const missingAsUndefined = (error: unknown): undefined => {
  if (error instanceof SentryApiError && error.status === notFound) return undefined
  throw error
}

const unauthorized = 401
const notFound = 404
