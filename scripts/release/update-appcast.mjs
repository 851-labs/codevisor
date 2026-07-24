#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from "node:fs"

const option = (name) => {
  const index = process.argv.indexOf(`--${name}`)
  return index < 0 ? undefined : process.argv[index + 1]
}
const required = (name) => {
  const value = option(name)
  if (!value) throw new Error(`--${name} is required`)
  return value
}
const escapeXML = (value) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;")

const input = option("input")
const output = required("output")
const channel = required("channel")
const version = required("version")
const build = required("build")
const url = required("url")
const signature = required("signature")
const length = required("length")
const notesURL = required("release-notes-url")
const publicationDate = option("publication-date") ?? new Date().toUTCString()
if (!["alpha", "stable"].includes(channel)) throw new Error("channel must be alpha or stable")
if (!/^\d+$/.test(build) || !/^\d+$/.test(length))
  throw new Error("build and length must be integers")

const existing = input && existsSync(input) ? readFileSync(input, "utf8") : ""
const oldItems = [...existing.matchAll(/<item>[\s\S]*?<\/item>/g)]
  .map((match) => match[0])
  .filter((item) => !item.includes(`<sparkle:version>${escapeXML(build)}</sparkle:version>`))
  .slice(0, 39)
const channelElement = channel === "alpha" ? "\n      <sparkle:channel>alpha</sparkle:channel>" : ""
const item = `    <item>
      <title>Codevisor ${escapeXML(version)}${channel === "alpha" ? " Alpha" : ""}</title>
      <pubDate>${escapeXML(publicationDate)}</pubDate>
      <sparkle:version>${escapeXML(build)}</sparkle:version>
      <sparkle:shortVersionString>${escapeXML(version)}</sparkle:shortVersionString>${channelElement}
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${escapeXML(notesURL)}</sparkle:releaseNotesLink>
      <enclosure url="${escapeXML(url)}" length="${length}" type="application/octet-stream" sparkle:edSignature="${escapeXML(signature)}" />
    </item>`
const contents = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Codevisor Updates</title>
    <link>https://updates.codevisor.dev/</link>
    <description>Codevisor updates</description>
${[item, ...oldItems].join("\n")}
  </channel>
</rss>
`
writeFileSync(output, contents)
console.log(`Updated ${output} with ${channel} build ${build}`)
