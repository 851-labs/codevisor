# codevisor-media

The screen sharing v2 media transport (851-3815, §3.3 of the
[HP-class engine design](https://linear.app/851/document/hp-class-engine-design-0b6e749493a3)). It carries encoded
video frames from the host to the viewer over QUIC datagrams on an iroh connection (ALPN `codevisor/screen/1`), with
no jitter buffer and no queue deeper than one frame.

## What it does

- **Framing and packetizing.** Each frame (one tile's access unit plus a few transport fields) is cut into balanced
  packets that fit the path's current datagram size, each with a 16-byte header.
- **Frame-spread pacing.** A frame's packets leave at twice the capacity estimate. When that wouldn't finish within
  half a frame interval they go faster, but never past four times the estimate, which would only overflow a slow
  link's queue. The pacer is a token bucket holding 1 ms of sending, because tokio's timers fire at 1 ms resolution.
- **Loss recovery, cheapest first.**
  1. NACK as soon as a gap shows, or once the tail wait passes (1.5 × the longest recent gap between a frame's
     packets, at least 1 ms).
  2. Reed–Solomon parity, one block per frame over GF(2^16) (`reed-solomon-simd`). With `FecMode::Adaptive` it's
     on while loss was seen in the last 10 s or the round trip is over a quarter of a frame interval: 5–25% of each
     frame's data packets (more as loss rises), at least one parity packet.
  3. Give up `max(RTT + 2 ms, 1.5 frame intervals)` after the first NACK, and tell the host (`Event::FrameLost`):
     its next encode of that stream should be an LTR refresh.
- **In-order delivery per stream, without waiting across streams.** A complete frame is delivered at once unless its
  predecessor in the same stream is still being repaired.
- **Per-frame feedback.** The viewer reports every frame it resolves, with its receive times, the stream's recent
  losses, and the newest LTR token its decoder acknowledged. The host turns these into events, a capacity estimate
  and the encoder's admission signal.
- **Delivery at idle.** The host keeps each frame until it hears about it and re-sends its last data packet when an
  ack is overdue (at most 6 times), so a lost last frame before idle is repaired instead of never.
- **Capacity estimate.** A 1 s maximum filter over per-frame delivery rates (bytes that arrived the first time, over
  their arrival spread). It backs off by 15% when frames' first packets keep finding a growing standing queue (2 ms
  over the 10 s minimum one-way delay).
- **Admission.** Encode the next capture only while the bytes waiting to be sent fit one frame interval at the
  estimate. The encoder ceiling is 85% of the estimate.

## Using it

`MediaSession` runs one end over a transport:

- The host calls `send_frame` once per encoded tile, and checks `admission()` before encoding the next capture.
  `send_frame` borrows the frame and only packetizes and queues it, so the encoder's buffer is free on return; the
  session's task sends, receives and runs the timers.
- The viewer takes `Event::Frame`s from `next_event`, decodes them, and calls `ack_ltr` for frames that carried an LTR
  token.
- The host gets `Event::FrameAcked`, `Event::FrameLost` and `Event::LtrAcked` from the same `next_event`. The viewer
  also gets `Event::FrameSkipped` when the transport gave up on a frame.
- `close()` stops the session and ends `next_event`. The connection stays open.

Transports implement `DatagramTransport`:

- `QuicTransport` is the product path. It keeps at most 256 KiB queued inside QUIC and hands later datagrams back
  as `SendOutcome::Full`, so the backlog stays in the pacer, where admission sees it.
- `UdpTransport` is the raw-UDP baseline and fallback.
- `ImpairedTransport` sends through a seeded `netsim::NetworkModel` (the benchmark's N0–N7) for the bench.

`Core` is the same transport as a state machine with no I/O and no clock of its own: feed it datagrams and the time,
and take datagrams, wake-up times and events out. The deterministic tests drive two of them over `netsim`.

## Swift

`codevisor-net-ffi` exposes one call per frame each way:

```swift
let connection = try await endpoint.connect(addr: viewer, alpn: mediaAlpn(), cancel: nil)
let session = await connection.openMediaSession(
  config: MediaSessionConfig(frameIntervalUs: 16_667, fecPercent: nil, initialRateKbps: 100_000))
if session.admission().admit {
  try session.sendFrame(stream: tile, keyframe: false, ltrToken: token, meta: timings, data: accessUnit)
}
while let event = await session.nextEvent() {
  if case .frame(let stream, _, _, let ltrToken, _, let bytes, _, _) = event {
    bytes.withUnsafeBytes { decode($0) }
    if let ltrToken { session.ackLtr(stream: stream, token: ltrToken) }
  }
}
```

The viewer side accepts with `NetEndpointHandle.accept()`. Frame bytes cross the boundary through a small C ABI
(`codevisor-net-ffi/include/codevisor_media.h`) wrapped by CodevisorNet's `MediaSessionHandle+FramePath.swift`, not
through uniffi: uniffi copies `Data` byte by byte, which measured 1–4 ms per frame on the minis, against
0.04–0.14 ms for the C ABI. `sendFrame` throws `MediaSendError` (no datagrams, path too small, metadata over 64 KiB,
frame over 65 535 packets).

The C functions take uniffi object handles from `uniffiCloneHandle()` and consume them; the buffers they're given must
be readable for the call, and `codevisor_media_bytes`' pointer is valid while the `MediaBytes` object lives. Panics
inside `codevisor_media_send_frame` are caught and returned as -5.

## Wire format

Every datagram starts with a version/kind byte (version in the high nibble, 1) and a stream byte. Integers are big
endian. Kinds 4 and up are reserved for audio and cursor.

Media packet (kind 0 data, kind 1 parity), 16 bytes before the shard:

| Bytes  | Field                                                      |
| ------ | ---------------------------------------------------------- |
| 0      | version and kind                                           |
| 1      | stream (a tile, or any other independent picture sequence) |
| 2..6   | frame number, counted per stream from 0                    |
| 6..8   | packet index: data shards `0..k`, then parity `k..k + m`   |
| 8..10  | `k`, the frame's data packet count                         |
| 10..12 | `m`, the frame's parity packet count                       |
| 12..16 | the frame payload's length                                 |

The payload is split into `k` shards of `ceil(len / k)` rounded up to even bytes (the last one shorter); parity shards
are that long. The payload itself is a flags byte (1 keyframe, 2 LTR token present), the optional LTR token (u64), the
metadata length (u16) and metadata, then the access unit.

Feedback (kind 2, viewer to host), one per resolved frame and per LTR acknowledgement:

| Bytes  | Field                                                                                                                                                     |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2..6   | the frame reported on (`u32::MAX` for none)                                                                                                               |
| 6      | flags: 1 lost, 2 receipt present, 4 LTR token present                                                                                                     |
| 7      | recovery of the reported frame: 0 none, 1 FEC, 2 NACK                                                                                                     |
| 8..12  | `resolved_below`: every earlier frame is delivered or given up                                                                                            |
| 12..16 | lost bitmap: bit `i` set means frame `resolved_below - 1 - i` was given up                                                                                |
| 16..36 | receipt: first arrival (u64 µs), last first-time arrival and completion (u32 µs after it), bytes that arrived the first time after the first packet (u32) |
| 36..44 | the newest LTR token the viewer's decoder acknowledged on this stream (optional)                                                                          |

NACK (kind 3): the frame (u32), a range count (u16, at most 64), then `(first index, count)` pairs of u16. A count of
`0xFFFF` asks for every data packet of a frame the viewer never saw.

## Bench

`bench::run` measures `send_frame` → ack round trips over iroh and over raw UDP with the same framing, the share of
frames complete within RTT + 2 ms of their last first-time arrival (the RTT taken from the acks), recovery delays and
counters, optionally through an emulated network:

```text
cargo run --release --example media_transport_bench -- loopback --network N3 --seconds 10
CodevisorBench media-transport --role viewer --bind 0.0.0.0:47310 --udp-bind 0.0.0.0:47311 --secret HEX
CodevisorBench media-transport --role host --peer-secret HEX --peer IP:47310 --udp-peer IP:47311
CodevisorBench media-transport --role ffi-cost
```

Two-Mac runs go through the signed `CodevisorBench.app`, which calls `bench::run` in-process (`media_bench_run`),
because macOS Local Network privacy drops LAN UDP from unsigned binaries run by the CI runner.

## Not yet

Audio and cursor datagrams, the control-plane streams, the media connection's own QUIC transport config (E2), and
tuning the estimator and FEC on constrained links (E7).
