import handler from "@tanstack/react-start/server-entry"

// Keep the former domains attached long enough for bookmarks and installers
// to follow a permanent redirect to the Codevisor canonical host.
export default {
  fetch(request: Request): Response | Promise<Response> {
    const url = new URL(request.url)
    if (
      url.pathname === "/.well-known/apple-app-site-association" &&
      ["codevisor.dev", "www.codevisor.dev", "localhost", "127.0.0.1"].includes(url.hostname)
    ) {
      return Response.json(
        {
          applinks: {
            details: [
              {
                appIDs: ["C4M7D4G7LG.com.dylanplayer.codevisor.ios"],
                components: [{ "/": "/plugins/*" }]
              }
            ]
          }
        },
        { headers: { "cache-control": "public, max-age=3600" } }
      )
    }
    if (url.hostname === "herdman.dev" || url.hostname === "www.herdman.dev") {
      url.protocol = "https:"
      url.hostname = "www.codevisor.dev"
      return Response.redirect(url.toString(), 301)
    }
    if (url.hostname === "codevisor.dev") {
      url.hostname = "www.codevisor.dev"
      return Response.redirect(url.toString(), 301)
    }
    return handler.fetch(request)
  }
}
