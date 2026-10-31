import { describe, expect, it } from "vitest"

import {
  alertContext,
  firingAlert,
  gmailMessageSchema,
  grafanaAlertSchema,
  invoiceMessage,
  messageContext
} from "./event-filter-test-support.js"
import { compileEventFilter, type CompiledEventFilter } from "./index.js"

const filterFor = (expression: string, schema: unknown): CompiledEventFilter => {
  const result = compileEventFilter(expression, schema)
  if (!result.ok) throw new Error(result.error)
  return result.filter
}

const errorFor = (expression: string, schema: unknown): string => {
  const result = compileEventFilter(expression, schema)
  if (result.ok) throw new Error(`expected "${expression}" to be rejected`)
  return result.error
}

describe("compileEventFilter on Grafana alerts", () => {
  it.each([
    {
      expression: 'labels.host == "db-1" && severity in ["critical", "page"]',
      payload: firingAlert,
      matches: true
    },
    {
      expression: 'labels.host == "db-1" && severity in ["critical", "page"]',
      payload: { ...firingAlert, severity: "warning" },
      matches: false
    },
    {
      expression: 'labels.host == "db-1"',
      payload: { ...firingAlert, labels: { alertname: "HighCPU" } },
      matches: false
    },
    {
      expression: 'labels.host in {"db-1": true, "db-2": true}',
      payload: firingAlert,
      matches: true
    },
    { expression: '"team" in labels && labels.team != "web"', payload: firingAlert, matches: true },
    { expression: "has(labels.host)", payload: { ...firingAlert, labels: {} }, matches: false },
    {
      expression: 'labels.host.startsWith("db-") && annotations.summary.contains("Disk")',
      payload: firingAlert,
      matches: true
    },
    { expression: 'status == "firing" && values.cpu > 0.9', payload: firingAlert, matches: true },
    { expression: "values.cpu >= 1", payload: firingAlert, matches: false },
    { expression: "silenceCount == 0", payload: firingAlert, matches: true },
    { expression: "silenceCount > 2", payload: { ...firingAlert, silenceCount: 3 }, matches: true },
    {
      expression: "silenceCount < 1",
      payload: { ...firingAlert, silenceCount: 0.5 },
      matches: false
    },
    { expression: "endsAt == null", payload: firingAlert, matches: true },
    {
      expression: "endsAt != null",
      payload: { ...firingAlert, endsAt: "2026-10-27T11:00:00Z" },
      matches: true
    },
    {
      expression: 'severity == "critical"',
      payload: { ...firingAlert, severity: 3 },
      matches: false
    },
    {
      expression: 'event.name == "alert.firing" && event.account.label == "Work"',
      payload: firingAlert,
      matches: true
    },
    {
      expression: 'event.eventId.startsWith(fingerprint + ":")',
      payload: firingAlert,
      matches: true
    },
    { expression: 'status == "firing"', payload: "not an object", matches: false },
    { expression: 'event.timestamp.startsWith("2026-10-27")', payload: null, matches: true }
  ])("$expression → $matches", ({ expression, payload, matches }) => {
    expect(filterFor(expression, grafanaAlertSchema).matches(payload, alertContext)).toBe(matches)
  })

  it("treats a missing account as a non-match instead of throwing", () => {
    const filter = filterFor('event.account.id == "acct-1"', grafanaAlertSchema)
    expect(filter.matches(firingAlert, messageContext)).toBe(false)
  })
})

