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
  const page = `<!doctype html><title>Codevisor</title><p>${message}</p>`
  if (app === undefined) return page

  const link = `${app}://${signedInHost}`
  return `${page}<p><a href="${link}">Open Codevisor</a></p><script>location.href = "${link}"</script>`
}

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
