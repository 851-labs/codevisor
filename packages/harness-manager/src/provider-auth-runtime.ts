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
