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
  link's queue. Under 100 Mbit/s they leave at 1.25 times the estimate and never faster (once the backlog is over half
  a frame interval's worth, at the estimate itself, so a keyframe or refresh several frames long doesn't overdrive a
  short queue), and both gains ramp linearly back to 2 and 4 by 200 Mbit/s: a link that slow can have a queue shorter than one frame (N5's 30 packets), and
  twice the estimate overflowed it on every large frame, so in the sim half of N5's frames were given up after NACK
  storms. The pacer is a token bucket holding 1 ms of sending,
  because tokio's timers fire at 1 ms resolution.
- **Loss recovery, cheapest first.**
  1. NACK as soon as a gap shows, or once the tail wait passes (1.5 × the longest recent gap between a frame's
     packets, at least 1 ms; the longest gap fades by 1/64 per resolved frame, about 0.7 s at 60 frames a second).
     At 1/16 per frame (851-3822) it forgot N6's 5 ms jitter within 11 frames and NACKed the next delayed packet as
     lost: in the sim 6% of N6's packets were resent, against 0.9% now, and those NACKs pinned FEC at 13–25%. When
     the tail wait passes, the viewer asks only for the packets that should have arrived by then at the frame's own
     pace (from every packet of it that arrived), or at the receiver's recent longest gap before the frame has a
     pace, or just the next packet before any gap is known (at least the next one), and waits again, so a slow link's frame isn't requested whole while it's still
     arriving: on N7 the first 800 KB keyframe used to be resent whole 1 ms after its first packet (675 packets, 13 s
     of queue at 1 Mbit/s), against 38 packets now. The viewer repeats a NACK every RTT + 1 ms; the host skips a packet whose
     retransmission is still queued or left less than half a round trip ago (a NACK that crossed it). Without that, at a low estimate, each
     repeat queued a large frame's packets again, and the backlog held admission shut: in the sim (N4, a 150 KB
     frame every 2 s from a 1 Mbit/s start) for 168 frames after each one, against 34–40 now, and in Tier 1 run
     41617646973 (scroll N4) for 8.5 s, with 2,707 packets resent for 43 NACKs.
  2. Reed–Solomon parity, one block per frame over GF(2^16) (`reed-solomon-simd`). With `FecMode::Adaptive` it's
     on while loss was seen in the last 10 s or the round trip is over a quarter of a frame interval: 5–25% of each
     frame's data packets (5% + twice the loss rate), at least one parity packet. The loss rate counts NACKed packets
     and one packet per frame that parity repaired, so FEC doesn't hide the loss that keeps it on: counting NACKs only,
     N7's 5% loss read as 0.5% once parity repaired most of it, and the next NACK round trips (100 ms) halved its frame
     rate in the sim.
  3. Give up `max(RTT + 2 ms, 1.5 frame intervals)` after the first NACK, or after the frame's last packet if that's
     later, and tell the host (`Event::FrameLost`): its next encode of that stream should be an LTR refresh. A frame
     still arriving isn't lost: in Tier 1 (run 41701359340, N6 and N7) a keyframe of several hundred KB was given up
     while it arrived, and with no acknowledged reference the host answered with another keyframe, which went the same
     way (scroll N6: 11 frames sent in 40 s, all keyframes, all lost).
     Neither end gives a frame up while it can still arrive (851-4477), within bounds. The viewer's wait for a frame
     it has asked for is at least the time the frame's missing packets take at the pace its own first-time packets
     came at (its patience, at most 5 s, `MAX_CROSSING`: a 190 KB keyframe at the 300 kbit/s floor); a frame with
     fewer than two first-time packets has no pace and gets the plain give-up time. While media
     packets of any frame keep arriving back to back (no gap longer than eight times the pace packets of one frame
     have been arriving at, or than the tail wait, which follows the longest gap seen inside a frame), the wait doesn't run out either: a link delivering back to back has a
     queue, and a resend waits behind whatever the host sent before the request. A link with gaps has nothing
     queued ahead of the resend, so other traffic doesn't hold the frame: with 60 fps video on four tiles at
     50 Mbit/s, counting any packet kept a packet that never arrived waiting 218 ms after its request in the sim,
     against a 53 ms give-up time, with the stream's later frames held behind it; back to back it is 66 ms (the
     tiles' frames take 13 ms to come through). Copies the viewer already has count too: the host's probes are
     queued ahead of its resends, and with only new packets counted the sim's viewer gave a keyframe up during the
     100 ms in which twelve probe copies arrived just before its 130 resends. That extra wait ends four times the
     patience after the frame's last packet, or after the time 512 packets take at that pace if that is longer,
     again at most 5 s; on 1 Mbit/s it is the 5 s, so a keyframe missing two packets is still there when their
     resends come through behind two more tiles' keyframes (it was given up 0.5 s after its last packet). The host counts a NACK that names a packet it wasn't asked
     for before as an answer: its probe count starts again and the frame gets the time everything then waiting needs
     to cross. A repeat counts too when the host sends that packet again, or while it is holding
     the packet's resend behind a deep queue (below): either way the viewer is still waiting for the frame. Without
     the first, a frame whose repeats the host kept sending still used up its six probes while the viewer was
     asking, and was given up; without the second, a frame on 1 Mbit/s with four keyframes in the queue
     was given up by the host while its resends were on their way. A repeat the host skips because its resend left
     under half a round trip ago doesn't count. A packet that never gets through still ends in a lost frame: the
     viewer gives its frame up within its bounds above and says so. When the sixth unanswered probe goes out, the host fixes how long it still waits: until what was in
     flight could have crossed at the rate the viewer acknowledged over the last 0.5 s (300 kbit/s with no
     acknowledgement in that time, never over the estimate, at most 5 s), counted from the frame's last packet or
     the viewer's last answer, whichever is later. Before, the viewer gave a frame up one
     round trip after its last packet, and the host's probes were spaced by a round trip measured before the queue
     built up: a 190 KB first keyframe on a 1 Mbit/s link was declared lost after 1.7 s, about when its last packets
     arrived, and with no acknowledged reference the host answered with a second, larger keyframe (Tier 1 lab run
     45764155233, scroll and video on N7: 417–455 KB and 1.25 MB). What discards the packets in the first place is
     below this crate: the viewer's QUIC logs "failed to authenticate packet" and "discarding possible duplicate
     packet" for them while the connection has more than one path.
     The host also stops answering a repeated request while its last resend of that packet is still behind a deep
     queue (851-4477). It used to resend whenever the last one had left more than half a round trip ago, and the
     viewer repeats a request every round trip, both read from QUIC, whose figure stays at the path's delay while a
     slow link's queue holds seconds: one keyframe's 130 missing packets were resent 1,268 times in the sim, and the
     longer waits above would only add to that. The host now gives everything it sends a place in one byte count and
     follows how far into it the viewer has got (`Arrived`). A sighting is a request that names a packet for the
     first time right after one it never asked for (that one arrived), or a completed frame; a packet the viewer
     asked for before the host had sent it was a guess and is never taken as arrived. Between sightings the reach
     moves on at the rate they advanced over the last 0.5 s, or at the estimate once the link has been measured if
     that is higher. A packet still asked for after a sighting has passed it is lost and took no link time, so it
     comes off what that sighting carried and a burst of loss doesn't make the link look faster; one asked for
     ahead of the reach may only be late and counts for nothing. Sightings under 5 ms apart give no rate, and
     neither does the first one after an idle spell, which starts the count again one lowest round trip after the
     frame's first packet left (or at the first sighting, if that comes sooner). An idle spell is one where no frame
     is in flight and, once the link has been measured, the reach has passed everything sent. With nothing in flight
     but the reach still short (fresh resends, trailing parity, or a given-up frame's packets still queued), the
     count carries on with what it has seen and what is known lost. Before the link is measured it starts again
     regardless: sightings across app-limited gaps understate the rate, so their reach always looks short. A resend that leaves with more
     than four round trips' worth of queue ahead of it (four frame intervals if that is longer) isn't sent again
     until the reach has passed it, at most 5 s; a request that still names it then means it was lost, and it goes
     out at once. Every other resend keeps the half-round-trip rule, and so does every resend while there is no
     rate: there a second copy costs little and repairs a resend that was itself lost a round trip sooner. So a
     wrong rate costs either some of the old repeats (too high, which is the side the loss count errs on: losses
     that parity made up for are never asked for again and stay uncounted) or a later repair of a resend that was
     lost (too low), never a packet that isn't sent. In the sim the keyframe above now has its 130 packets resent
     175 times. Steady streams on N7 never have that much queued, so nothing changes there (32 seeds of 20 s, and 16
     tiles for 40 s: the same frames and estimates as with the old rule, where holding every resend, deep or not,
     cost about 1% of the frames), and a packet lost twice on a fast link is repaired at the viewer's next request
     as before (7 ms on N1). A probe is not a resend the viewer asked for: the viewer's first request for a probed
     packet counts as an answer and as a loss, once, whether or not the probe's copy makes another one unnecessary,
     and a probe for a frame the viewer has already answered doesn't back the next frame's tail probe off.
  4. **Refresh requests.** A frame the transport delivered can still fail to decode, and the transport can't see
     that. The viewer calls `request_refresh(stream, keyframe)`, and the host gets `Event::RefreshRequested` once
     per request. The viewer repeats the request every give-up time + RTT until a recovery frame arrives on that
     stream: a frame sent with `refresh` or `keyframe` settles a refresh request, and only a keyframe settles a
     keyframe request. A keyframe request replaces an open refresh request; another refresh request while one is
     open changes nothing. A request stops after 50 sends, and the host ignores requests for streams it never sent. The host ignores repeats while its answer is on the way, and raises the event again
     only when a repeat says the viewer has resolved the answer (`resolved_below` past the answer's frame) and
     still asks: the answer was lost or didn't help.
- **In-order delivery per stream, without waiting across streams.** A complete frame is delivered at once unless its
  predecessor in the same stream is still being repaired.
- **Per-frame feedback.** The viewer reports every frame it resolves, with its receive times, the stream's recent
  losses, and the newest LTR token its decoder acknowledged. The host turns these into events, a capacity estimate
  and the encoder's admission signal.
- **Delivery at idle.** The host keeps each frame until it hears about it and re-sends its last data packet when an
  ack is overdue, so a lost last frame before idle is repaired instead of never. The newest frame of each stream gets
  a tail-loss probe first, as soon as its ack is late: the viewer reports a complete frame at once, so the probe waits
  for the smoothed delay from a frame's last packet to its ack plus twice that delay's variation, at least 1 ms (the
  round trip + 1 ms until there are acks to measure; tokio's timers can add another 1 ms). Only acks of frames that
  weren't probed are measured, and each probe doubles the wait (up to 16×, never past the next probe's time) until an
  unprobed frame's ack arrives, so a path whose delay grows stops being probed spuriously within a few frames. Older frames don't need it:
  the next frame's arrival already shows the viewer a gap. After that, every give-up time + RTT + 1 ms, at most 6
  times in all, before the frame counts as lost. A frame lost whole at idle (one packet, as typing and small tile
  changes are) or a lost ack is then repaired about RTT + 1–2 ms after it would have arrived, instead of about
  1.5 frame intervals + RTT. On loopback with emulated N3, timing the probe from QUIC's round trip alone probed
  293 of 300 idle frames (the emulation adds delay QUIC doesn't see); timing it from the acks probed 46.
- **Capacity estimate** (851-3822). The larger of two rates, capped after a back-off:
  - **bursts:** a 10 s maximum filter over per-frame delivery rates (bytes that arrived the first time, over their
    arrival spread, or over their send spread if that was longer, since a frame can't arrive faster than it left).
    A sample needs 2.4 KB and an arrival spread of at least two jitters, so frames bunched by jitter don't count.
  - **receive rate:** the bytes the viewer acknowledged over the last 0.5 s. It's a floor: the link carried that much.
    With no burst samples, the estimate is the initial rate or the receive rate if higher. Once the viewer receives
    under 75% of what was sent, the link is narrower than the sender and the receive rate wins. Frames that NACK
    repaired give no burst sample: the viewer doesn't count an original that arrived after it was requested, so their
    bytes are too few for their spread. A flooded first keyframe on N5 read as 0.68 Mbit/s and paced the next one at
    0.55 Mbit/s for 15 s (local Tier 1, video N5).
  - **heavy loss:** when more than 10% of a second's data packets are lost (at least 30 sent; each packet counted at
    its first NACK, plus one per frame parity repaired, less the late originals below), the estimate becomes
    `estimate × (1 − loss / 2)` (GCC's rule), but not under
    85% of the receive rate. A short queue like N5's (30 packets, under 10 ms) turns overuse into loss rather than
    delay, and the Tier 1 relay's batched deliveries let burst samples read 35–44 Mbit/s on its 30 Mbit/s link: with
    only the delay detector, local Tier 1 video N5 stalled in 3 of 4 runs, against 0 of 4 with this.
  - **late originals (851-4501):** a request is not a loss when the packet was only late. The viewer notes, per
    frame, the packets it asked for whose first copy arrived within half the session's lowest round trip of the
    request (too soon for the resend), and reports them with the frame's receipt as up to eight index ranges. The
    host takes back off the loss window only those it charged as first losses in the current window, so a packet it
    never charged (not sent yet, or named in a request that was lost) can't cancel a real loss, and a window doesn't
    pay for another window's take-back. The take-back runs before the window can roll, and when a window ends while a
    frame whose losses it counted could still answer (one round trip and two frame intervals), it waits up to that
    long before deciding. On the 50 Mbit/s lab network (25 ms ± 5) a pause in arrivals during a
    large frame made the viewer ask for 30–170 packets still on their way; the window read 13–32% on a link that lost
    0.1%, the cut threw the measured rate away and the estimate fell to the next small sample, about 3 Mbit/s, for the
    rest of the run (16 traced local runs, 5 of 8 collapsed on main). The count only misses late originals (a copy
    later than that counts as the resend), so it can hide a real loss only if the round trip falls below half its
    session low. A taken-back packet also comes off the estimator's lost bytes, and when every loss of the frame that
    last set the FEC trigger is taken back, the trigger goes back to what it was before. The frame's last packet isn't
    charged when a tail probe's copy of it is on its way, since that copy can arrive early. A frame resolved by a later
    frame's report keeps what it was charged until its own report arrives. Feedback naming more than eight ranges keeps
    the first eight, and feedback cut short inside them keeps none, rather than being dropped. An older viewer sends no
    ranges and the host counts as before; an older host ignores the flag and the bytes after it.
  - **back-off:** when frames' first packets keep finding a growing standing queue, at most once per round trip +
    frame interval, the estimate becomes 85% of the receive rate (at most the estimate) and the burst samples are
    cleared. When the receive rate is under half the estimate and the viewer received at least 75% of what was sent
    over the same 0.5 s, the sender isn't filling the link, so the queue isn't its average rate's doing and the
    back-off takes 15% of the estimate instead: in Tier 1 run 41701359340 scroll at N5 needs 2–3 Mbit/s, and
    back-offs to 85% of that took a 30 Mbit/s estimate down to 2.4, after which admission refused a third to half of
    the captures. Sending more than arrives is a narrower link, not a quiet sender, and goes to 85% of what arrived.
    Back-offs are at least min(RTT, 2 × the smallest RTT) + a frame interval apart, so a long queue's inflated RTT
    doesn't hold the next one off for seconds. After a back-off, the next one needs the queue to grow by another
    threshold beyond where it stood then, or to stand above a frame interval + the threshold. Tier 1's one-Mac relay
    holds the first packet's one-way delay about 3.7 ms over its minimum for seconds at a time (PR gate 41758951189,
    scroll N3). That's a standing offset, not a growing queue, but its microsecond creep counted as growth. Backing off
    every hold-off took the estimate to 1–9 Mbit/s on a 1 Gbit/s link in 4 of 6 runs. While capped, the estimate is the cap: an app-limited receive rate doesn't pull it lower. The
    cap doubles every second while the queue stays within a threshold of where it stood at the back-off and feedback
    keeps coming (a quiet spell counts for at most 250 ms, so a pause doesn't hand the next burst a rate nobody
    measured), and goes once it passes the bursts. Growing it by a
    quarter of its starting value per second (PR gate 41735956891) left Tier 1's scroll at N3 near 1 Mbit/s on a
    1 Gbit/s link after the one-Mac relay's own delay spikes, for minutes: 4 of 6 runs froze 6–9 times. In the sim a
    link that narrows to 20 Mbit/s for 2 s is followed down within about 0.6 s and is back at 40 Mbit/s or more within
    about 3 s of the link recovering (the test allows 4 s). Without the cap, the next jitter-compressed burst undid every back-off:
    in the sim N6's estimate ran to 100–1,000 Mbit/s on a 50 Mbit/s link, with seconds of queue.
  - **queue:** the smallest of the last 8 one-way delays, over the 10 s minimum: jitter raises some samples, and a
    standing queue raises all of them (taking the latest sample let 1–2 ms of jitter ratchet the estimate down to
    3–15 Mbit/s in Tier 1 run 41610616589). It counts as a queue above 2 ms + 4 jitters, where the jitter is the
    smoothed size of the delays' second difference, so a steadily growing queue doesn't raise its own threshold. A
    minimum of 8 samples sits about 1.5 standard deviations above a 10 s minimum without any queue, which a fixed 2 ms
    took for a queue on N6 (5 ms of jitter) and backed off until the estimate was gone. Back-offs read the receive
    rate up to now, so a stall doesn't keep an old rate as their floor. Frames repaired by NACK or FEC count too,
    except NACK-repaired frames of one or two packets, whose first arrival may be the resend (a lost first packet makes a sample a little late, which the minimum of 8 absorbs); without them N5,
    where most frames lose a packet to the short queue, had no samples at all. Probed frames don't count.
  - The estimate never goes under 300 kbit/s.
- **Admission.** Encode the next capture only while the bytes waiting fit one frame interval at the estimate.
  "Measured" means a burst sample or a receive rate exists; a delay sample alone isn't one. Waiting
  bytes are the pacer's backlog plus the bytes in flight beyond what the path holds at the estimate for the smallest
  round trip of the last 10 s plus two frame intervals; before the first delivery is measured, every byte in flight
  waits. So the queue in the network counts too: before this, N7 (1 Mbit/s) took a whole 45 Mbit/s second into its
  unlimited queue before the first ack, and every frame after that arrived too late to repair. The encoder ceiling is
  85% of the estimate over 1 + the FEC ratio, since parity shares the link.
- **Tier 1 runs cited above, before 851-4477.** Until 851-4477 the bench's one-Mac relay delivered a delayed packet
  only when the next packet in either direction reached it (its timer never fired; see "Delivery on time" in
  `apps/screen-sharing-bench/README.md`). Every Tier 1 run this file cites on a network with a delay went through
  that relay, and its "standing offset", "batched deliveries" and clumped arrivals were that bug. The rules those
  runs led to are unchanged.
- **Constrained links in the sim** (`tests/core.rs`: a 60 Hz scene whose encoder follows the ceiling every 250 ms,
  with frames sized for one interval or for all the time since the last encode, 30 s after 5 s of warm-up, seeds
  1–3): N5 keeps 55–60 frames a second at a p50 of 23–25 ms and p95 under 32 ms (RTT 20 ms), with the estimate at
  30 Mbit/s; N6 keeps 58–60 at 49–51 ms, p95 67–76 ms (RTT 50 ms); N7 keeps 54 at 88 ms, p95 118–131 ms, with
  one-interval frames (RTT 100 ms, encoder at its 200 kbit/s minimum). When every frame carries the time since the
  last encode, N7 keeps 20–23 frames a second at 109–128 ms once started; its first measured seconds sit at
  0.8–1.4 s while the estimate is still measured one frame at a time. N0 and N3 are unchanged. Before: N5 gave up 90% of its frames, N6's age grew to 6 s, and N7 delivered
  almost nothing.

## Using it

`MediaSession` runs one end over a transport:

- The host calls `send_frame` once per encoded tile, and checks `admission()` before encoding the next capture.
  `send_frame` borrows the frame and only packetizes and queues it, so the encoder's buffer is free on return; the
  session's task sends, receives and runs the timers.
- The viewer takes `Event::Frame`s from `next_event`, decodes them, and calls `ack_ltr` for frames that carried an LTR
  token.
- The host gets `Event::FrameAcked`, `Event::FrameLost`, `Event::LtrAcked` and `Event::RefreshRequested` from the
  same `next_event`. The viewer also gets `Event::FrameSkipped` when the transport gave up on a frame, and calls
  `request_refresh` when a delivered frame doesn't decode.
- `OutgoingFrame::refresh` marks a frame that answers a loss (an LTR refresh); keyframes answer one too.
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
  try session.sendFrame(stream: tile, keyframe: false, refresh: false, ltrToken: token, meta: timings, data: accessUnit)
}
while let event = await session.nextEvent() {
  if case .frame(let stream, _, _, _, let ltrToken, _, let bytes, _, _) = event {
    if bytes.withUnsafeBytes({ decode($0) }) {
      if let ltrToken { session.ackLtr(stream: stream, token: ltrToken) }
    } else {
      session.requestRefresh(stream: stream, keyframe: false)
    }
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
endian. Kind 5 is audio and kind 6 is cursor: an app datagram is the first byte, a stream byte (0), then the payload,
which the session neither paces nor repairs (`MediaSession::send_datagram` sends it straight to the transport and
drops it when the transport is full or the path's datagram is too small; the receiver hands it up as
`Event::Datagram`). The product sends Opus packets and cursor positions this way (851-3823).

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
are that long. The payload itself is a flags byte (1 keyframe, 2 LTR token present, 4 refresh), the optional LTR token
(u64), the metadata length (u16) and metadata, then the access unit.

Feedback (kind 2, viewer to host), one per resolved frame and per LTR acknowledgement:

| Bytes  | Field                                                                                                                                                     |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2..6   | the frame reported on (`u32::MAX` for none)                                                                                                               |
| 6      | flags: 1 lost, 2 receipt present, 4 LTR token present, 8 late originals present                                                                           |
| 7      | recovery of the reported frame: 0 none, 1 FEC, 2 NACK                                                                                                     |
| 8..12  | `resolved_below`: every earlier frame is delivered or given up                                                                                            |
| 12..16 | lost bitmap: bit `i` set means frame `resolved_below - 1 - i` was given up                                                                                |
| 16..36 | receipt: first arrival (u64 µs), last first-time arrival and completion (u32 µs after it), bytes that arrived the first time after the first packet (u32) |
| 36..44 | the newest LTR token the viewer's decoder acknowledged on this stream (optional)                                                                          |
| then   | late originals (optional): a range count (u8, at most 8 kept), then `(first index, count)` pairs of u16                                                   |

NACK (kind 3): the frame (u32), a range count (u16, at most 64), then `(first index, count)` pairs of u16. A count of
`0xFFFF` asks for every data packet of a frame the viewer never saw.

Refresh request (kind 4, viewer to host), 9 bytes: the request number (u16, per stream, the same in every repeat of
one request), a flags byte (1 keyframe) and `resolved_below` (u32), as in feedback.

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

Rows 6 and 7 send one small frame (1 and 4 packets) every 100 ms, as typing does. For them the "acks later than
RTT+2 ms over the floor" column counts frames whose ack came more than RTT + 2 ms later than the fastest clean round
trip, timed from the frame's last packet out: at idle that is a loss, or a lost ack, that took longer than a
tail-loss probe to repair. It is 0 for the other rows.

Two-Mac runs go through the signed `CodevisorBench.app`, which calls `bench::run` in-process (`media_bench_run`),
because macOS Local Network privacy drops LAN UDP from unsigned binaries run by the CI runner.

## Not yet

The control plane rides reliable QUIC streams on the same connection, outside this crate (see `ScreenSharingV2`'s
`Session/` in `packages/swift/ScreenSharing`).
