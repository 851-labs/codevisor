import qrcode from "qrcode-terminal"

/// Text as terminal half-block QR lines. qrcode-terminal's generate callback
/// is synchronous; capturing it keeps callers on the injectable line-logger
/// seam instead of printing straight to stdout.
export const renderQr = (text: string): string[] => {
  let output = ""
  qrcode.generate(text, { small: true }, (qr) => {
    output = qr
  })
  return output.split("\n")
}
