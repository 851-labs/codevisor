import { createHash } from "node:crypto"
import { mkdir, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

export const gatewayExtension = String.raw`
export default function (pi) {
  const url = process.env.CODEVISOR_MCP_GATEWAY_URL;
  if (!url || typeof pi.registerMcpServer !== "function") return;
  pi.registerMcpServer(process.env.CODEVISOR_MCP_GATEWAY_NAME || "codevisor", {
    url,
    headers: { Authorization: "Bearer " + process.env.CODEVISOR_MCP_GATEWAY_TOKEN },
    exposure: "direct",
    description: "Codevisor: the user's apps, browser, terminals and other machines"
  });
}
`

export type ExtensionWriter = (name: string, source: string) => Promise<string>

/* v8 ignore start */
export const writeTemporaryExtension: ExtensionWriter = async (name, source) => {
  const directory = join(tmpdir(), "codevisor-pi-extensions")
  await mkdir(directory, { recursive: true })
  const digest = createHash("sha256").update(source).digest("hex").slice(0, 16)
  const path = join(directory, `${name}-${digest}.ts`)
  await writeFile(path, source)
  return path
}
/* v8 ignore stop */
