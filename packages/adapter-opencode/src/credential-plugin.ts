/// OpenCode 2 plugin that lets a Codevisor-shared sign-in refresh without
/// OpenCode ever holding the rotating refresh token. OpenCode refreshes an
/// OAuth credential by calling its sign-in method's `refresh` once the token
/// is within five minutes of expiring; this plugin replaces that `refresh`
/// for the methods Codevisor shares. A credential Codevisor seeded carries
/// `codevisor:<capability>` where the refresh token would be, and the
/// capability (good only at this machine's Codevisor server) buys a fresh
/// access token. GitHub Copilot's stored token doesn't expire, so it has
/// nothing to refresh.
///
/// Loaded from a directory through OpenCode's `plugins` config, with the
/// token service URL as its `broker` option. It replaces those methods'
/// sign-in too: a profile Codevisor manages signs in through Codevisor.

/// Integration and OAuth method ids whose refresh Codevisor provides.
export const OPENCODE_MANAGED_METHODS: ReadonlyArray<readonly [string, string]> = [
  ["openai", "chatgpt-browser"],
  ["xai", "device"]
]

const plugin = String.raw`
const managed = ${JSON.stringify(OPENCODE_MANAGED_METHODS)};
const PREFIX = "codevisor:";

export default {
  id: "codevisor.shared-credentials",
  setup: async (ctx) => {
    const broker = ctx.options && ctx.options.broker;
    if (typeof broker !== "string") throw new Error("Codevisor's credential plugin needs its broker URL.");
    await ctx.integration.transform((editor) => {
      for (const [integrationID, id] of managed) {
        const method = editor.method.list(integrationID).find((m) => m.type === "oauth" && m.id === id);
        if (!method) continue;
        editor.method.update({
          integrationID,
          method,
          authorize: async () => {
            throw new Error("Sign in to this provider from Codevisor's OpenCode accounts.");
          },
          refresh: async (credential) => {
            if (typeof credential.refresh !== "string" || !credential.refresh.startsWith(PREFIX))
              throw new Error("Sign in to this provider again from Codevisor's OpenCode accounts.");
            const response = await fetch(broker, {
              method: "POST",
              redirect: "error",
              headers: {
                Authorization: "Bearer " + credential.refresh.slice(PREFIX.length),
                "Content-Type": "application/json"
              },
              body: JSON.stringify({ rejectedAccessToken: credential.access })
            });
            if (!response.ok) throw new Error("Reconnect this account in Codevisor.");
            const { credential: fresh } = await response.json();
            return { ...credential, access: fresh.access, expires: fresh.expires };
          }
        });
      }
    });
  }
};
`

/// The plugin directory's files, by name.
export const openCodeCredentialPluginFiles: Readonly<Record<string, string>> = {
  "index.mjs": plugin,
  "package.json": `${JSON.stringify(
    { name: "codevisor-shared-credentials", private: true, type: "module", main: "index.mjs" },
    null,
    2
  )}\n`
}
