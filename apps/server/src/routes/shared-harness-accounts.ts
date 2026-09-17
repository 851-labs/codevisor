import type { IncomingMessage, ServerResponse } from "node:http"

import { providerOAuthSupported } from "@codevisor/harness-manager"
import { Schema } from "effect"

import { sharedHarness } from "../infra/shared-account-store.js"
import {
  HttpFailure,
  matchRoute,
  readSchema,
  writeJson,
  run,
  type CodevisorServerServices
} from "../server-context.js"

const Action = Schema.Struct({
  action: Schema.Literals([
    "list",
    "create",
    "rename",
    "remove",
    "activate",
    "probe",
    "login",
    "answer",
    "cancel",
    "logout",
    "inherit",
    "providers"
  ]),
  accountId: Schema.optional(Schema.String),
  label: Schema.optional(Schema.String),
  methodId: Schema.optional(Schema.String),
  apiKey: Schema.optional(Schema.String),
  flowId: Schema.optional(Schema.String),
  code: Schema.optional(Schema.String),
  providerId: Schema.optional(Schema.String),
  inputs: Schema.optional(Schema.Record(Schema.String, Schema.String))
})

export const routeSharedHarnessAccounts = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const harnessId = matchRoute(url.pathname, "/v1/harnesses/:id/shared-accounts")
  if (!harnessId || request.method !== "POST") return false
  const shared = services.sharedAccounts
  const auth = services.auth
  if (!shared || !auth) throw new HttpFailure(501, "Update this machine to sync accounts")
  const input = await readSchema(request, Action)
  response.setHeader("Cache-Control", "no-store")
  if (harnessId === "grok-build") {
    if (["create", "rename", "inherit", "answer", "providers"].includes(input.action))
      throw new HttpFailure(400, "Unknown Grok account action")
    if (input.action === "list") {
      writeJson(response, 200, { accounts: await auth.accounts(harnessId, true) })
      return true
    }
    const account = input.accountId
      ? await run(services.db.getHarnessAccount(input.accountId))
      : undefined
    if (!account || account.harnessId !== harnessId) throw new HttpFailure(404, "Account not found")
    switch (input.action) {
      case "probe":
        writeJson(response, 200, { account: await auth.probeAccount(account.id, true, true) })
        break
      case "login":
        writeJson(response, 201, {
          flow: await auth.beginLogin(account.id, input.methodId, input.apiKey, true)
        })
        break
      case "activate":
        // Grok has one provider slot; sign-in already selects it in this scope.
        writeJson(response, 200, { accounts: await auth.accounts(harnessId, true) })
        break
      case "logout":
      case "remove":
        writeJson(response, 200, { account: await auth.logout(account.id, true) })
        break
      case "cancel":
        if (!input.flowId) throw new HttpFailure(400, "Choose a sign-in attempt")
        await auth.cancelLogin(input.flowId)
        writeJson(response, 200, {})
        break
    }
    return true
  }
  if (harnessId === "pi" || harnessId === "opencode") {
    const profile = input.accountId ?? "default"
    const account =
      harnessId === "opencode"
        ? (await run(services.db.listHarnessAccounts("opencode"))).find((row) =>
            profile === "default" ? row.profileKind === "default" : row.id === profile
          )
        : undefined
    if (harnessId === "opencode" && !account)
      throw new HttpFailure(404, "OpenCode profile not found")
    const accountId = account?.id ?? "default"
    if (input.action === "providers") {
      const configured = await shared.providers.configured(harnessId, accountId, true)
      if (harnessId === "pi") {
        if (!auth.piProviders) throw new HttpFailure(501, "Pi authentication unavailable")
        const providers = (await auth.piProviders()).map(({ credentialType: _, ...provider }) => ({
          ...provider,
          ...(configured.includes(provider.id) ? { credentialType: "oauth" } : {})
        }))
        writeJson(response, 200, { piProviders: providers })
      } else {
        if (!auth.openCodeProviders)
          throw new HttpFailure(501, "OpenCode authentication unavailable")
        const providers = (await auth.openCodeProviders(accountId)).map(
          ({ credentialType: _, ...provider }) => ({
            ...provider,
            methods: provider.methods.filter(
              (method) => method.type !== "oauth" || providerOAuthSupported("opencode", provider.id)
            ),
            ...(configured.includes(provider.id) ? { credentialType: "oauth" } : {})
          })
        )
        writeJson(response, 200, { openCodeProviders: providers })
      }
    } else if (input.action === "login") {
      if (!input.providerId || !providerOAuthSupported(harnessId, input.providerId))
        throw new HttpFailure(400, "This provider does not support shared OAuth")
      if (harnessId === "pi") {
        if (!auth.beginPiLogin || input.methodId !== "oauth")
          throw new HttpFailure(400, "Choose an OAuth method")
        writeJson(response, 201, {
          piFlow: await auth.beginPiLogin(input.providerId, "oauth", true)
        })
      } else {
        if (!auth.beginOpenCodeLogin || !input.methodId)
          throw new HttpFailure(400, "Choose an OAuth method")
        writeJson(response, 201, {
          openCodeFlow: await auth.beginOpenCodeLogin(
            accountId,
            input.providerId,
            input.methodId,
            input.inputs,
            undefined,
            true
          )
        })
      }
    } else if (input.action === "logout" || input.action === "remove") {
      if (!input.providerId) throw new HttpFailure(400, "Choose a provider")
      await shared.providers.remove(harnessId, accountId, input.providerId, true)
      writeJson(response, 200, {})
    } else throw new HttpFailure(400, "Unknown provider account action")
    return true
  }
  if (!sharedHarness(harnessId))
    throw new HttpFailure(400, "This harness uses provider-specific account settings")
  if (input.action === "list") {
    writeJson(response, 200, { accounts: await shared.accounts(harnessId, true) })
    return true
  }
  if (input.action === "create") {
    writeJson(response, 201, { account: await shared.create(harnessId, input.label) })
    return true
  }
  if (input.action === "inherit") {
    await shared.inherit(harnessId)
    writeJson(response, 200, { accounts: await shared.accounts(harnessId) })
    return true
  }
  const id = input.accountId
  const account = id ? await run(services.db.getHarnessAccount(id)) : undefined
  if (!account || account.harnessId !== harnessId) throw new HttpFailure(404, "Account not found")
  switch (input.action) {
    case "activate":
      if (!(await shared.activate(harnessId, account.id, true)))
        throw new HttpFailure(404, "Shared account not found")
      writeJson(response, 200, { accounts: await shared.accounts(harnessId, true) })
      break
    case "rename":
      if (!input.label?.trim()) throw new HttpFailure(400, "Enter an account name")
      writeJson(response, 200, { account: await shared.rename(account.id, input.label) })
      break
    case "remove":
    case "logout":
      writeJson(response, 200, { account: await shared.logout(account.id, true) })
      break
    case "probe":
      writeJson(response, 200, { account: await shared.probe(account.id, true) })
      break
    case "login":
      if (input.methodId === "apiKey") {
        await shared.saveApiKey(account.id, input.apiKey ?? "")
        writeJson(response, 200, {
          flow: { id: account.id, accountId: account.id, kind: "complete" }
        })
      } else
        writeJson(response, 201, {
          flow: await auth.beginLogin(account.id, input.methodId, input.apiKey)
        })
      break
    case "answer":
      if (!input.flowId || !input.code) throw new HttpFailure(400, "Enter the sign-in code")
      writeJson(response, 200, { flow: await auth.answerLogin(input.flowId, input.code) })
      break
    case "cancel":
      if (!input.flowId) throw new HttpFailure(400, "Sign-in not found")
      await auth.cancelLogin(input.flowId)
      writeJson(response, 200, {})
      break
    case "providers":
      throw new HttpFailure(400, "This harness has account settings")
  }
  return true
}
