import assert from "node:assert/strict"
import test from "node:test"

import {
  designatedRequirement,
  diagnosticInfoPlist,
  parseCodesigningIdentities,
  resolveSigningIdentity,
  rigIdentity,
  signDiagnosticApp,
  signingIdentityVariable
} from "./screen-sharing-bundle.ts"

const findIdentityOutput = `Policy: Code Signing
  Matching identities
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example Person (TEAM123456)"
  2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Apple Development: Example Person (CERT000001)"
  3) FEDCBA9876543210FEDCBA9876543210FEDCBA98 "Apple Development: Example Person (CERT000002)" (CSSMERR_TP_CERT_REVOKED)
     3 valid identities found
`

test("parses identities and marks revoked entries invalid", () => {
  assert.deepEqual(parseCodesigningIdentities(findIdentityOutput), [
    {
      hash: "0123456789ABCDEF0123456789ABCDEF01234567",
      name: "Developer ID Application: Example Person (TEAM123456)",
      valid: true
    },
    {
      hash: "89ABCDEF0123456789ABCDEF0123456789ABCDEF",
      name: "Apple Development: Example Person (CERT000001)",
      valid: true
    },
    {
      hash: "FEDCBA9876543210FEDCBA9876543210FEDCBA98",
      name: "Apple Development: Example Person (CERT000002)",
      valid: false
    }
  ])
  assert.deepEqual(parseCodesigningIdentities("     0 valid identities found\n"), [])
})

test("prefers the first valid Apple Development identity over Developer ID", () => {
  const identities = parseCodesigningIdentities(findIdentityOutput)
  assert.deepEqual(resolveSigningIdentity({ identities }), {
    identity: "Apple Development: Example Person (CERT000001)",
    adHoc: false,
    source: "keychain"
  })
})

test("falls back to ad hoc with a warning when no development identity exists", () => {
  const onlyDeveloperID = parseCodesigningIdentities(findIdentityOutput).filter((entry) =>
    entry.name.startsWith("Developer ID")
  )
  const resolved = resolveSigningIdentity({ identities: onlyDeveloperID })
  assert.equal(resolved.identity, "-")
  assert.equal(resolved.adHoc, true)
  assert.match(
    resolved.warning!,
    /^WARNING: signing ad hoc \(no Apple Development identity found\)/
  )
  assert.match(resolved.warning!, new RegExp(signingIdentityVariable))
})

test("environment override wins, may be a hash, and rejects revoked identities", () => {
  const identities = parseCodesigningIdentities(findIdentityOutput)
  assert.deepEqual(
    resolveSigningIdentity({
      env: { [signingIdentityVariable]: "Developer ID Application: Example Person (TEAM123456)" },
      identities
    }),
    {
      identity: "Developer ID Application: Example Person (TEAM123456)",
      adHoc: false,
      source: "environment"
    }
  )
  assert.equal(
    resolveSigningIdentity({
      env: { [signingIdentityVariable]: "0123456789ABCDEF0123456789ABCDEF01234567" },
      identities
    }).identity,
    "0123456789ABCDEF0123456789ABCDEF01234567"
  )
  assert.throws(
    () =>
      resolveSigningIdentity({
        env: { [signingIdentityVariable]: "Apple Development: Example Person (CERT000002)" },
        identities
      }),
    /not valid/
  )
  const explicitAdHoc = resolveSigningIdentity({
    env: { [signingIdentityVariable]: "-" },
    identities
  })
  assert.equal(explicitAdHoc.adHoc, true)
  assert.match(explicitAdHoc.warning!, /requested through the environment/)
})

test("rig plist carries the fixed identity and is byte-stable across calls", () => {
  const options = {
    ...rigIdentity,
    bundleIdentifier: rigIdentity.bundleIdentifier,
    configuration: "release"
  }
  const first = diagnosticInfoPlist(options)
  assert.equal(first, diagnosticInfoPlist({ ...options }))
  assert.match(
    first,
    /<key>CFBundleIdentifier<\/key><string>com\.codevisor\.ScreenSharingRig<\/string>/
  )
  assert.match(first, /<key>CFBundleExecutable<\/key><string>screen-sharing-rig<\/string>/)
  assert.match(first, /<key>NSHighResolutionCapable<\/key><true\/>/)
  assert.match(first, /<key>NSScreenCaptureUsageDescription<\/key>/)
  assert.match(
    first,
    /<key>NSAppTransportSecurity<\/key><dict>\n<key>NSAllowsArbitraryLoads<\/key><true\/>\n<\/dict>/,
    "signaling over a Tailscale address is plain HTTP outside ATS's private-range exemption"
  )
  assert.doesNotMatch(first, /w[0-9a-f]{12}/, "the rig identifier must not embed a worktree hash")
})

test("plist escapes XML in values and keeps keys sorted", () => {
  const plist = diagnosticInfoPlist({
    bundleIdentifier: "x",
    displayName: 'A & "B" <C>',
    executableName: "e",
    configuration: "debug",
    extra: { AAAFirst: "1" }
  })
  assert.match(plist, /<string>A &amp; &quot;B&quot; &lt;C&gt;<\/string>/)
  assert.ok(plist.indexOf("<key>AAAFirst</key>") < plist.indexOf("<key>CFBundleDisplayName</key>"))
})

test("signs frameworks before the app with one identity and no timestamp", async () => {
  const calls: string[][] = []
  const commands = await signDiagnosticApp({
    app: "/tmp/Rig.app",
    frameworks: ["/tmp/Rig.app/Contents/Frameworks/WebRTC.framework"],
    identity: "Apple Development: Example Person (CERT000001)",
    run: async (command, args) => calls.push([command, ...args])
  })
  const expected = [
    [
      "/usr/bin/codesign",
      "--force",
      "--sign",
      "Apple Development: Example Person (CERT000001)",
      "--timestamp=none",
      "/tmp/Rig.app/Contents/Frameworks/WebRTC.framework"
    ],
    [
      "/usr/bin/codesign",
      "--force",
      "--sign",
      "Apple Development: Example Person (CERT000001)",
      "--timestamp=none",
      "/tmp/Rig.app"
    ]
  ]
  assert.deepEqual(calls, expected)
  assert.deepEqual(commands, expected)
  await assert.rejects(
    signDiagnosticApp({ app: "/tmp/Rig.app", frameworks: [], identity: "", run: async () => {} }),
    /signing identity is required/
  )
})

test("reads the designated requirement back from codesign", async () => {
  const requirement = await designatedRequirement({
    app: "/tmp/Rig.app",
    capture: async () =>
      `Executable=/tmp/Rig.app/Contents/MacOS/screen-sharing-rig\ndesignated => identifier "com.codevisor.ScreenSharingRig" and anchor apple generic\n`
  })
  assert.equal(requirement, 'identifier "com.codevisor.ScreenSharingRig" and anchor apple generic')
  assert.equal(
    await designatedRequirement({
      app: "/tmp/Rig.app",
      capture: async () => `# designated => cdhash H"4590715ae08947abc6ed6f7e8ac64a3f98f3f35d"\n`
    }),
    'cdhash H"4590715ae08947abc6ed6f7e8ac64a3f98f3f35d"',
    "ad-hoc signatures report their implicit requirement commented out"
  )
  await assert.rejects(
    designatedRequirement({ app: "/tmp/Rig.app", capture: async () => "Executable=/x\n" }),
    /did not report a designated requirement/
  )
})
