import type { Context } from "hono"
import { createAuth } from "../auth.js"
import type { CloudEnv } from "../env.js"

type CloudContext = Context<{ Bindings: CloudEnv }>

export const nativeScheme = (value: string | undefined): string | undefined =>
  value && /^codevisor(?:-dev(?:-[a-f0-9]{10})?)?$/.test(value) ? value : undefined

const privateResponse = (c: CloudContext) => {
  c.header("Cache-Control", "no-store")
  c.header("Referrer-Policy", "no-referrer")
}

/** Native authentication returns directly to the app, including errors. */
export const nativeHandoff = async (c: CloudContext) => {
  privateResponse(c)
  const scheme = nativeScheme(c.req.query("app"))
  if (!scheme) return c.body(null, 400)
  if (c.req.query("error")) return c.redirect(`${scheme}://cloud-auth?error=sign_in_failed`)
  const auth = createAuth(c.env)
  const headers = c.req.raw.headers
  if (!(await auth.api.getSession({ headers }))) {
    return c.redirect(`${scheme}://cloud-auth?error=session_expired`)
  }
  const { token } = await auth.api.generateOneTimeToken({ headers })
  return c.redirect(`${scheme}://cloud-auth?ott=${encodeURIComponent(token)}`)
}

/** A headless bridge binds the browser to the native account before OAuth.
 * The one-time credential stays in the fragment, outside requests/referrers.
 * Provider selection and account management live entirely in the native app.
 */
export const connectAccount = (c: CloudContext) => {
  privateResponse(c)
  const scheme = nativeScheme(c.req.query("app"))
  const provider = c.req.param("provider")
  if (!scheme || (provider !== "github" && provider !== "apple")) return c.body(null, 400)
  const callbackURL = `/auth/handoff?app=${scheme}`
  return c.html(`<!doctype html><html><head><meta name="referrer" content="no-referrer"><title></title></head><body><script>
    const token = new URLSearchParams(location.hash.slice(1)).get("ott");
    history.replaceState(null, "", location.pathname + location.search);
    const request = async (path, body) => {
      const response = await fetch("/api/auth/" + path, {
        method: "POST", credentials: "include",
        headers: { "content-type": "application/json" }, body: JSON.stringify(body)
      });
      if (!response.ok) throw new Error("Authentication failed");
      return response.json();
    };
    (async () => {
      if (!token) throw new Error("Missing handoff");
      await request("one-time-token/verify", { token });
      const result = await request("link-social", {
        provider: ${JSON.stringify(provider)}, callbackURL: ${JSON.stringify(callbackURL)},
        errorCallbackURL: ${JSON.stringify(callbackURL + "&error=link_failed")}
      });
      if (!result.url) throw new Error("Missing provider");
      location.replace(result.url);
    })().catch(() => location.replace(${JSON.stringify(scheme + "://cloud-auth?error=link_failed")}));
  </script></body></html>`)
}
