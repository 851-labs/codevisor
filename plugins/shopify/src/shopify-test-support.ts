import { anyResult, connectClient, withAccount } from "@codevisor/plugin-kit/test-support"
import { onTestFinished } from "vitest"

import { makeShopifyCli } from "./shopify-cli.js"
import type { ProcessResult, RunProcess } from "./shopify-process.js"
import { createShopifyServer } from "./shopify-server.js"

export interface CliCall {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

export interface FakeShopifyCli {
  readonly run: RunProcess
  readonly calls: Array<CliCall>
  readonly respond: (result: Partial<ProcessResult>) => void
}

export const fakeShopifyCli = (): FakeShopifyCli => {
  const calls: Array<CliCall> = []
  const replies: Array<ProcessResult> = []
  return {
    calls,
    respond: (result) => {
      replies.push({ code: 0, stdout: "", stderr: "", ...result })
    },
    run: async (command, args) => {
      calls.push({ command, args })
      const reply = replies.shift()
      if (reply === undefined) throw new Error(`Unexpected CLI call: ${args.join(" ")}`)
      return reply
    }
  }
}

export const cliJson = (value: unknown): Partial<ProcessResult> => ({
  stdout: `Shopify CLI will open the app authorization page in your browser.\n${JSON.stringify(value)}\n`
})

export const cliFailure = (error: Record<string, unknown>): Partial<ProcessResult> => ({
  code: 1,
  stdout: `${JSON.stringify({ error: { type: "abort", ...error } })}\n`
})

export const shopifyCommand = { command: "/usr/local/bin/shopify", args: [] }

export const connectShopify = async (fake: FakeShopifyCli) => {
  const cli = makeShopifyCli({ locate: async () => shopifyCommand, run: fake.run })
  const { client } = await connectClient(createShopifyServer(cli))
  onTestFinished(() => client.close())
  return {
    callTool: (name: string, args: Record<string, unknown>, store?: string) =>
      client.callTool({
        name,
        arguments: args,
        ...(store === undefined ? {} : { _meta: withAccount("store-1", { store }) })
      }),
    signIn: (values: Record<string, unknown>, scopes: ReadonlyArray<string>) =>
      client.request({ method: "codevisor/account/signIn", params: { values, scopes } }, anyResult)
  }
}
