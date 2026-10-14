import * as Host from "./core/host/host.js"
import * as UI from "./ui/legacy/legacy.js"
import * as SDK from "./core/sdk/sdk.js"
import * as Common from "./core/common/common.js"
import * as Root from "./core/root/root.js"

const native = globalThis.__codevisorDevTools
if (!native) throw new Error("Codevisor DevTools bridge is unavailable")
const host = Host.InspectorFrontendHost.InspectorFrontendHostInstance
const getPreferences = host.getPreferences.bind(host)
host.getPreferences = (callback) => getPreferences((preferences) => callback({
  ...preferences,
  currentDockState: JSON.stringify(native.initialDockSide)
}))
let dockRequest = 0
const dockCallbacks = new Map()
native.didDock = (request) => {
  const callback = dockCallbacks.get(request)
  dockCallbacks.delete(request)
  callback?.()
}
host.setIsDocked = (_isDocked, callback) => {
  const request = ++dockRequest
  dockCallbacks.set(request, callback)
  native.dock(JSON.stringify({side: UI.DockController.DockController.instance().dockSide(), request}))
}
native.inspect = (backendNodeId) => {
  const target = SDK.TargetManager.TargetManager.instance().primaryPageTarget()
  if (target) void Common.Revealer.reveal(new SDK.DOMModel.DeferredDOMNode(target, backendNodeId))
}
host.isHostedMode = () => false
host.sendMessageToBackend = (message) => native.send(message)
host.closeWindow = () => native.close("")
host.copyText = (text) => native.copy(text)
host.openInNewTab = (url) => native.open(url)
host.bringToFront = () => native.focus("")
host.readyForTest = () => native.ready("")

Root.Runtime.conditions.canDock = () => false

await import("./entrypoints/devtools_app/devtools_app.js")
