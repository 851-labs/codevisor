export const EXEC_OUTPUT_LIMIT = 30_000

export class OutputTail {
  private kept = ""
  private dropped = 0

  append(text: string): void {
    this.kept += text
    if (this.kept.length <= EXEC_OUTPUT_LIMIT) return
    this.dropped += this.kept.length - EXEC_OUTPUT_LIMIT
    this.kept = this.kept.slice(-EXEC_OUTPUT_LIMIT)
  }

  text(outputPath?: string): string {
    if (this.dropped === 0) return this.kept
    const where = outputPath === undefined ? "" : `; the full output is in ${outputPath}`
    return `[${this.dropped} earlier characters cut${where}]\n${this.kept}`
  }
}
