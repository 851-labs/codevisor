// The native browser waits for this acknowledgement before loading a website.
// updateEnabledRulesets resolves only after WebKit installs the compiled rules.
browser.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: ["loopback"] }).then(
  () => browser.runtime.sendNativeMessage("codevisor.browser-routing", { ready: true }),
  (error) =>
    browser.runtime.sendNativeMessage("codevisor.browser-routing", { error: String(error) })
)
