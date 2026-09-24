import assert from "node:assert/strict"
import test from "node:test"

import {
  bootstrapPlan,
  parseTuningArgument,
  withTuning,
  buildInfoExtras,
  deployPlan,
  launchAgentPlist,
  parseRigArguments,
  quote,
  rigConfiguration,
  rigLaunchAgentLabel,
  stopPlan,
  stringOption
} from "./screen-sharing-rig-lib.ts"

test("launch agent runs the installed rig with its config and restarts only abnormal exits", () => {
  const plist = launchAgentPlist({
    home: "/Users/x",
    configPath: "/Users/x/Applications/CodevisorRig/rig.json",
    logPath: "/Users/x/Library/Logs/CodevisorRig/rig.log"
  })
  assert.match(plist, new RegExp(`<key>Label</key><string>${rigLaunchAgentLabel}</string>`))
  assert.match(
    plist,
    /<string>\/Users\/x\/Applications\/CodevisorRig\/ScreenSharingRig\.app\/Contents\/MacOS\/screen-sharing-rig<\/string>\n<string>--config<\/string>\n<string>\/Users\/x\/Applications\/CodevisorRig\/rig\.json<\/string>/
  )
  assert.match(plist, /<key>KeepAlive<\/key><dict><key>SuccessfulExit<\/key><false\/><\/dict>/)
  const host = launchAgentPlist({
    home: "/Users/x",
    configPath: "/Users/x/Applications/CodevisorRig/rig.json",
    logPath: "/Users/x/Library/Logs/CodevisorRig/rig.log",
    role: "host"
  })
  assert.match(
    host,
    /<key>KeepAlive<\/key><true\/>/,
    "a host restarts after any exit, including Quit & Reopen"
  )
  assert.doesNotMatch(host, /SuccessfulExit/)
  assert.match(plist, /<key>LimitLoadToSessionType<\/key><string>Aqua<\/string>/)
  assert.match(
    plist,
    /<key>StandardOutPath<\/key><string>\/Users\/x\/Library\/Logs\/CodevisorRig\/rig\.log<\/string>/
  )
  assert.equal(
    plist,
    launchAgentPlist({
      home: "/Users/x",
      configPath: "/Users/x/Applications/CodevisorRig/rig.json",
      logPath: "/Users/x/Library/Logs/CodevisorRig/rig.log"
    })
  )
})

test("rig configuration validates roles, tokens, peers and capture", () => {
  const token = "0123456789abcdef0123"
  assert.deepEqual(rigConfiguration({ role: "host", token, capture: "workload:1920x1080@60" }), {
    role: "host",
    token,
    port: 48731,
    controlPort: 48732,
    hud: true,
    capture: "workload:1920x1080@60"
  })
  assert.deepEqual(
    rigConfiguration({ role: "viewer", token, peer: "192.168.10.191", hud: false, fps: 30 }),
    {
      role: "viewer",
      token,
      port: 48731,
      controlPort: 48732,
      hud: false,
      peer: "192.168.10.191",
      fps: 30
    }
  )
  assert.throws(() => rigConfiguration({ role: "viewer", token }), /host address/)
  // @ts-expect-error -- rig.json and CLI input are untyped at runtime; the role check still guards it.
  assert.throws(() => rigConfiguration({ role: "admin", token }), /role/)
  assert.throws(() => rigConfiguration({ role: "host", token: "short" }), /token/)
  assert.throws(() => rigConfiguration({ role: "host", token, capture: "tab:3" }), /capture/)
  assert.equal(
    rigConfiguration({ role: "host", token, capture: "virtual:1920x1080@60" }).capture,
    "virtual:1920x1080@60"
  )
})

test("deploy plan stages, swaps atomically, verifies and kickstarts, locally or over ssh", () => {
  const local = deployPlan({
    builtApp: "/repo/tmp/ScreenSharingRig.app",
    home: "/Users/x",
    uid: 501
  })
  assert.deepEqual(local.slice(0, 3), [
    ["mkdir", "-p", "/Users/x/Applications/CodevisorRig"],
    ["rm", "-rf", "/Users/x/Applications/CodevisorRig/.staging-ScreenSharingRig.app"],
    [
      "cp",
      "-R",
      "/repo/tmp/ScreenSharingRig.app",
      "/Users/x/Applications/CodevisorRig/.staging-ScreenSharingRig.app"
    ]
  ])
  const swap = local[3]!
  assert.equal(swap[0], "sh")
  assert.match(
    swap[2]!,
    /mv '\/Users\/x\/Applications\/CodevisorRig\/\.staging-ScreenSharingRig\.app' '\/Users\/x\/Applications\/CodevisorRig\/ScreenSharingRig\.app'/
  )
  assert.match(swap[2]!, /codesign --verify --deep --strict/)
  assert.match(swap[2]!, new RegExp(`launchctl kickstart -k gui/501/${rigLaunchAgentLabel}`))
  const remote = deployPlan({
    builtApp: "/repo/tmp/ScreenSharingRig.app",
    home: "/Users/tuftlord",
    uid: 501,
    remote: "tuftlord@tuftlords-macbook-pro"
  })
  assert.equal(remote[0]![0], "ssh")
  assert.deepEqual(remote[1], [
    "rsync",
    "-a",
    "--delete",
    "/repo/tmp/ScreenSharingRig.app/",
    "tuftlord@tuftlords-macbook-pro:/Users/tuftlord/Applications/CodevisorRig/.staging-ScreenSharingRig.app/"
  ])
  assert.equal(remote[2]![0], "ssh")
  assert.match(remote[2]![2]!, /launchctl kickstart -k gui\/501/)
  assert.doesNotMatch(
    remote.flat().join(" "),
    /open |launchctl asuser/,
    "never launch GUI over ssh directly"
  )
})

