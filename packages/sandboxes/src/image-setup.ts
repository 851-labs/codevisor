import {
  APP_LAUNCHER,
  DEFAULT_INSTALL_URL,
  environmentAssignments,
  shellQuote
} from "./bootstrap.js"

export interface ImageApp {
  readonly bundleName: string
  readonly development?: { readonly instanceId: string; readonly serverPort: number }
}

export interface ImageSetup {
  readonly app: ImageApp
  readonly installUrl?: string
  readonly installEnvironment?: Readonly<Record<string, string>>
}

const grantedServices = [
  "kTCCServiceScreenCapture",
  "kTCCServiceAccessibility",
  "kTCCServicePostEvent",
  "kTCCServiceListenEvent",
  "kTCCServiceSystemPolicyAllFiles"
]
const bridgeWaitSeconds = 120
const tccBusyTimeoutMs = 30_000
const tccWriteAttempts = 5
const scriptPrelude = ["set -eu", "step() { printf '==> %s\\n' \"$*\"; }"]

export const imageToolsScript = (agentCommands: ReadonlyArray<string>): string =>
  [
    ...scriptPrelude,
    ...agentCommands.flatMap(agentInstallLines),
    "sync",
    "step 'The agent CLIs are installed'",
    ""
  ].join("\n")

export const imageSetupScript = (setup: ImageSetup): string =>
  [
    ...scriptPrelude,
    `app=${shellQuote(`/Applications/${setup.app.bundleName}`)}`,
    ...appIdentityLines(),
    ...tccWriteLines(),
    ...serverInstallLines(setup),
    ...grantLines(),
    ...appLauncherLines(setup.app),
    ...startAppLines(),
    ...localNetworkLines(),
    ...screenCaptureApprovalLines(),
    "sync",
    "step 'The macOS image is ready'",
    ""
  ].join("\n")

const appIdentityLines = (): ReadonlyArray<string> => [
  '[ -d "$app" ] || { echo "error: $app was not copied into the VM" >&2; exit 1; }',
  'bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)'
]

const tccWriteLines = (): ReadonlyArray<string> => [
  "tcc_write() {",
  `  for attempt in $(seq 1 ${tccWriteAttempts}); do`,
  `    tcc_error=$("$1" sqlite3 -cmd ".timeout ${tccBusyTimeoutMs}" "$2" "$3" 2>&1) && return 0`,
  '    case "$tcc_error" in',
  "      *locked*) sleep 2 ;;",
  "      *) printf 'error: %s\\n' \"$tcc_error\" >&2; exit 1 ;;",
  "    esac",
  "  done",
  `  echo "error: $2 was still locked after ${tccWriteAttempts} tries of ${tccBusyTimeoutMs / 1000} s each, so macOS permissions were not granted" >&2`,
  "  exit 1",
  "}"
]

const serverInstallLines = (setup: ImageSetup): ReadonlyArray<string> => [
  "step 'Installing the Codevisor server'",
  'installer="$(mktemp)"',
  `curl -fsSL ${shellQuote(setup.installUrl ?? DEFAULT_INSTALL_URL)} -o "$installer"`,
  `CODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1 ${environmentAssignments(setup.installEnvironment)}sh "$installer"`
]

const agentInstallLines = (command: string): ReadonlyArray<string> => [
  `step ${shellQuote(`Installing ${command}`)}`,
  `/bin/zsh -lc ${shellQuote(command)} </dev/null || echo ${shellQuote(`warning: ${command} failed; the agent installs on first use instead`)}`
]

const grantLines = (): ReadonlyArray<string> => [
  'step "Allowing $bundle_id to record the screen and control the Mac"',
  'requirement=$(codesign -d -r- "$app" 2>&1 | sed -n "s/^designated => //p")',
  '[ -n "$requirement" ] || { echo "error: $app has no designated requirement" >&2; exit 1; }',
  'csreq_file="$(mktemp)"',
  'printf \'%s\' "$requirement" | csreq -r- -b "$csreq_file"',
  'csreq_hex=$(xxd -p "$csreq_file" | tr -d "\\n")',
  'tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"',
  `for service in ${grantedServices.join(" ")}; do`,
  "  tcc_write sudo \"$tcc_db\" \"insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) values ('$service', '$bundle_id', 0, 2, 4, 1, X'$csreq_hex', 0)\"",
  "done"
]

const appLauncherLines = (app: ImageApp): ReadonlyArray<string> => [
  "step 'Opening Codevisor whenever the VM starts'",
  `launcher=${shellQuote(APP_LAUNCHER)}`,
  'launcher="$HOME/${launcher#\\~/}"',
  'mkdir -p "$(dirname "$launcher")"',
  `printf '#!/bin/sh\\nexec /usr/bin/open %s -a %s\\n' "${developmentEnvironment(app)}" "'$app'" > "$launcher"`,
  'chmod +x "$launcher"'
]

