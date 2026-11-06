export interface ShipOptions {
  readonly review: boolean
  readonly wait: boolean
  readonly pullRequestDetails: ReadonlyArray<string>
}

export const shipUsage =
  "usage: bun run ship [--review] [--wait] [--title <title>] [--body <body> | --body-file <path>]"

const detailFlags = new Set(["--title", "--body", "--body-file"])

export function parseShipArguments(argv: ReadonlyArray<string>): ShipOptions {
  const details: Array<string> = []
  let review = false
  let wait = false
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index] ?? ""
    const value = argv[index + 1]
    if (argument === "--review") review = true
    else if (argument === "--wait") wait = true
    else if (detailFlags.has(argument) && value !== undefined) {
      details.push(argument, value)
      index += 1
    } else throw new Error(`${shipUsage} (unknown argument ${argument})`)
  }
  return { review, wait, pullRequestDetails: details }
}
