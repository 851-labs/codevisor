import { Schema } from "effect"

export interface AppCsp {
  readonly connectDomains: ReadonlyArray<string>
  readonly resourceDomains: ReadonlyArray<string>
  readonly frameDomains: ReadonlyArray<string>
  readonly baseUriDomains: ReadonlyArray<string>
}

export interface AppPermissions {
  readonly clipboardWrite?: Readonly<Record<string, never>>
}

export interface AppSandbox {
  readonly csp: AppCsp
  readonly permissions: AppPermissions
}

export const appSandbox = (resourceMeta: unknown): AppSandbox => {
  const ui = decodedUi(resourceMeta)
  return {
    csp: {
      connectDomains: allowedOrigins(ui?.csp?.connectDomains),
      resourceDomains: allowedOrigins(ui?.csp?.resourceDomains),
      frameDomains: allowedOrigins(ui?.csp?.frameDomains),
      baseUriDomains: allowedOrigins(ui?.csp?.baseUriDomains)
    },
    permissions: ui?.permissions?.clipboardWrite === undefined ? {} : { clipboardWrite: {} }
  }
}

export const appPolicy = (csp: AppCsp): string => policy(csp, csp.connectDomains, csp.frameDomains)

export const shellPolicy = (csp: AppCsp): string =>
  policy(csp, ["'self'", ...csp.connectDomains], [...loopbackFrames, ...csp.frameDomains])

const loopbackFrames = ["http://127.0.0.1:*", "http://localhost:*"]

export const frameAllow = (permissions: AppPermissions): string =>
  permissions.clipboardWrite === undefined ? "" : "clipboard-write"

const originPattern = /^(https|wss):\/\/(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)*(:\d{1,5})?$/i

const Domains = Schema.optional(Schema.Array(Schema.String))

const UiMeta = Schema.Struct({
  ui: Schema.optional(
    Schema.Struct({
      csp: Schema.optional(
        Schema.Struct({
          connectDomains: Domains,
          resourceDomains: Domains,
          frameDomains: Domains,
          baseUriDomains: Domains
        })
      ),
      permissions: Schema.optional(
        Schema.Struct({ clipboardWrite: Schema.optional(Schema.Unknown) })
      )
    })
  )
})

const decodedUi = (resourceMeta: unknown) => {
  try {
    return Schema.decodeUnknownSync(UiMeta)(resourceMeta ?? {}).ui
  } catch {
    return undefined
  }
}

const allowedOrigins = (domains: ReadonlyArray<string> | undefined): ReadonlyArray<string> =>
  (domains ?? []).filter((domain) => originPattern.test(domain))

const sources = (values: ReadonlyArray<string>): string =>
  values.length === 0 ? "'none'" : values.join(" ")

const policy = (
  csp: AppCsp,
  connect: ReadonlyArray<string>,
  frames: ReadonlyArray<string>
): string => {
  const withResources = (directive: string): string => [directive, ...csp.resourceDomains].join(" ")
  return [
    "default-src 'none'",
    withResources("script-src 'unsafe-inline'"),
    withResources("style-src 'unsafe-inline'"),
    withResources("img-src data: blob:"),
    withResources("font-src data:"),
    withResources("media-src data: blob:"),
    `connect-src ${sources(connect)}`,
    `frame-src ${sources(frames)}`,
    `base-uri ${sources(csp.baseUriDomains)}`,
    "object-src 'none'",
    "form-action 'none'"
  ].join("; ")
}
