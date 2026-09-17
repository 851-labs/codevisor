import type { Context } from "hono"

import { hasAppleAuth } from "../apple-auth.js"
import { hasEmailAuth } from "../email-auth.js"
import { isDevAuthEnabled, type CloudEnv } from "../env.js"
import { loginURL, validAuthRedirect } from "./auth-navigation.js"
import { loginScript } from "./login-script.js"
import { page } from "./pages.js"

const providerIcon = (provider: "apple" | "github") => (
  <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class="provider-icon">
    {provider === "apple" ? (
      <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.75 3.08.81 1.18-.24 2.31-.94 3.57-.85 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01ZM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25Z" />
    ) : (
      <path d="M12 .75a11.25 11.25 0 0 0-3.56 21.92c.56.1.77-.24.77-.54v-2.1c-3.13.68-3.79-1.33-3.79-1.33-.51-1.3-1.25-1.65-1.25-1.65-1.02-.7.08-.68.08-.68 1.13.08 1.73 1.16 1.73 1.16 1 1.72 2.63 1.22 3.27.93.1-.73.39-1.22.71-1.5-2.5-.28-5.13-1.25-5.13-5.56 0-1.23.44-2.23 1.16-3.02-.12-.29-.5-1.43.11-2.98 0 0 .95-.3 3.1 1.15a10.8 10.8 0 0 1 5.63 0c2.15-1.45 3.1-1.15 3.1-1.15.61 1.55.23 2.69.11 2.98.72.79 1.16 1.8 1.16 3.02 0 4.32-2.63 5.28-5.14 5.56.4.35.76 1.03.76 2.08v3.09c0 .3.2.65.77.54A11.25 11.25 0 0 0 12 .75Z" />
    )}
  </svg>
)

export const loginPage = (c: Context<{ Bindings: CloudEnv }>) => {
  const redirect = c.req.query("redirect") ?? "/"
  if (!validAuthRedirect(redirect)) return c.json({ error: "invalid redirect" }, 400)
  c.header("Cache-Control", "no-store")
  const apple = hasAppleAuth(c.env)
  const github = Boolean(c.env.GITHUB_CLIENT_ID && c.env.GITHUB_CLIENT_SECRET)
  const email = hasEmailAuth(c.env)
  const dev = isDevAuthEnabled(c.env)
  const destination = new URL(redirect, c.env.PUBLIC_BASE_URL).pathname
  const subtitle =
    destination === "/device"
      ? "Sign in to connect this machine to your account."
      : "Your Codevisor account, connected."
  const href = (step: string) => loginURL(redirect, step)
  return page(
    c,
    "Sign in",
    <div
      id="auth"
      data-redirect={redirect}
      data-subtitle={subtitle}
      data-instance={c.env.INSTANCE_NAME}
    >
      <div class="auth-heading">
        <div id="auth-success" class="auth-success" hidden aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
            <path d="m6 12 4 4 8-8" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </div>
        <h1 id="auth-title" tabindex={-1}>
          Sign in to Codevisor
        </h1>
        <p id="auth-subtitle">{subtitle}</p>
        <p id="auth-address" class="auth-address" hidden></p>
      </div>
      {apple || github ? (
        <div id="auth-providers" class="auth-providers">
          {(["github", "apple"] as const)
            .filter((provider) => (provider === "apple" ? apple : github))
            .map((provider) => (
              <a
                id={provider}
                class="auth-provider"
                href={`/login/${provider}?redirect=${encodeURIComponent(redirect)}`}
              >
                {providerIcon(provider)}
                <span>Sign in with {provider === "apple" ? "Apple" : "GitHub"}</span>
              </a>
            ))}
        </div>
      ) : null}
      {email ? (
        <>
          {apple || github ? (
            <div id="auth-divider" class="auth-divider">
              <span>or continue with email</span>
            </div>
          ) : null}
          <form id="email-auth" method="post" action="/api/auth/sign-in/email">
            <fieldset id="auth-fields" class="auth-fields">
              <div id="email-field" class="auth-field">
                <label for="email">Email</label>
                <input
                  id="email"
                  name="email"
                  type="email"
                  autocomplete="username"
                  autocapitalize="none"
                  spellcheck={false}
                  maxlength={254}
                  placeholder="you@example.com"
                  required
                />
              </div>
              <div id="code-field" class="auth-field" hidden>
                <label for="code">Verification code</label>
                <input
                  id="code"
                  name="code"
                  class="auth-code"
                  type="text"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  pattern="[0-9]{6}"
                  maxlength={6}
                  placeholder="000000"
                  aria-describedby="code-hint"
                  disabled
                />
                <p id="code-hint" class="auth-hint">
                  Enter the 6-digit code. It expires in 10 minutes.
                </p>
              </div>
              <div id="password-field" class="auth-field">
                <div class="auth-label-row">
                  <label id="password-label" for="password">
                    Password
                  </label>
                  <a
                    id="forgot-password"
                    class="auth-link"
                    href={href("forgot-password")}
                    data-step="forgot-password"
                  >
                    Forgot password?
                  </a>
                </div>
                <div class="auth-password">
                  <input
                    id="password"
                    name="password"
                    type="password"
                    autocomplete="current-password"
                    required
                  />
                  <button
                    id="show-password"
                    type="button"
                    class="auth-reveal"
                    aria-label="Show password"
                    aria-controls="password"
                    aria-pressed="false"
                  >
                    Show
                  </button>
                </div>
                <p id="password-hint" class="auth-hint" hidden>
                  Use 8–128 characters.
                </p>
              </div>
              <p
                id="auth-error"
                class="auth-message auth-error"
                role="alert"
                tabindex={-1}
                hidden
              ></p>
              <p id="auth-notice" class="auth-message auth-notice" role="status" hidden></p>
              <button id="auth-submit" type="submit" class="auth-submit" disabled>
                <span class="auth-spinner" aria-hidden="true"></span>
                <span id="auth-submit-label">Sign in</span>
              </button>
              <div id="auth-code-actions" class="auth-code-actions" hidden>
                <span>Didn’t get a code?</span>
                <button id="resend-code" type="button" class="auth-link">
                  Resend code
                </button>
              </div>
              <p id="auth-signup" class="auth-switch">
                New to Codevisor?{" "}
                <a class="auth-link" href={href("sign-up")} data-step="sign-up">
                  Create an account
                </a>
              </p>
              <p id="auth-signin" class="auth-switch" hidden>
                Already have an account?{" "}
                <a class="auth-link" href={href("sign-in")} data-step="sign-in">
                  Sign in
                </a>
              </p>
              <p id="auth-back" class="auth-switch" hidden>
                <a id="auth-back-link" class="auth-link" href={href("sign-in")} data-step="sign-in">
                  Back to sign in
                </a>
              </p>
            </fieldset>
          </form>
          <noscript>
            <p class="auth-message auth-error">
              Enable JavaScript to sign in with email. You can also use an available sign-in
              provider above.
            </p>
          </noscript>
        </>
      ) : (
        <p id="auth-error" class="auth-message auth-error" role="alert" hidden></p>
      )}
      {!email && !apple && !github && !dev ? (
        <p class="auth-empty">No sign-in methods are configured on this instance.</p>
      ) : null}
      {dev ? (
        <a
          id="dev-login"
          class="auth-dev"
          href={`/dev-login?redirect=${encodeURIComponent(redirect)}`}
        >
          Continue as Dev User
        </a>
      ) : null}
    </div>,
    loginScript
  )
}
