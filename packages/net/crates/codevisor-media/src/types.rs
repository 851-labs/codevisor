use std::time::{Duration, Instant};

use bytes::Bytes;

pub use crate::wire::Recovery;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MediaConfig {
    pub frame_interval: Duration,
    pub fec: FecMode,
    pub initial_rate_bps: f64,
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
    Adaptive,
    Off,
    Fixed(f64),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OutgoingFrame<'a> {
    pub stream: u8,
    pub keyframe: bool,
    pub ltr_token: Option<u64>,
    pub meta: &'a [u8],
    pub data: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendError {
    NoDatagrams,
    PathTooSmall,
    MetaTooLarge,
    FrameTooLarge,
}

impl std::fmt::Display for SendError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::NoDatagrams => "the connection doesn't carry datagrams",
            Self::PathTooSmall => "the path's datagrams can't hold a media header",
            Self::MetaTooLarge => "frame metadata is over 64 KiB",
            Self::FrameTooLarge => "the frame needs more than 65 535 packets",
        })
    }
}

impl std::error::Error for SendError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Frame(ReceivedFrame),
    FrameSkipped { stream: u8, frame: u32 },
    FrameAcked(FrameAck),
    FrameLost { stream: u8, frame: u32 },
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
    pub first_packet_at: Instant,
    pub completed_at: Instant,
    pub recovery: Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameAck {
    pub stream: u8,
    pub frame: u32,
    pub queued: Duration,
    pub sending: Duration,
    pub acked_after: Duration,
    pub receipt: Option<Receipt>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Receipt {
    pub arriving: Duration,
    pub assembling: Duration,
    pub recovery: Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Admission {
    pub admit: bool,
    pub backlog_bytes: usize,
    pub budget_bytes: usize,
    pub estimate_bps: f64,
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

pub fn give_up_after(rtt: Duration, frame_interval: Duration) -> Duration {
    (rtt + Duration::from_millis(2)).max(frame_interval.mul_f64(1.5))
}
