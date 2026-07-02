import handler from "@tanstack/react-start/server-entry"

// herdman.dev is attached to this worker as a second custom domain; the apex
// permanently redirects to www.herdman.dev.
export default {
  fetch(request: Request): Response | Promise<Response> {
    const url = new URL(request.url)
    if (url.hostname === "herdman.dev") {
      url.hostname = "www.herdman.dev"
      return Response.redirect(url.toString(), 301)
    }
    return handler.fetch(request)
  }
}
