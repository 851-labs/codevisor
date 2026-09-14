import { execFileSync } from "node:child_process"
import { readdir } from "node:fs/promises"
import { join } from "node:path"

// Visit nested code before its enclosing bundle. Do not follow symlinks into
// another bundle or include resource-only Swift package bundles.
export async function embeddedCodePaths(bundle) {
  const paths = []
  for (const entry of await readdir(bundle, { withFileTypes: true })) {
    const path = join(bundle, entry.name)
    if (entry.isDirectory()) {
      paths.push(...(await embeddedCodePaths(path)))
      if (/\.(framework|appex|app)$/.test(entry.name)) paths.push(path)
    } else if (entry.isFile() && entry.name.endsWith(".dylib")) {
      paths.push(path)
    }
  }
  return paths
}

export async function prepareEmbeddedCode(bundle, entitlementsPath) {
  for (const path of await embeddedCodePaths(bundle)) {
    // Unsigned archives can contain linker signatures with temporary binary
    // identifiers. Give Xcode the bundle identity before cloud distribution
    // signing so its designated requirement matches the exported identifier.
    execFileSync("codesign", ["--force", "--sign", "-", path], { stdio: "inherit" })
  }
  // CODE_SIGNING_ALLOWED=NO skips the app's entitlements too. Export preserves
  // capabilities from an existing signature, so attach the declared entitlements
  // with an ad-hoc signature before Xcode replaces it with cloud distribution
  // signing. No local signing identity or provisioning profile is required.
  execFileSync("codesign", ["--force", "--sign", "-", "--entitlements", entitlementsPath, bundle], {
    stdio: "inherit"
  })
}

export async function verifyDistributionSignatures(bundle, teamId) {
  for (const path of [...(await embeddedCodePaths(bundle)), bundle]) {
    // --deep on the outer app can miss a framework's invalid designated
    // requirement. Verify each component directly as well as its team.
    execFileSync("codesign", ["--verify", "--strict", "--verbose=2", path], { stdio: "inherit" })
    execFileSync(
      "codesign",
      [
        "--verify",
        "--strict",
        "-R",
        `=anchor apple generic and certificate leaf[subject.OU] = "${teamId}" and certificate leaf[field.1.2.840.113635.100.6.1.4] exists`,
        path
      ],
      { stdio: "inherit" }
    )
  }
}
