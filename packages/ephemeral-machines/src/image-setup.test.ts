import { describe, expect, it } from "vitest"

import { imageSetupScript } from "./image-setup.js"

const release = imageSetupScript({
  app: { bundleName: "Codevisor.app" },
  agentCommands: ["npm install -g @openai/codex", "curl -fsSL https://example.test/install | bash"]
})

const development = imageSetupScript({
  app: {
    bundleName: "Codevisor (dev).app",
    development: { instanceId: "dev-ephemeral", serverPort: 49361 }
  },
  installUrl: "http://192.168.1.2:4000/install.sh",
  installEnvironment: { CODEVISOR_VERSION: "dev" },
  agentCommands: []
})

describe("macOS image setup script", () => {
  it("installs the app, the standalone server and each agent CLI", () => {
    expect(release).toContain("app='/Applications/Codevisor.app'")
    expect(release).toContain(
      '[ -d "$app" ] || { echo "error: $app was not copied into the VM" >&2; exit 1; }'
    )
    expect(release).toContain(
      'curl -fsSL \'https://www.codevisor.dev/install.sh\' -o "$installer"\nCODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1 sh "$installer"'
    )
    expect(release).toContain(
      "/bin/zsh -lc 'curl -fsSL https://example.test/install | bash' </dev/null || echo 'warning: curl -fsSL https://example.test/install | bash failed; the agent installs on first use instead'"
    )
    expect(development).toContain(
      "CODEVISOR_INSTALL_SERVER=1 CODEVISOR_VERSION='dev' sh \"$installer\""
    )
  })

  it("grants screen recording and input control to the app's signing identity, not a path", () => {
    expect(release).toContain('codesign -d -r- "$app"')
    expect(release).toContain("csreq -r- -b")
    for (const service of ["ScreenCapture", "Accessibility", "PostEvent", "ListenEvent"]) {
      expect(release).toContain(`kTCCService${service}`)
    }
    expect(release).toContain("values ('$service', '$bundle_id', 0, 2, 4, 1, X'$csreq_hex', 0)")
  })

  it("opens the app whenever the VM starts and approves screen capture so macOS never asks", () => {
    expect(release).toContain(
      `printf '#!/bin/sh\\nexec /usr/bin/open %s -a %s\\n' "" "'$app'" > "$launcher"`
    )
    expect(release).toContain(
      'defaults write "$bundle_id" CodevisorUsesStandaloneServer -bool true'
    )
    expect(release).toContain("killall -9 replayd")
    expect(release).toContain(
      "<key>kScreenCapturePrivacyHintDate</key><date>2100-01-01T00:00:00Z</date>"
    )
    expect(release.trimEnd().endsWith("step 'The macOS image is ready'")).toBe(true)
  })

  it("answers the local network prompts once so every VM made from the image inherits them", () => {
    expect(release).toContain(
      "'kTCCServiceAppleEvents', '$agent', 1, 2, 4, 1, 0, 'com.apple.systemevents', 0"
    )
    expect(release).toContain('type: "primeLocalNetwork"')
    expect(release).toContain('socket.send(Buffer.alloc(12), 5353, "224.0.0.251"')
    expect(release).toContain('click button "Allow" of alertWindow')
    expect(release).toContain(`"$(basename "$app" .app)"`)
  })

  it("launches a development build against the VM's own server and data", () => {
    expect(development).toContain(
      '"--env CODEVISOR_DEV_INSTANCE_ID=dev-ephemeral --env CODEVISOR_DEV_PORT=49361 --env CODEVISOR_DEV_DATA_DIR=$HOME/.codevisor/data"'
    )
  })
})
