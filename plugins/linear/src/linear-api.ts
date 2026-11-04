import type { z } from "zod"

import { rejectedLinearSignIn } from "./linear-account.js"
import {
  commentData,
  graphqlResponse,
  issueData,
  stateData,
  userData,
  viewerData
} from "./linear-api-schemas.js"
import { linearQueries } from "./linear-queries.js"

export type {
  LinearComment,
  LinearIssue,
  LinearPerson,
  LinearState,
  LinearViewer
} from "./linear-api-schemas.js"

export type Fetch = (url: string, init: RequestInit) => Promise<Response>

export class LinearApiError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}

export const linearGraphqlUrl = "https://api.linear.app/graphql"
export const linearRevokeUrl = "https://api.linear.app/oauth/revoke"
export const linearRequestTimeoutMs = 30_000

export const linearApi = (fetcher: Fetch, accessToken: string) => {
  const query = graphqlCaller(fetcher, accessToken)
  return {
    viewer: async () => (await query(viewerData, linearQueries.viewer, {})).viewer,
    issue: async (id: string) =>
      (await query(issueData, linearQueries.issue, { id }).catch(missingAsNull)).issue,
    comment: async (id: string) =>
      (await query(commentData, linearQueries.comment, { id }).catch(missingAsNull)).comment,
    state: async (id: string) =>
      (await query(stateData, linearQueries.state, { id }).catch(missingAsNull)).workflowState,
    user: async (id: string) =>
      (await query(userData, linearQueries.user, { id }).catch(missingAsNull)).user,
    revoke: () => revokeToken(fetcher, accessToken)
  }
}

export type LinearApi = ReturnType<typeof linearApi>

type GraphqlCaller = <T>(
  schema: z.ZodType<T>,
  query: string,
  variables: Record<string, unknown>
) => Promise<T>

const graphqlCaller =
  (fetcher: Fetch, accessToken: string): GraphqlCaller =>
  async (schema, query, variables) => {
    const response = await fetcher(linearGraphqlUrl, graphqlInit(accessToken, query, variables))
    if (response.status === unauthorized)
      throw new LinearApiError(unauthorized, rejectedLinearSignIn)

    const body = graphqlResponse.parse(await response.json().catch(() => ({})))
    const failure = graphqlFailure(response.status, body)
    if (failure !== undefined) throw failure

    return schema.parse(body.data)
  }

const graphqlInit = (
  accessToken: string,
  query: string,
  variables: Record<string, unknown>
): RequestInit => ({
  method: "POST",
  headers: {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
    Accept: "application/json"
  },
  body: JSON.stringify({ query, variables }),
  signal: AbortSignal.timeout(linearRequestTimeoutMs)
})

const graphqlFailure = (
  status: number,
  body: z.infer<typeof graphqlResponse>
): LinearApiError | undefined => {
  const error = body.errors?.[0]
  if (error === undefined && status < firstErrorStatus) return undefined
  if (error === undefined) return new LinearApiError(status, `Linear returned ${status}`)
  if (isAuthenticationError(error)) return new LinearApiError(unauthorized, rejectedLinearSignIn)
  if (isNotFoundError(error)) return new LinearApiError(notFound, error.message)

  return new LinearApiError(status, `Linear returned: ${error.message}`)
}

type GraphqlError = NonNullable<z.infer<typeof graphqlResponse>["errors"]>[number]

const isAuthenticationError = (error: GraphqlError): boolean =>
  error.extensions?.type === "authentication error" ||
  error.extensions?.["code"] === "AUTHENTICATION_ERROR"

const isNotFoundError = (error: GraphqlError): boolean => /entity not found/i.test(error.message)

const missingAsNull = (error: unknown): Record<string, null> => {
  if (error instanceof LinearApiError && error.status === notFound) return {}
  throw error
}

const revokeToken = async (fetcher: Fetch, accessToken: string): Promise<void> => {
  await fetcher(linearRevokeUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token: accessToken }).toString(),
    signal: AbortSignal.timeout(linearRequestTimeoutMs)
  })
}

const unauthorized = 401
const notFound = 404
const firstErrorStatus = 400
