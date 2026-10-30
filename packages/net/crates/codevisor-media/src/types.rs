use std::time::{Duration, Instant};

use bytes::Bytes;

pub use crate::wire::Recovery;

/// Session settings. Both ends of a session should use the same frame interval.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MediaConfig {
    /// The capture cadence. It sets the pacing spread (half an interval), the give-up time (at least 1.5 intervals)
    /// and the admission budget (one interval at the capacity estimate).
    pub frame_interval: Duration,
    pub fec: FecMode,
    /// The capacity estimate before the first delivery is timed.
    pub initial_rate_bps: f64,
    /// The highest the capacity estimate (and so the pacing rate's base) may go.
    pub max_rate_bps: f64,
}

impl Default for MediaConfig {
    fn default() -> Self {
        Self {
            frame_interval: Duration::from_micros(16_667),
            fec: FecMode::Adaptive,
            initial_rate_bps: 100e6,
            max_rate_bps: 2.5e9,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FecMode {
    /// None after 10 s without loss and while the round trip is under a quarter of a frame interval (NACK repairs in
    /// time); otherwise 5–25% of each frame's packets, more as loss rises, and at least one parity packet.
    Adaptive,
    Off,
    /// This fraction of each frame's data packets (rounded up), whatever the network does.
    Fixed(f64),
}

/// One access unit for [`crate::Core::send_frame`], borrowed: the transport copies it once, into its packets, so
/// the encoder's buffer is free again when the call returns.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OutgoingFrame<'a> {
    pub stream: u8,
    pub keyframe: bool,
    /// The VideoToolbox LTR token this frame's encode asked to be acknowledged; the viewer acks it with
    /// [`crate::Core::ack_ltr`] once decoded, and the host gets [`Event::LtrAcked`].
    pub ltr_token: Option<u64>,
    /// Up to 64 KiB the transport carries alongside the frame unchanged (the host's stage timings, for example).
    pub meta: &'a [u8],
    pub data: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Viewer: a complete frame, in order within its stream.
    Frame(ReceivedFrame),
    /// Viewer: the transport gave up on this frame, so the next frame on its stream follows a gap. The host was told
    /// and is expected to refresh the stream.
    FrameSkipped { stream: u8, frame: u32 },
    /// Host: the viewer has this frame.
    FrameAcked(FrameAck),
    /// Host: the viewer gave up on this frame (or never answered for it). Encode the stream's next frame as a refresh.
    FrameLost { stream: u8, frame: u32 },
    /// Host: the viewer decoded the frame that carried this LTR token.
    LtrAcked { stream: u8, token: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceivedFrame {
    pub stream: u8,
    pub frame: u32,
    pub keyframe: bool,
    pub ltr_token: Option<u64>,
    pub meta: Vec<u8>,
    pub data: Bytes,
    /// First packet in.
    pub first_packet_at: Instant,
    /// The last missing packet in (or rebuilt).
    pub completed_at: Instant,
    pub recovery: Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameAck {
    pub stream: u8,
    pub frame: u32,
    /// `send_frame` to the first packet out (time waiting behind earlier frames in the pacer).
    pub queued: Duration,
    /// First to last original packet out: the pacing spread.
    pub sending: Duration,
    /// First packet out to this ack in.
    pub acked_after: Duration,
    /// The viewer's timing. `None` when the ack itself was lost and a later report said the frame arrived.
    pub receipt: Option<Receipt>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Receipt {
    /// First packet in to the last packet that arrived the first time it was sent.
    pub arriving: Duration,
    /// First packet in to complete. Minus [`FrameAck::sending`], what loss recovery cost this frame.
    pub assembling: Duration,
    pub recovery: Recovery,
}

/// Whether the encoder should encode the next capture. Encoded frames are never dropped (later frames reference
/// them), so the pipeline drops captures here instead whenever the link is behind.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Admission {
    /// Bytes waiting to be sent are within one frame interval's budget.
    pub admit: bool,
    pub backlog_bytes: usize,
    pub budget_bytes: usize,
    pub estimate_bps: f64,
    /// The bitrate cap for the encoder: 85% of the estimate.
    pub encoder_ceiling_bps: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Stats {
    pub frames_sent: u64,
    pub frames_acked: u64,
    pub frames_lost: u64,
    pub packets_sent: u64,
    pub bytes_sent: u64,
    pub parity_packets_sent: u64,
    pub packets_retransmitted: u64,
    pub probes_sent: u64,
    pub nacks_received: u64,
    pub transport_rejected: u64,

    pub frames_received: u64,
    pub frames_skipped: u64,
    pub packets_received: u64,
    pub bytes_received: u64,
    pub duplicate_packets: u64,
    pub invalid_datagrams: u64,
    pub fec_recoveries: u64,
    pub nacks_sent: u64,

    pub rtt: Duration,
    pub estimate_bps: f64,
    pub queue_delay_us: i64,
    pub fec_ratio: f64,
    pub loss_rate: f64,
}

/// How long the viewer keeps trying to complete a frame once it noticed packets missing.
pub fn give_up_after(rtt: Duration, frame_interval: Duration) -> Duration {
    (rtt + Duration::from_millis(2)).max(frame_interval.mul_f64(1.5))
}
