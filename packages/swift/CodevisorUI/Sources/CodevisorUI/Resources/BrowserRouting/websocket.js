;(() => {
  // WebKit applies blocking rules to WebSockets but ignores redirect actions.
  // Change only loopback destinations before calling the native constructor.
  // Unhandled contexts remain covered by the native loopback blocking rules.
  const NativeWebSocket = globalThis.WebSocket
  globalThis.WebSocket = new Proxy(NativeWebSocket, {
    construct(target, args, newTarget) {
      if (args.length) {
        const url = new URL(args[0], document.baseURI)
        if (!url.username && !url.password) {
          const host = url.hostname.toLowerCase()
          if (host === "localhost" || host === "localhost." || host === "0.0.0.0") {
            url.hostname = "proxy.localhost"
          } else if (/^127\.\d+\.\d+\.\d+$/.test(host)) {
            url.hostname = `ipv4-${host.replaceAll(".", "-")}.proxy.localhost`
          } else if (host === "[::1]") {
            url.hostname = "ipv6.proxy.localhost"
          }
          args[0] = url.href
        }
      }
      return Reflect.construct(target, args, newTarget)
    }
  })
})()
