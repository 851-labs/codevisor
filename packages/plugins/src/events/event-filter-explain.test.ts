import { describe, expect, it } from "vitest"

import { explainEventFilter } from "./index.js"

describe("explainEventFilter", () => {
  it.each([
    { expression: undefined, explained: "every event" },
    { expression: "  ", explained: "every event" },
    {
      expression: 'labels.host == "db-1" && severity in ["critical", "page"]',
      explained: 'labels.host is "db-1" and severity is one of "critical" or "page"'
    },
    {
      expression: 'severity in ["critical", "page", "major"]',
      explained: 'severity is one of "critical", "page" or "major"'
    },
    { expression: 'severity in ["critical"]', explained: 'severity is "critical"' },
    { expression: "severity in []", explained: "severity is one of nothing" },
    {
      expression: '!(severity in ["info", "debug"])',
      explained: 'severity is not one of "info" or "debug"'
    },
    { expression: '"INBOX" in labels', explained: 'labels contains "INBOX"' },
    { expression: '!("SPAM" in labels)', explained: 'labels does not contain "SPAM"' },
    { expression: 'status != "resolved"', explained: 'status is not "resolved"' },
    {
      expression: "values.cpu > 0.9 || count >= 3",
      explained: "values.cpu is greater than 0.9 or count is at least 3"
    },
    {
      expression: "count < 3 && size <= 10",
      explained: "count is less than 3 and size is at most 10"
    },
    {
      expression: "a == 1 && (b == 2 || c == 3) || d == 4",
      explained: "(a is 1 and (b is 2 or c is 3)) or d is 4"
    },
    { expression: '!(status == "firing")', explained: 'not (status is "firing")' },
    {
      expression: 'subject.startsWith("Invoice") && from.email.endsWith("@client.com")',
      explained: 'subject starts with "Invoice" and from.email ends with "@client.com"'
    },
    { expression: 'snippet.contains("urgent")', explained: 'snippet contains "urgent"' },
    { expression: 'subject.matches("^Inv")', explained: 'subject matches the pattern "^Inv"' },
    { expression: "has(labels.host)", explained: "labels.host is set" },
    { expression: "size(to) > 1", explained: "size(to) is greater than 1" },
    { expression: 'to.exists(t, t == "me")', explained: 'to.exists(t, t == "me")' },
    { expression: "hasAttachments", explained: "hasAttachments" },
    { expression: "isUrgent(subject)", explained: "isUrgent(subject)" },
    { expression: "has(a.b, c)", explained: "has(a.b, c)" },
    { expression: 'subject.contains("a", "b")', explained: 'subject.contains("a", "b")' },
    { expression: "subject.lowerAscii()", explained: "subject.lowerAscii()" },
    { expression: "labels.host ==", explained: "labels.host ==" }
  ])("$expression", ({ expression, explained }) => {
    expect(explainEventFilter(expression)).toBe(explained)
  })
})
