import type { Context } from "hono"
import { hasAppleAuth } from "../apple-auth.js"
import type { CloudEnv } from "../env.js"
import { heading, page } from "./pages.js"

type Ctx = Context<{ Bindings: CloudEnv }>

export const accountPage = (c: Ctx) => {
  c.header("Cache-Control", "no-store")
  return page(
    c,
    "Sign-in methods",
    <>
      {heading(
        "Sign-in methods",
        "Connect another sign-in method to keep using this same Cloud account on every device."
      )}
      <p id="identity" class="mb-6 break-words text-sm text-zinc-300">
        Checking your account…
      </p>
      <div id="providers" class="hidden flex-col gap-3">
        {hasAppleAuth(c.env) ? (
          <button id="apple" class="rounded-lg bg-white px-4 py-3 text-sm font-medium text-black">
            Connect Apple
          </button>
        ) : null}
        {c.env.GITHUB_CLIENT_ID && c.env.GITHUB_CLIENT_SECRET ? (
          <button id="github" class="rounded-lg bg-white px-4 py-3 text-sm font-medium text-black">
            Connect GitHub
          </button>
        ) : null}
      </div>
      <p id="status" role="status" class="mt-4 text-sm text-amber-400"></p>
      <a id="done" class="mt-6 hidden text-sm text-sky-400">
        Return to Codevisor
      </a>
    </>,
    `
    const params = new URLSearchParams(location.search);
    const scheme = params.get("app");
    const appQuery = ["codevisor", "codevisor-dev"].includes(scheme)
      ? "?app=" + encodeURIComponent(scheme) : "";
    const callbackURL = "/account" + appQuery;
    const status = document.getElementById("status");
    const request = async (path, body) => {
      const response = await fetch("/api/auth/" + path, {
        method: body === undefined ? "GET" : "POST",
        headers: { "content-type": "application/json" },
        credentials: "include",
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      });
      if (!response.ok) throw new Error("Your session could not be used. Close this page and try again from Codevisor.");
      return response.json();
    };
    (async () => {
      // Only the single-use handoff travels in the URL, in a fragment that
      // never reaches access logs. Remove it before doing any network work.
      const ott = new URLSearchParams(location.hash.slice(1)).get("ott");
      history.replaceState(null, "", location.pathname + location.search);
      if (ott) await request("one-time-token/verify", { token: ott });
      const session = await request("get-session");
      if (!session?.user) throw new Error("Open sign-in methods from your signed-in Codevisor app.");
      document.getElementById("identity").textContent = "Cloud account: " + session.user.email;
      const accounts = await request("list-accounts");
      for (const provider of ["apple", "github"]) {
        const button = document.getElementById(provider);
        if (!button) continue;
        if (accounts.some(account => account.providerId === provider)) {
          button.textContent = (provider === "apple" ? "Apple" : "GitHub") + " connected";
          button.disabled = true;
          continue;
        }
        button.addEventListener("click", async () => {
          button.disabled = true;
          try {
            const result = await request("link-social", {
              provider, callbackURL, errorCallbackURL: callbackURL + (appQuery ? "&" : "?") + "failed=1"
            });
            if (!result.url) throw new Error("Unable to start sign-in. Please try again.");
            location.href = result.url;
          } catch (error) { status.textContent = error.message; button.disabled = false; }
        });
      }
      document.getElementById("providers").classList.remove("hidden");
      document.getElementById("providers").classList.add("flex");
      const done = document.getElementById("done");
      done.href = "/auth/handoff" + appQuery;
      done.classList.remove("hidden");
      if (params.has("failed")) status.textContent = "The account could not be connected. It may already belong to another Cloud account. No accounts were merged. Try again or return to Codevisor.";
    })().catch(error => { status.textContent = error.message; });
  `
  )
}

export const authErrorPage = (c: Ctx) =>
  page(
    c,
    "Sign-in incomplete",
    <>
      {heading("Sign-in didn’t complete")}
      <p class="text-sm leading-relaxed text-zinc-300">
        Close this page and try again from Codevisor. If you already use GitHub, sign in with GitHub
        first, then open Manage Sign-In Methods to connect Apple to that account.
      </p>
    </>
  )
