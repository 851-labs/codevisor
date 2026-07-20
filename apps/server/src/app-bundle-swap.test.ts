import { generateKeyPairSync, sign as cryptoSign } from "node:crypto"
import { describe, expect, it } from "vitest"
import {
  applyAppBundleSwap,
  verifyEdDSASignature,
  type AppBundleSwapOps
} from "./app-bundle-swap.js"

/// Real Ed25519 material: Sparkle's SUPublicEDKey is the raw 32-byte public
/// key in base64, which is the tail of the SPKI DER export.
const keyPair = generateKeyPairSync("ed25519")
const rawPublicKey = keyPair.publicKey
  .export({ format: "der", type: "spki" })
  .subarray(-32)
  .toString("base64")

const zipData = Buffer.from("fake zip bytes for the swap test")
const goodSignature = cryptoSign(null, zipData, keyPair.privateKey).toString("base64")

const appcast = (signature: string, length = zipData.length): string => `<rss><channel><item>
  <sparkle:version>5591</sparkle:version>
  <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
  <enclosure url="https://example.com/ChatGPT.zip" length="${length}" sparkle:edSignature="${signature}" />
</item></channel></rss>`

interface OpsOverrides {
  readonly publicKey?: string | undefined
  readonly newTeam?: string
  readonly codesignVerifyFails?: boolean
  readonly failSecondRename?: boolean
  readonly fileSize?: number
}

const makeOps = (overrides: OpsOverrides = {}) => {
  const calls: Array<string> = []
  let renames = 0
  const ops: AppBundleSwapOps = {
    download: async (url) => {
      calls.push(`download ${url}`)
    },
    execFile: async (command, args) => {
      calls.push(`${command} ${args[0] ?? ""}`.trim())
      if (command === "plutil") {
        const key = "publicKey" in overrides ? overrides.publicKey : rawPublicKey
        if (key === undefined) throw new Error("missing key")
        return { stderr: "", stdout: `${key}\n` }
      }
      if (command === "codesign" && args[0] === "-dv") {
        const isNew = (args.at(-1) ?? "").includes("extracted")
        const team = isNew ? (overrides.newTeam ?? "TEAM1234X") : "TEAM1234X"
        return { stderr: `TeamIdentifier=${team}\n`, stdout: "" }
      }
      if (command === "codesign" && args[0] === "--verify") {
        if (overrides.codesignVerifyFails === true) {
          throw new Error("code object is not signed at all")
        }
        return { stderr: "", stdout: "" }
      }
      return { stderr: "", stdout: "" }
    },
    fileSize: async () => overrides.fileSize ?? zipData.length,
    mkdir: async (path) => {
      calls.push(`mkdir ${path}`)
    },
    readFile: async () => zipData,
    readdir: async () => ["ChatGPT.app"],
    remove: async (path) => {
      calls.push(`remove ${path}`)
    },
    rename: async (from, to) => {
      renames += 1
      calls.push(`rename ${from} -> ${to}`)
      if (overrides.failSecondRename === true && renames === 2) {
        throw new Error("rename blocked")
      }
    }
  }
  return { calls, ops }
}

const bundlePath = "/Applications/ChatGPT.app"

describe("verifyEdDSASignature", () => {
  it("accepts a valid signature and rejects tampering", () => {
    expect(verifyEdDSASignature(zipData, goodSignature, rawPublicKey)).toBe(true)
    const tampered = Buffer.from(zipData)
    tampered[0] = tampered[0]! ^ 0xff
    expect(verifyEdDSASignature(tampered, goodSignature, rawPublicKey)).toBe(false)
    expect(verifyEdDSASignature(zipData, goodSignature, Buffer.alloc(16).toString("base64"))).toBe(
      false
    )
  })
})

