# 851-2316: UTF-8 clipboard — notes

`validate.md` is the gate's output: PASS (tests 288 + 92, interop 7/7, bench
A/B against origin/main with no verdicts, tophat 24/24).

## What changed

- **Protocol:** `RFBExtendedClipboard` encodes and decodes the Extended
  Clipboard pseudo-encoding (0xC0A1E5CE): caps (with per-format maximum
  sizes), request, peek, notify, provide. Provide carries one complete zlib
  stream; text is UTF-8, CRLF line endings, NUL-terminated. The client
  advertises it; extended ServerCutText (negative length) becomes an event,
  and an undecodable one is dropped without ending the session.
- **Host emulator:** answers the server's caps with its own; sending text
  announces it (notify) and provides it when the server asks; a server
  notify is followed at once by a request, so "Get Clipboard from Machine"
  has the text. Servers without the extension still get Latin-1.
- **Reference server:** caps, eager request on notify, `setClipboard`,
  `clipboardTextsReceived`; the rig's Loopback server enables it and its
  input log shows UTF-8 text.

## Evidence

- **L1:** every message round-trips; the wire form of "a\nb" is exactly
  `0,0,0,5, a, CR, LF, b, NUL`; malformed input is rejected. The first run
  caught a real bug: in a caps message the other action bits list supported
  actions, so caps must be decoded before the single-action switch.
- **L2:** "héllo — 日本語 😀\nline two" goes through the product's own
  `ScreenSharingClipboardTransfer` → session → reference server exactly, and
  back; a server without the extension still gets Latin-1.
- **L3 (TigerVNC 1.15):** TigerVNC ignores text provided unprompted, so the
  interop container runs a watcher that reads the clipboard (the paste that
  makes Xvnc request the client's text) and writes `echo:<text>` back. The
  test drives caps → notify → request → provide and gets
  `echo:héllo — 日本語 😀 <id>` back byte for byte.
- **L4:** the tophat's clipboard token now includes "日本語 😀" and arrives
  intact through the product's "Send Clipboard to Machine".

Metric target: correctness only.
