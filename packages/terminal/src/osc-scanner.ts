export interface OscPrefix {
  readonly prefix: string
  readonly maxLength: number
}

export type OscEvent =
  | { readonly type: "osc"; readonly body: string; readonly terminator: string }
  | { readonly type: "reset" }

export interface OscScanner {
  readonly scan: (data: string) => ReadonlyArray<OscEvent>
}

const ESC = "\u001b"
const BEL = "\u0007"

export const makeOscScanner = (prefixes: ReadonlyArray<OscPrefix>): OscScanner => {
  let carry = ""
  const wanted = (body: string): boolean => prefixes.some(({ prefix }) => body.startsWith(prefix))
  const pending = (body: string): boolean =>
    prefixes.some(({ prefix, maxLength }) =>
      body.startsWith(prefix) ? body.length <= maxLength : prefix.startsWith(body)
    )

  return {
    scan: (data) => {
      const text = carry + data
      carry = ""
      const events: Array<OscEvent> = []
      let index = text.indexOf(ESC)
      while (index !== -1) {
        const next = text[index + 1]
        if (next === undefined) {
          carry = text.slice(index)
          break
        }
        if (next === "c") events.push({ type: "reset" })
        if (next !== "]") {
          index = text.indexOf(ESC, index + 1)
          continue
        }
        const start = index + 2
        const end = sequenceEnd(text, start)
        if (end === undefined) {
          if (pending(text.slice(start))) carry = text.slice(index)
          break
        }
        const terminator = terminatorAt(text, end)
        const body = text.slice(start, end)
        if (terminator !== undefined && wanted(body)) events.push({ type: "osc", body, terminator })
        index = terminator === undefined ? end : text.indexOf(ESC, end + 1)
      }
      return events
    }
  }
}

const sequenceEnd = (text: string, start: number): number | undefined => {
  const bel = text.indexOf(BEL, start)
  const esc = text.indexOf(ESC, start)
  const end = bel !== -1 && (esc === -1 || bel < esc) ? bel : esc
  if (end === -1 || (end === esc && text[esc + 1] === undefined)) return undefined
  return end
}

const terminatorAt = (text: string, end: number): string | undefined => {
  if (text[end] === BEL) return BEL
  if (text[end + 1] === "\\") return `${ESC}\\`
  return undefined
}
