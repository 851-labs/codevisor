/** Native integrations contain no credentials. Their mode-0600 manifest holds
 * machine-local capabilities; real rotating refresh tokens stay in the vault. */
export const piAuthExtension = String.raw`
import { readFile } from "node:fs/promises";
import { builtinProviders } from "@earendil-works/pi-ai/providers/all";
export default async function(pi) {
  const manifest = JSON.parse(await readFile(process.env.CODEVISOR_PROVIDER_AUTH, "utf8"));
  for (const provider of builtinProviders()) {
    const managed = manifest.providers[provider.id];
    if (!managed || !provider.auth.oauth) continue;
    const native = provider.auth.oauth;
    pi.registerProvider({ ...provider, auth: { ...provider.auth, oauth: { ...native,
      async refresh(credential, signal) {
        const response = await fetch(manifest.url, {
          method: "POST", redirect: "error", signal,
          headers: { Authorization: "Bearer " + managed.capability, "Content-Type": "application/json" },
          body: JSON.stringify({ rejectedAccessToken: credential.access })
        });
        if (!response.ok) throw new Error("Reconnect this account in Codevisor.");
        return (await response.json()).credential;
      }
    } } });
  }
}
`

export const openCodeAuthPlugin = String.raw`
import { readFile } from "node:fs/promises";
export default async function() {
  const manifest = JSON.parse(await readFile(process.env.CODEVISOR_PROVIDER_AUTH, "utf8"));
  const symbol = Symbol.for("codevisor.provider-auth");
  if (!globalThis[symbol]) {
    const original = globalThis.fetch;
    const entries = new Map();
    globalThis[symbol] = entries;
    globalThis.fetch = Object.assign(async function(input, init) {
      const request = new Request(input, init);
      if (request.method !== "POST") return original(input, init);
      const contentType = request.headers.get("content-type") || "";
      if (!contentType.includes("application/json") && !contentType.includes("application/x-www-form-urlencoded"))
        return original(input, init);
      const text = await request.clone().text();
      if (!text.includes("codevisor:") && !text.includes("codevisor%3A")) return original(input, init);
      let fields;
      try { fields = contentType.includes("application/json") ? JSON.parse(text) : Object.fromEntries(new URLSearchParams(text)); }
      catch { throw new Error("Invalid managed authentication request."); }
      if (typeof fields?.refresh_token !== "string" || !fields.refresh_token.startsWith("codevisor:")) return original(input, init);
      const managed = entries.get(fields.refresh_token);
      // Never send a managed refresh handle to an upstream endpoint, including
      // when a plugin changes its contract or its manifest is missing.
      if (!managed || fields.grant_type !== "refresh_token" || request.url !== managed.endpoint)
        throw new Error("This authentication provider needs a Codevisor update.");
      const response = await original(managed.url, {
        method: "POST", redirect: "error", signal: request.signal,
        headers: { Authorization: "Bearer " + managed.capability, "Content-Type": "application/json" },
        body: "{}"
      });
      if (!response.ok) throw new Error("Reconnect this account in Codevisor.");
      const value = await response.json();
      managed.access = value.credential.access;
      return Response.json({ access_token: value.credential.access,
        refresh_token: fields.refresh_token, token_type: "Bearer",
        expires_in: Math.max(1, Math.floor((value.credential.expires - Date.now()) / 1000)),
        ...(value.idToken ? { id_token: value.idToken } : {}) });
    }, original);
  }
  for (const managed of Object.values(manifest.providers))
    globalThis[symbol].set("codevisor:" + managed.capability, { ...managed, url: manifest.url });
  return {};
}
`
