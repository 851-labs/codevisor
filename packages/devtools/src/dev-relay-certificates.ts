import { spawn } from "node:child_process"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { pathExists } from "./files.ts"

export interface CertificateSubject {
  readonly netRoot: string
  readonly relayHost: string
  readonly vmHost?: string | undefined
}

const certificateDigest = "-sha256"
const validDays = "825"

export async function ensureDevCertificates(net: CertificateSubject): Promise<void> {
  const names = [
    ...new Set(["localhost", "127.0.0.1", "::1", net.relayHost, net.vmHost].filter(isPresent))
  ]
  const directory = net.netRoot
  await mkdir(directory, { recursive: true })
  const namesFile = join(directory, "cert-names.json")
  const fingerprint = JSON.stringify({ names, digest: certificateDigest })
  if (await isCurrent(namesFile, fingerprint, join(directory, "relay.key"))) return

  await writeExtensions(directory, names)
  const openssl = (...args: Array<string>) => run("openssl", args, directory)
  await createCertificateAuthority(openssl)
  await createRelayCertificate(openssl)
  await writeFile(namesFile, fingerprint)
}

async function isCurrent(namesFile: string, fingerprint: string, key: string): Promise<boolean> {
  const current = await readFile(namesFile, "utf8").catch(() => "")
  return current === fingerprint && pathExists(key)
}

async function writeExtensions(directory: string, names: ReadonlyArray<string>): Promise<void> {
  const sans = names
    .map((name) => (/^[0-9.:]+$/.test(name) ? `IP:${name}` : `DNS:${name}`))
    .join(",")
  await writeFile(
    join(directory, "relay.ext"),
    `basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=${sans}\n`
  )
  await writeFile(
    join(directory, "ca.ext"),
    "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
  )
}

async function createCertificateAuthority(
  openssl: (...args: Array<string>) => Promise<void>
): Promise<void> {
  await openssl("ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", "ca.sec1.key")
  await openssl("pkcs8", "-topk8", "-nocrypt", "-in", "ca.sec1.key", "-out", "ca.key")
  await openssl(
    "req",
    "-new",
    certificateDigest,
    "-key",
    "ca.key",
    "-subj",
    "/CN=Codevisor Dev Relay CA",
    "-out",
    "ca.csr"
  )
  await openssl(
    "x509",
    "-req",
    certificateDigest,
    "-in",
    "ca.csr",
    "-signkey",
    "ca.key",
    "-days",
    validDays,
    "-extfile",
    "ca.ext",
    "-out",
    "ca.pem"
  )
}

async function createRelayCertificate(
  openssl: (...args: Array<string>) => Promise<void>
): Promise<void> {
  await openssl("ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", "relay.sec1.key")
  await openssl("pkcs8", "-topk8", "-nocrypt", "-in", "relay.sec1.key", "-out", "relay.key")
  await openssl(
    "req",
    "-new",
    certificateDigest,
    "-key",
    "relay.key",
    "-subj",
    "/CN=codevisor-dev-relay",
    "-out",
    "relay.csr"
  )
  await openssl(
    "x509",
    "-req",
    certificateDigest,
    "-in",
    "relay.csr",
    "-CA",
    "ca.pem",
    "-CAkey",
    "ca.key",
    "-CAcreateserial",
    "-days",
    validDays,
    "-extfile",
    "relay.ext",
    "-out",
    "relay.pem"
  )
}

function run(command: string, args: ReadonlyArray<string>, cwd: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "inherit"], cwd })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} ${args.join(" ")} exited ${code}`))
    )
  })
}

function isPresent(value: string | undefined): value is string {
  return Boolean(value)
}
