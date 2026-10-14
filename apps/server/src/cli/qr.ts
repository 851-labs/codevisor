import qrcode from "qrcode-terminal"

export const renderQr = (text: string): string[] => {
  let output = ""
  qrcode.generate(text, { small: true }, (qr) => {
    output = qr
  })
  return output.split("\n")
}
