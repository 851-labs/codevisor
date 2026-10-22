import { join } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"

export interface GrokCredentialPlan {
  readonly env: Readonly<Record<string, string>>
  readonly unset: ReadonlyArray<string>
  readonly broker?: { readonly capability: string }
}

export const grokResources = ["sessions", "config.toml"]

export const grokCredentialPlan = (
  root: string,
  apiKey: string | undefined,
  managed: { readonly capability: string } | undefined
): GrokCredentialPlan => {
  if (apiKey)
    return { env: { XAI_API_KEY: apiKey }, unset: ["GROK_AUTH", "GROK_AUTH_PROVIDER_COMMAND"] }
  if (!managed)
    return { env: { GROK_AUTH_PROVIDER_COMMAND: "false" }, unset: ["GROK_AUTH", "XAI_API_KEY"] }
  return {
    env: {
      GROK_AUTH_PROVIDER_COMMAND: `/bin/sh ${shellQuote(grokTokenCommand(root))}`,
      GROK_AUTH_PROVIDER_LABEL: "Codevisor"
    },
    unset: ["GROK_AUTH", "XAI_API_KEY"],
    broker: { capability: managed.capability }
  }
}

export const grokEnv = (
  base: HarnessAccountContext,
  root: string,
  manifestPath: string,
  plan: GrokCredentialPlan
): Record<string, string> => {
  const env: Record<string, string> = {
    ...base.env,
    CODEVISOR_PROVIDER_AUTH: manifestPath,
    GROK_HOME: root,
    GROK_AUTH_PATH: join(root, "auth.json")
  }
  for (const name of plan.unset) delete env[name]
  return { ...env, ...plan.env }
}

export const grokTokenCommand = (root: string) => join(root, "token.sh")

export const grokCurlConfig = (url: string, capability: string) =>
  `url = ${JSON.stringify(url)}\nheader = ${JSON.stringify(`Authorization: Bearer ${capability}`)}\nheader = "Content-Type: application/json"\nrequest = "POST"\nsilent\nshow-error\nfail\nmax-time = 6\n`

export const grokTokenScript = (curlConfig: string) =>
  `#!/bin/sh\nif [ "\${GROK_AUTH_EXPIRED:-0}" = "1" ]; then\n  exec curl --config ${shellQuote(curlConfig)} --data '{"force":true}'\nfi\nexec curl --config ${shellQuote(curlConfig)} --data '{}'\n`

const shellQuote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`
