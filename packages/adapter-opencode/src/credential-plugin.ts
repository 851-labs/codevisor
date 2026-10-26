export const OPENCODE_MANAGED_METHODS: ReadonlyArray<readonly [string, string]> = [
  ["openai", "chatgpt-browser"],
  ["xai", "device"],
  ["opencode", "device"]
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

export const openCodeCredentialPluginFiles: Readonly<Record<string, string>> = {
  "index.mjs": plugin,
  "package.json": `${JSON.stringify(
    { name: "codevisor-shared-credentials", private: true, type: "module", main: "index.mjs" },
    null,
    2
  )}\n`
}
