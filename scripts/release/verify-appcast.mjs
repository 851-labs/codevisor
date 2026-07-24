#!/usr/bin/env node
import { readFileSync } from "node:fs"

export const verifyAppcast = (contents, build, expectedChannel) => {
  if (!/^\d+$/.test(build)) throw new Error("build must be an integer")
  if (!["alpha", "stable"].includes(expectedChannel))
    throw new Error("expected channel must be alpha or stable")

  const matchingItems = [...contents.matchAll(/<item>[\s\S]*?<\/item>/g)]
    .map((match) => match[0])
    .filter((item) => item.includes(`<sparkle:version>${build}</sparkle:version>`))
  if (matchingItems.length !== 1)
    throw new Error(`expected exactly one appcast item for build ${build}`)

  const item = matchingItems[0]
  const channel = item.match(/<sparkle:channel>([^<]+)<\/sparkle:channel>/)?.[1]
  if (expectedChannel === "alpha" && channel !== "alpha")
    throw new Error(`build ${build} is not on the Alpha channel`)
  if (expectedChannel === "stable" && channel !== undefined)
    throw new Error(`build ${build} still has the ${channel} channel`)

  const enclosure = item.match(/<enclosure\b[^>]*\/>/)?.[0]
  if (!enclosure) throw new Error(`build ${build} has no enclosure`)
  if (!/\burl="https:\/\/[^"]+"/.test(enclosure))
    throw new Error(`build ${build} has no HTTPS enclosure URL`)
  if (!/\blength="[1-9]\d*"/.test(enclosure))
    throw new Error(`build ${build} has no positive enclosure length`)
  if (!/\bsparkle:edSignature="[^"]+"/.test(enclosure))
    throw new Error(`build ${build} has no EdDSA signature`)
}

if (process.argv[1] === import.meta.filename) {
  const [, , path, build, channel] = process.argv
  if (!path || !build || !channel) {
    console.error("usage: verify-appcast.mjs <appcast-path> <build> <alpha|stable>")
    process.exit(1)
  }
  verifyAppcast(readFileSync(path, "utf8"), build, channel)
}
