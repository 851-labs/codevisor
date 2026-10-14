browser.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: ["loopback"] }).then(
  () => browser.runtime.sendNativeMessage("codevisor.browser-routing", { ready: true }),
  (error) =>
    browser.runtime.sendNativeMessage("codevisor.browser-routing", { error: String(error) })
)