test("bootstrap and stop plans use the gui domain", () => {
  const [shell, flag, script = ""] = bootstrapPlan({ uid: 501, plistPath: "/p/x.plist" })[0]!
  assert.equal(`${shell} ${flag}`, "sh -c")
  assert.match(
    script,
    /^launchctl bootout gui\/501\/com\.codevisor\.screen-sharing-rig[^;]*\|\| true; /
  )
  assert.match(
    script,
    /launchctl print gui\/501\/com\.codevisor\.screen-sharing-rig >\/dev\/null 2>&1 \|\| break; sleep 0\.5/,
    "waits for the old instance to unload"
  )
  assert.match(
    script,
    /launchctl bootstrap gui\/501 '\/p\/x\.plist' && launchctl kickstart -k gui\/501\/com\.codevisor\.screen-sharing-rig$/
  )
  assert.ok(script.indexOf("bootout") < script.indexOf("launchctl print"))
  assert.ok(script.indexOf("launchctl print") < script.indexOf("bootstrap gui"))
  assert.equal(bootstrapPlan({ uid: 501, plistPath: "/p/x.plist", remote: "u@h" })[0]![0], "ssh")
  assert.match(stopPlan({ uid: 501 })[0]![2]!, /bootout gui\/501/)
})

test("argument parser defaults to build and rejects unknown commands", () => {
  assert.deepEqual(parseRigArguments([]), { command: "build", options: {}, positional: [] })
  assert.deepEqual(parseRigArguments(["--debug", "--build-only"]), {
    command: "build",
    options: { debug: true, "build-only": true },
    positional: []
  })
  assert.deepEqual(
    parseRigArguments([
      "install",
      "--host",
      "u@h",
      "--host-address",
      "10.0.0.2",
      "--capture",
      "synthetic"
    ]),
    {
      command: "install",
      options: { host: "u@h", "host-address": "10.0.0.2", capture: "synthetic" },
      positional: []
    }
  )
  assert.deepEqual(parseRigArguments(["hud", "off"]), {
    command: "hud",
    options: {},
    positional: ["off"]
  })
  assert.throws(() => parseRigArguments(["frobnicate"]), /Unknown command/)
})

test("value options reject a bare flag instead of passing true along", () => {
  const { options } = parseRigArguments(["install", "--host", "u@h", "--token", "--debug"])
  assert.equal(stringOption(options, "host"), "u@h")
  assert.equal(stringOption(options, "capture"), undefined)
  assert.throws(() => stringOption(options, "token"), /--token needs a value/)
})

test("shell quoting and build extras", () => {
  assert.equal(quote("it's"), `'it'\\''s'`)
  assert.deepEqual(buildInfoExtras({ commit: "abc", dirty: true, builtAt: "t" }), {
    CodevisorRigCommit: "abc",
    CodevisorRigDirty: "true",
    CodevisorRigBuiltAt: "t"
  })
})

test("tune accepts a JSON object, the product profile, or default", () => {
  assert.deepEqual(
    withTuning(
      { role: "host", codec: "h264", tuning: { drawables: 2 } },
      { codec: "hevc444", keyframeIntervalSeconds: 60 }
    ),
    { role: "host", codec: "hevc444", tuning: { keyframeIntervalSeconds: 60 } },
    "codec and bitrate move to the top level; the rest replaces tuning"
  )
  assert.deepEqual(
    withTuning(
      { role: "host", codec: "hevc444", tuning: { drawables: 2 } },
      { bitrate: 24_000_000 }
    ),
    { role: "host", codec: "hevc444", bitrate: 24_000_000 },
    "an object with only top-level keys clears tuning"
  )
  assert.deepEqual(parseTuningArgument('{"playoutDelayMs":[1,15]}'), { playoutDelayMs: [1, 15] })
  assert.deepEqual(parseTuningArgument("paced15-worker"), { profile: "paced15-worker" })
  assert.equal(parseTuningArgument("default"), null)
  assert.throws(() => parseTuningArgument(undefined), /tune needs/)
  assert.throws(() => parseTuningArgument("[1,2]"), /expected an object/)
  assert.throws(() => parseTuningArgument("not json"), /not JSON/)
  const base = { role: "host", token: "t", tuning: { profile: "paced15-worker" } }
  assert.deepEqual(withTuning(base, null), { role: "host", token: "t" })
  assert.deepEqual(withTuning({ role: "host", token: "t" }, { drawables: 2 }), {
    role: "host",
    token: "t",
    tuning: { drawables: 2 }
  })
  assert.deepEqual(base.tuning, { profile: "paced15-worker" }, "input is not mutated")
})