describe("compileEventFilter on Gmail messages", () => {
  it.each([
    {
      expression: 'from.email == "pat@client.com" && "INBOX" in labels',
      payload: invoiceMessage,
      matches: true
    },
    {
      expression: '!("SPAM" in labels) && from.name == "Pat"',
      payload: invoiceMessage,
      matches: true
    },
    {
      expression: String.raw`subject.matches("^Invoice \\d+")`,
      payload: invoiceMessage,
      matches: true
    },
    {
      expression: String.raw`subject.matches("^Receipt")`,
      payload: invoiceMessage,
      matches: false
    },
    {
      expression: 'attachments.exists(a, a.filename.endsWith(".pdf") && a.size > 1000)',
      payload: invoiceMessage,
      matches: true
    },
    { expression: "attachments.all(a, a.size < 1000)", payload: invoiceMessage, matches: false },
    { expression: "size(to) > 1 && hasAttachments", payload: invoiceMessage, matches: true },
    { expression: "sizeEstimate >= 1000000", payload: invoiceMessage, matches: false },
    {
      expression: 'to.filter(t, t.endsWith("@example.com")).exists(t, t.startsWith("billing"))',
      payload: invoiceMessage,
      matches: true
    },
    {
      expression: 'to.exists(a, to.exists(b, a != b && a.startsWith("me")))',
      payload: invoiceMessage,
      matches: true
    },
    {
      expression: 'from.email == "pat@client.com"',
      payload: { ...invoiceMessage, from: { name: "Pat" } },
      matches: false
    },
    { expression: 'event.name == "message.received"', payload: invoiceMessage, matches: true }
  ])("$expression → $matches", ({ expression, payload, matches }) => {
    expect(filterFor(expression, gmailMessageSchema).matches(payload, messageContext)).toBe(matches)
  })
})

describe("compileEventFilter rejections", () => {
  it.each([
    {
      expression: "labels.host == 1",
      schema: grafanaAlertSchema,
      error: 'no such overload: string == int in "labels.host == 1".'
    },
    {
      expression: 'nope == "x"',
      schema: grafanaAlertSchema,
      error:
        'Unknown variable: nope in "nope". Fields: status, severity, labels, annotations, values, startsAt, endsAt, fingerprint, silenceCount, event.'
    },
    {
      expression: 'from.nope == "x"',
      schema: gmailMessageSchema,
      error: 'No such key: nope in "nope".'
    },
    {
      expression: "status",
      schema: grafanaAlertSchema,
      error: "Filter must be true or false, but it gives string."
    },
    {
      expression: "labels.host ==",
      schema: grafanaAlertSchema,
      error: "Unexpected token: EOF at character 15."
    },
    {
      expression: `status in [${Array.from({ length: 101 }, (_, index) => `"s${index}"`).join(", ")}]`,
      schema: grafanaAlertSchema,
      error: "Exceeded maxListElements (100) at character 702."
    },
    {
      expression: "subject.matches(snippet)",
      schema: gmailMessageSchema,
      error: "matches() needs a quoted pattern."
    },
    {
      expression: 'subject.matches("(a+)+$")',
      schema: gmailMessageSchema,
      error: "The matches() pattern repeats a group that itself repeats or alternates."
    },
    {
      expression: 'subject.matches("(a|b)*c")',
      schema: gmailMessageSchema,
      error: "The matches() pattern repeats a group that itself repeats or alternates."
    },
    {
      expression: "to.exists(a, to.exists(b, to.exists(c, a == b && b == c)))",
      schema: gmailMessageSchema,
      error: "Filters can nest at most 2 list macros."
    },
    {
      expression: '[subject.matches("(a+)+$")].exists(s, s)',
      schema: gmailMessageSchema,
      error: "The matches() pattern repeats a group that itself repeats or alternates."
    }
  ])("$expression", ({ expression, schema, error }) => {
    expect(errorFor(expression, schema)).toBe(error)
  })

  it("rejects expressions longer than the cap", () => {
    expect(errorFor(`status == "${"x".repeat(2000)}"`, grafanaAlertSchema)).toBe(
      "Filter is too long (2012 characters, at most 2000)."
    )
  })
})

describe("compileEventFilter without a filter", () => {
  it.each([undefined, "", "   "])("matches every event for %j", (expression) => {
    const result = compileEventFilter(expression, grafanaAlertSchema)
    expect(result).toMatchObject({ ok: true, explained: "every event" })
    expect(result.ok && result.filter.matches(undefined, alertContext)).toBe(true)
  })
})
