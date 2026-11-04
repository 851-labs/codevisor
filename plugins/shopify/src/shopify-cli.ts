import { z } from "zod"

import type { CliCommand } from "./shopify-cli-install.js"
import type { ProcessResult, RunProcess } from "./shopify-process.js"
import { ShopifyToolError } from "./shopify-store.js"

export interface StoreSession {
  readonly store: string
  readonly email: string | undefined
}

export interface ExecuteRequest {
  readonly query: string
  readonly variables?: Record<string, unknown> | undefined
  readonly allowMutations: boolean
}

export interface ShopifyCli {
  readonly signIn: (store: string, scopes: ReadonlyArray<string>) => Promise<StoreSession>
  readonly execute: (store: string, request: ExecuteRequest) => Promise<Record<string, unknown>>
}

export interface ShopifyCliDeps {
  readonly locate: () => Promise<CliCommand>
  readonly run: RunProcess
}

export const makeShopifyCli = (deps: ShopifyCliDeps): ShopifyCli => {
  const shopify = async (args: ReadonlyArray<string>, timeoutMs: number) => {
    const cli = await deps.locate()
    const result = await deps.run(cli.command, [...cli.args, ...args, ...jsonFlags], { timeoutMs })
    return outputOf(result)
  }

  return {
    signIn: async (store, scopes) => {
      const output = await shopify(signInArgs(store, scopes), signInTimeoutMs)
      const session = signedInSchema.parse(output)
      return { store: session.store, email: session.associatedUser?.email }
    },
    execute: async (store, request) => {
      const output = await shopify(executeArgs(store, request), executeTimeoutMs)
      return executedSchema.parse(output)
    }
  }
}

const signInArgs = (store: string, scopes: ReadonlyArray<string>): ReadonlyArray<string> => [
  "store",
  "auth",
  "--store",
  store,
  "--scopes",
  scopes.join(",")
]

const executeArgs = (store: string, request: ExecuteRequest): ReadonlyArray<string> => [
  "store",
  "execute",
  "--store",
  store,
  "--query",
  request.query,
  ...(request.variables === undefined ? [] : ["--variables", JSON.stringify(request.variables)]),
  ...(request.allowMutations ? ["--allow-mutations"] : [])
]

const outputOf = (result: ProcessResult): Record<string, unknown> => {
  const output = lastJsonObject(result.stdout)
  const failure = failureSchema.safeParse(output)
  if (failure.success) throw new ShopifyCliError(failureMessage(failure.data.error))
  if (result.code !== 0 || output === undefined) throw new ShopifyCliError(unreadable(result))

  return output
}

const lastJsonObject = (stdout: string): Record<string, unknown> | undefined =>
  stdout
    .split("\n")
    .toReversed()
    .map(parsedObject)
    .find((parsed) => parsed !== undefined)

const parsedObject = (line: string): Record<string, unknown> | undefined => {
  try {
    const parsed: unknown = JSON.parse(line)
    return isRecord(parsed) ? parsed : undefined
  } catch {
    return undefined
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

export class ShopifyCliError extends ShopifyToolError {}

const failureMessage = (error: z.infer<typeof failureSchema>["error"]): string => {
  const store = notSignedInPattern.exec(error.message)?.[1]
  if (store !== undefined) return notSignedIn(store)

  return [error.message, error.tryMessage, ...(error.nextSteps ?? [])]
    .filter((part) => part !== undefined)
    .join(" ")
}

const notSignedInPattern = /^No stored app authentication found for (.+)\.$/

const notSignedIn = (store: string): string =>
  `Shopify isn't signed in to ${store} on this machine. Ask the user to sign in from Settings › Plugins › Shopify.`

const unreadable = (result: ProcessResult): string =>
  `The Shopify CLI failed (exit ${String(result.code)}): ${(result.stderr || result.stdout).trim().slice(0, maxErrorLength)}`

const failureSchema = z.object({
  error: z.object({
    message: z.string(),
    tryMessage: z.string().optional(),
    nextSteps: z.array(z.string()).optional()
  })
})

const signedInSchema = z.object({
  store: z.string(),
  associatedUser: z.object({ email: z.string().optional() }).loose().optional()
})

const executedSchema = z.object({ data: z.unknown() }).loose()

const jsonFlags = ["--json", "--no-color"]
const signInTimeoutMs = 6 * 60_000
const executeTimeoutMs = 2 * 60_000
const maxErrorLength = 2_000
