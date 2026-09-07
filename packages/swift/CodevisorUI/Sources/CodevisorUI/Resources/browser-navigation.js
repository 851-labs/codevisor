;(() => {
  const post = (kind) =>
    window.webkit.messageHandlers.codevisorBrowserNavigation.postMessage({
      kind,
      url: location.href
    })
  for (const name of ["pushState", "replaceState"]) {
    const original = history[name]
    history[name] = function (...args) {
      const result = Reflect.apply(original, this, args)
      post("location")
      return result
    }
  }
  addEventListener("popstate", () => post("location"))
  addEventListener("hashchange", () => post("location"))
})()
