import type { IncomingMessage } from "node:http"

export const routeTag = (request: Pick<IncomingMessage, "method" | "url"> | undefined): string => {
  const pathname = URL.parse(request?.url ?? "/", "http://localhost")?.pathname ?? "/"
  const segments = pathname.split("/").filter(Boolean).slice(0, maxSegments).map(routeSegment)
  return `${request?.method ?? "?"} /${segments.join("/")}`
}

const maxSegments = 5

const routeSegment = (segment: string): string =>
  /^[a-z][a-z\d-]*$/.test(segment) ? segment : ":id"
