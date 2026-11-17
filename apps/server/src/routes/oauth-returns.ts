export interface OAuthReturns {
  readonly remember: (authorizationUrl: string, app: string | undefined) => void
  readonly take: (state: string) => string | undefined
}

export const appSchemeParameter = "app"

export const makeOAuthReturns = (): OAuthReturns => {
  const apps = new Map<string, string>()
  return {
    remember: (authorizationUrl, app) => {
      const state = oauthState(authorizationUrl)
      const scheme = appScheme(app)
      if (state === undefined || scheme === undefined) return

      apps.set(state, scheme)
      forgetOldest(apps)
    },
    take: (state) => {
      const app = apps.get(state)
      apps.delete(state)
      return app
    }
  }
}

export const appScheme = (value: string | null | undefined): string | undefined =>
  value && appSchemePattern.test(value) ? value : undefined

export const oauthFinishedPage = (message: string, app: string | undefined): string => {
  if (app === undefined) return signInPage({ title: "Codevisor", message })

  const link = `${app}://${signedInHost}`
  return signInPage({
    title: "Codevisor",
    message,
    link: { title: "Open Codevisor", url: link },
    opens: link
  })
}

export interface SignInPage {
  readonly title: string
  readonly message: string
  readonly link?: { readonly title: string; readonly url: string }
  readonly opens?: string
  readonly continuesAt?: string
}

export const signInPage = (page: SignInPage): string =>
  [
    "<!doctype html>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<meta name="color-scheme" content="light dark">',
    page.continuesAt === undefined
      ? ""
      : `<meta http-equiv="refresh" content="0;url=${escapeHtml(page.continuesAt)}">`,
    `<title>${escapeHtml(page.title)}</title>`,
    `<style>${pageStyle}</style>`,
    `<main><p>${escapeHtml(page.message)}</p>`,
    page.link === undefined
      ? ""
      : `<p><a href="${escapeHtml(page.link.url)}">${escapeHtml(page.link.title)}</a></p>`,
    "</main>",
    page.opens === undefined ? "" : `<script>location.href = ${scriptString(page.opens)}</script>`
  ].join("")

const scriptString = (value: string): string => JSON.stringify(value).replaceAll("<", "\\u003c")

const escapeHtml = (value: string): string =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")

const pageStyle =
  "body{margin:0;font:15px/1.5 -apple-system,system-ui,sans-serif}" +
  "main{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:0 24px;box-sizing:border-box}" +
  "p{margin:4px 0;max-width:420px}a{color:inherit}"

const appSchemePattern = /^codevisor(?:-dev(?:-[a-f0-9]{10})?)?$/

const signedInHost = "signed-in"

const maxRemembered = 64

const oauthState = (authorizationUrl: string): string | undefined => {
  if (!URL.canParse(authorizationUrl)) return undefined
  return new URL(authorizationUrl).searchParams.get("state") ?? undefined
}

const forgetOldest = (apps: Map<string, string>): void => {
  for (const state of apps.keys()) {
    if (apps.size <= maxRemembered) return
    apps.delete(state)
  }
}
