# 851-2361 (and 851-2360) — what macOS will send us, and whether pipelining helps

Host: tuftlord (macOS Screen Sharing, 3024×1964), showing the frame-clock
page's video workload (851-2358). Client: `screen-sharing-rig vnc-sample`
(the product's `RFBClient`, no UI), release build, Mac-account sign-in.

## Which encodings macOS sends (851-2361)

`vnc-sample --encodings N,-223` advertises exactly one encoding (plus
DesktopSize). An encoding the client can't decode would end the sample with
its number; none did.

| advertised                                 | macOS sent          | updates/s | MB/update |
| ------------------------------------------ | ------------------- | --------: | --------: |
| ZRLE (16)                                  | ZRLE                |      0.64 |      11.8 |
| Tight (7), with and without JPEG quality 6 | **Raw**             |  0.96–1.1 | 10.6–12.0 |
| RRE (2)                                    | Raw                 |      0.80 |      10.1 |
| ZYWRLE (17)                                | Raw                 |      0.47 |      14.9 |
| Raw (0)                                    | Raw                 |      0.47 |      15.9 |
| Hextile (5)                                | nothing in 6 s      |         – |         – |
| Zlib (6)                                   | nothing in 40 s     |         – |         – |
| Apple 1100, 1103, 1104                     | Raw                 | 0.94–1.27 |  9.2–15.7 |
| Apple 1000, 1001, 1002, 1011, 1101, 1102   | **nothing in 40 s** |         – |         – |

- macOS offers a standard client **no lossy encoding**: no Tight/JPEG
  (it falls back to Raw), no continuous updates. ZRLE is the best it gives us.
- Apple's own encodings 1000–1002, 1011, 1101 and 1102 are recognised (the
  server stops sending and waits, presumably for Apple-specific setup
  messages), but they are undocumented: IANA lists them as "Apple Inc." with
  no description, Wireshark's VNC dissector doesn't know them, and no open
  client implements them.

## Keeping requests in flight (851-2360)

`vnc-sample --depth N --early true|false`, 20 s each:

| outstanding requests | request on header | updates/s | Mbit/s | MB/update | request → update p50 |
| -------------------: | ----------------- | --------: | -----: | --------: | -------------------: |
|            1 (today) | no                | 1.13–1.36 |  45–67 |   5.0–6.2 |           570–680 ms |
|                    1 | yes               |      1.18 |     63 |       6.7 |               670 ms |
|                    2 | no                |      1.31 |     63 |       6.0 |              1110 ms |
|                    2 | yes               |      1.75 |     73 |       5.2 |               920 ms |
|                    4 | yes               |      2.50 |     85 |       4.3 |              1650 ms |

On full-screen motion the stream is **bandwidth-bound** (5–6 MB of lossless
data per update at 45–85 Mbit/s). Pipelining buys up to ~1.8× updates but
each image is older (request → update up to 1.65 s), so the lag the user
sees gets worse. It may still help lighter workloads (typing, scrolling),
where the server's wait rather than bytes dominates; that's not measured yet.

## Conclusion

VNC to a Mac can't approach Apple's viewer on motion: the best we can get is
lossless ZRLE of the full Retina framebuffer (~5 MB per frame), at ~1–2.5
frames per second on this link, whatever the client does. Options:

1. **Native path for Mac hosts** (851-2365): ScreenCaptureKit + hardware
   H.264 through codevisor-server on the Mac, which Codevisor already has.
2. Fewer pixels (851-2363), if macOS can be made to send a scaled
   framebuffer to a standard client.
3. Reverse-engineering Apple's private encodings: large, fragile, and
   undocumented.

Client-side work (decode off the read path 851-2362, the rig's own ~3× loss
851-2364) still matters for Linux hosts and for lighter workloads.

## Tooling added

- `RFBClient.advertise(_:)` and `vnc-sample --encodings N,N,…`.
- `RFBClient.setRequestPipelining(depth:beforeApplying:)` and
  `vnc-sample --depth N --early true|false`. The defaults (1, false) are the
  existing behaviour.
