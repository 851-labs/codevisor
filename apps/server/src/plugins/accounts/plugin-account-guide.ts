import type {
  PluginAccountGuide,
  PluginAccountGuideLink,
  PluginAccountGuideStep,
  ResolvedPluginAccountGuide,
  ResolvedPluginAccountGuideStep
} from "@codevisor/api"

import { HttpFailure } from "../../server-context.js"
import { isRecord } from "../../unknown-values.js"

export interface GuideIngressUrl {
  readonly name: string
  readonly url: string
}

export const resolveAccountGuide = (
  guide: PluginAccountGuide,
  accountId: string,
  ingress: ReadonlyArray<GuideIngressUrl>
): ResolvedPluginAccountGuide => {
  const values = new Map(ingress.map((entry) => [entry.name, entry.url]))
  return {
    accountId,
    title: guide.title,
    summary: guide.summary,
    steps: guide.steps.map((step) => resolvedStep(step, values))
  }
}

export const requireGuideAccountId = (accountId: string): string => {
  if (guideAccountIdPattern.test(accountId)) return accountId
  throw new HttpFailure(400, "Account ids for guided setup must be UUIDs")
}

const guideAccountIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type IngressValues = ReadonlyMap<string, string>

const resolvedStep = (
  step: PluginAccountGuideStep,
  values: IngressValues
): ResolvedPluginAccountGuideStep => ({
  title: step.title,
  detail: step.detail,
  ...(step.link === undefined ? {} : { link: resolvedLink(step.link, values) }),
  fields: [...(step.fields ?? [])]
})

const resolvedLink = (link: PluginAccountGuideLink, values: IngressValues) => {
  const url = new URL(filled(link.url, values))
  const pairs = [
    ...url.searchParams.entries(),
    ...Object.entries(link.query ?? {}).map(([key, value]) => [key, queryValue(value, values)])
  ]
  url.search = pairs.map(([key, value]) => `${encoded(key)}=${encoded(value)}`).join("&")
  return { title: link.title, url: url.toString() }
}

const encoded = (text: string | undefined): string => encodeURIComponent(text ?? "")

const queryValue = (value: unknown, values: IngressValues): string => {
  if (typeof value === "string") return filled(value, values)
  return JSON.stringify(filledJson(value, values))
}

const filledJson = (value: unknown, values: IngressValues): unknown => {
  if (typeof value === "string") return filled(value, values)
  if (Array.isArray(value)) return value.map((item) => filledJson(item, values))
  if (!isRecord(value)) return value

  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [key, filledJson(item, values)])
  )
}

const filled = (text: string, values: IngressValues): string =>
  text.replaceAll(ingressPlaceholder, (_match, name: string) => ingressUrl(values, name))

const ingressPlaceholder = /\{\{ingress\.([\w-]+)\}\}/g

const ingressUrl = (values: IngressValues, name: string): string => {
  const url = values.get(name)
  if (url !== undefined) return url

  throw new HttpFailure(
    409,
    "Sign in to Codevisor Cloud to set up this account. Its webhook URL comes from Codevisor Cloud."
  )
}
