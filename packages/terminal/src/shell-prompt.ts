/// Whether a shell is waiting at its prompt or running a command, from the
/// semantic prompt marks (OSC 133) its shell integration writes: `A` a
/// prompt starts, `C` a command's output starts, `D` the command finished.
///
/// The title a shell sets at its prompt is its theme's (`user@host:~/path`),
/// the same every time; the useful titles are the ones set while a command
/// runs (`npm run dev`, a TUI's own name). A shell without integration never
/// writes the marks, so its state stays unknown and every title counts.
export interface ShellPrompt {
  /// Scans a chunk of output. A mark split across chunks is completed by the
  /// next one.
  readonly observe: (data: string) => void
  /// True while a command runs, false at the prompt, undefined until the
  /// shell has written a mark.
  readonly running: () => boolean | undefined
}

const MARK = "\u001b]133;"

export const makeShellPrompt = (): ShellPrompt => {
  let running: boolean | undefined
  // The end of the previous chunk, in case a mark began there.
  let carry = ""
  return {
    observe: (data) => {
      const text = carry + data
      let index = text.indexOf(MARK)
      while (index !== -1) {
        const kind = text[index + MARK.length]
        if (kind === "C") running = true
        else if (kind === "A" || kind === "D") running = false
        index = text.indexOf(MARK, index + MARK.length)
      }
      // Keep only what could be the start of a mark: at most the mark and
      // its kind letter.
      carry = text.slice(-MARK.length)
    },
    running: () => running
  }
}