describe("applyAppBundleSwap", () => {
  it("verifies, extracts, and swaps with the staged rename sequence", async () => {
    const { calls, ops } = makeOps()
    const result = await applyAppBundleSwap({
      appcastXml: appcast(goodSignature),
      bundlePath,
      ops
    })
    expect(result).toEqual({ installedVersion: "26.715.52143" })
    const renameCalls = calls.filter((call) => call.startsWith("rename"))
    expect(renameCalls).toEqual([
      `rename ${bundlePath} -> ${bundlePath}.codevisor-old`,
      expect.stringContaining(`-> ${bundlePath}`)
    ])
    // Verification strictly precedes any mutation of the installed bundle.
    const firstRename = calls.findIndex((call) => call.startsWith("rename"))
    expect(calls.slice(0, firstRename)).toEqual(
      expect.arrayContaining(["codesign --verify", "ditto -x"])
    )
    // The old bundle is discarded only after the swap.
    expect(calls.filter((call) => call === `remove ${bundlePath}.codevisor-old`)).toHaveLength(2)
  })

  it.each([
    ["tampered signature", { appcastXml: appcast(goodSignature.replace(/^./, "X")) }, {}],
    ["missing public key", { appcastXml: appcast(goodSignature) }, { publicKey: undefined }],
    ["codesign failure", { appcastXml: appcast(goodSignature) }, { codesignVerifyFails: true }],
    ["team mismatch", { appcastXml: appcast(goodSignature) }, { newTeam: "EVIL9999X" }],
    ["short download", { appcastXml: appcast(goodSignature) }, { fileSize: 3 }]
  ] as const)("aborts before any rename on %s", async (_name, options, overrides) => {
    const { calls, ops } = makeOps(overrides)
    await expect(applyAppBundleSwap({ bundlePath, ops, ...options })).rejects.toThrow()
    expect(calls.some((call) => call.startsWith("rename"))).toBe(false)
  })

  it("aborts when the installed app's Team ID is unreadable", async () => {
    const { calls, ops } = makeOps()
    const unreadableTeam: AppBundleSwapOps = {
      ...ops,
      execFile: async (command, args) => {
        if (command === "codesign" && args[0] === "-dv") {
          // Ad-hoc/unsigned bundles report no TeamIdentifier line.
          return { stderr: "Signature=adhoc\n", stdout: "" }
        }
        return ops.execFile(command, args)
      }
    }
    await expect(
      applyAppBundleSwap({ appcastXml: appcast(goodSignature), bundlePath, ops: unreadableTeam })
    ).rejects.toThrow(/Team ID/)
    expect(calls.some((call) => call.startsWith("rename"))).toBe(false)
  })

  it("rejects feeds whose latest item lacks a version", async () => {
    const { ops } = makeOps()
    const versionless = `<rss><channel><item>
      <enclosure url="https://example.com/x.zip" sparkle:edSignature="sig==" />
    </item></channel></rss>`
    await expect(applyAppBundleSwap({ appcastXml: versionless, bundlePath, ops })).rejects.toThrow(
      /no usable release/
    )
    // As does a feed with no items at all.
    await expect(applyAppBundleSwap({ appcastXml: "<rss/>", bundlePath, ops })).rejects.toThrow(
      /no usable release/
    )
  })

  it("aborts when the installed app reports an empty Sparkle key", async () => {
    const { calls, ops } = makeOps()
    const emptyKey: AppBundleSwapOps = {
      ...ops,
      execFile: async (command, args) =>
        command === "plutil" ? { stderr: "", stdout: "\n" } : ops.execFile(command, args)
    }
    await expect(
      applyAppBundleSwap({ appcastXml: appcast(goodSignature), bundlePath, ops: emptyKey })
    ).rejects.toThrow(/no Sparkle public key/)
    expect(calls.some((call) => call.startsWith("rename"))).toBe(false)
  })

  it("swaps without a size check when the feed omits the length", async () => {
    const { ops } = makeOps({ fileSize: 999_999 })
    const lengthless = `<rss><channel><item>
      <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
      <enclosure url="https://example.com/ChatGPT.zip" sparkle:edSignature="${goodSignature}" />
    </item></channel></rss>`
    await expect(applyAppBundleSwap({ appcastXml: lengthless, bundlePath, ops })).resolves.toEqual({
      installedVersion: "26.715.52143"
    })
  })

  it("aborts when the archive contains no app bundle", async () => {
    const { calls, ops } = makeOps()
    const emptyArchive: AppBundleSwapOps = { ...ops, readdir: async () => ["README.txt"] }
    await expect(
      applyAppBundleSwap({ appcastXml: appcast(goodSignature), bundlePath, ops: emptyArchive })
    ).rejects.toThrow(/no app bundle/)
    expect(calls.some((call) => call.startsWith("rename"))).toBe(false)
  })

  it("rolls the original bundle back when the final rename fails", async () => {
    const { calls, ops } = makeOps({ failSecondRename: true })
    await expect(
      applyAppBundleSwap({ appcastXml: appcast(goodSignature), bundlePath, ops })
    ).rejects.toThrow("rename blocked")
    expect(calls.filter((call) => call.startsWith("rename")).at(-1)).toBe(
      `rename ${bundlePath}.codevisor-old -> ${bundlePath}`
    )
  })

  it("rejects unsigned feeds outright", async () => {
    const { ops } = makeOps()
    const unsigned = `<rss><channel><item>
      <sparkle:shortVersionString>1.0</sparkle:shortVersionString>
      <enclosure url="https://example.com/x.zip" />
    </item></channel></rss>`
    await expect(applyAppBundleSwap({ appcastXml: unsigned, bundlePath, ops })).rejects.toThrow(
      /unsigned/
    )
  })
})