const developmentEnvironment = (app: ImageApp): string => {
  if (app.development === undefined) return ""

  return [
    `--env CODEVISOR_DEV_INSTANCE_ID=${app.development.instanceId}`,
    `--env CODEVISOR_DEV_PORT=${app.development.serverPort}`,
    "--env CODEVISOR_DEV_DATA_DIR=$HOME/.codevisor/data"
  ].join(" ")
}

const startAppLines = (): ReadonlyArray<string> => [
  "step 'Starting Codevisor'",
  'defaults write "$bundle_id" CodevisorUsesStandaloneServer -bool true',
  '"$launcher"',
  `for attempt in $(seq 1 ${bridgeWaitSeconds}); do`,
  '  [ -s "$HOME/.codevisor/data/computer-use-token" ] && ls /tmp/codevisor-cu-"$(id -u)"-*.sock >/dev/null 2>&1 && break',
  `  [ "$attempt" = ${bridgeWaitSeconds} ] && { echo "error: Codevisor never opened its Computer Use bridge" >&2; exit 1; }`,
  "  sleep 1",
  "done"
]

const localNetworkLines = (): ReadonlyArray<string> => [
  "step 'Allowing Codevisor and the Tart guest agent on the local network'",
  'agent=$(readlink -f "$(command -v tart-guest-agent)")',
  "tcc_write env \"$HOME/Library/Application Support/com.apple.TCC/TCC.db\" \"insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags) values ('kTCCServiceAppleEvents', '$agent', 1, 2, 4, 1, 0, 'com.apple.systemevents', 0)\"",
  "killall tccd 2>/dev/null || true",
  'bridge_socket=$(ls /tmp/codevisor-cu-"$(id -u)"-*.sock | head -1)',
  `( for attempt in 1 2 3; do node -e ${shellQuote(primeClient)} "$bridge_socket" "$HOME/.codevisor/data/computer-use-token"; node -e ${shellQuote(multicastProbe)}; sleep 10; done ) &`,
  `osascript -e ${shellQuote(answerLocalNetworkPrompts)} "$(basename "$app" .app)"`,
  "wait"
]

const primeClient = [
  'const socket = require("net").createConnection(process.argv[1])',
  'const token = require("fs").readFileSync(process.argv[2], "utf8").trim()',
  'socket.on("data", (data) => { if (String(data).includes("\\"id\\":\\"2\\"")) socket.end() })',
  'socket.write(JSON.stringify({ id: "1", type: "authenticate", token }) + "\\n")',
  'socket.write(JSON.stringify({ id: "2", type: "primeLocalNetwork" }) + "\\n")'
].join("; ")

const multicastProbe = [
  'const socket = require("dgram").createSocket("udp4")',
  'socket.bind(() => socket.send(Buffer.alloc(12), 5353, "224.0.0.251", () => socket.close()))'
].join("; ")

const answerLocalNetworkPrompts = [
  "on run {appName}",
  "  set answered to {}",
  "  repeat 90 times",
  "    try",
  '      tell application "System Events" to tell process "UserNotificationCenter"',
  "        repeat with alertWindow in (every window)",
  "          set alertText to (value of every static text of alertWindow) as text",
  '          if alertText contains "local network" then',
  '            click button "Allow" of alertWindow',
  "            set end of answered to alertText",
  "          end if",
  "        end repeat",
  "      end tell",
  "    end try",
  "    set answeredText to answered as text",
  '    if answeredText contains appName and answeredText contains "tart-guest" then exit repeat',
  "    delay 1",
  "  end repeat",
  "  set AppleScript's text item delimiters to linefeed",
  "  return answered as text",
  "end run"
].join("\n")

const screenCaptureApprovalLines = (): ReadonlyArray<string> => [
  "step 'Approving screen capture without the system picker'",
  'approvals="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"',
  "killall -9 replayd 2>/dev/null || true",
  'mkdir -p "$(dirname "$approvals")"',
  'cat > "$approvals" <<PLIST',
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
  '<plist version="1.0"><dict><key>$bundle_id</key><dict>',
  "<key>kScreenCaptureAlertableUsageCount</key><integer>1</integer>",
  "<key>kScreenCaptureApprovalLastAlerted</key><date>2100-01-01T00:00:00Z</date>",
  "<key>kScreenCaptureApprovalLastUsed</key><date>2100-01-01T00:00:00Z</date>",
  "<key>kScreenCapturePrivacyHintDate</key><date>2100-01-01T00:00:00Z</date>",
  "<key>kScreenCapturePrivacyHintPolicy</key><integer>2592000</integer>",
  "</dict></dict></plist>",
  "PLIST",
  'plutil -lint "$approvals" >/dev/null'
]
