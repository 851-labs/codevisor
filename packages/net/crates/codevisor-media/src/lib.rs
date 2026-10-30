//! `codevisor-media`: the screen sharing v2 media transport (851-3815, the HP-class engine design's §3.3).
//!
//! It carries encoded video frames from the host to the viewer over QUIC datagrams on an iroh connection
//! (ALPN [`ALPN_SCREEN`]), with no jitter buffer and no queue deeper than one frame:
//!
//! * **Framing and packetizing.** Each frame (one tile's access unit plus a few transport fields) is cut into
//!   balanced packets that fit the path's current datagram size, each with a 16-byte header ([`wire`]).
//! * **Frame-spread pacing.** A frame's packets leave at twice the capacity estimate, and never take longer than
//!   half a frame interval, so a keyframe doesn't hit the wire at line rate.
//! * **Loss recovery,** cheapest first: NACK as soon as a gap shows; Reed–Solomon parity when loss has been seen in
//!   the last 10 s or the round trip is too long for NACK ([`FecMode::Adaptive`]); then give up after
//!   `max(RTT + 2 ms, 1.5 frame intervals)` and tell the host, whose next encode of that stream should be an LTR
//!   refresh ([`Event::FrameLost`]).
//! * **In-order delivery per stream, without waiting across streams.** A complete frame is delivered at once
//!   unless its predecessor in the same stream is still being repaired.
//! * **Per-frame feedback.** The viewer reports every frame it resolves, with its receive times, the stream's
//!   recent losses and the newest LTR token its decoder acknowledged; the host turns them into events, a capacity
//!   estimate and the encoder's [`Admission`] signal.
//! * **Delivery at idle.** The host keeps each frame until it hears about it, and probes when an ack is overdue,
//!   so a lost last frame before idle is repaired within a round trip of the probe instead of never.
//!
//! # Using it
//!
//! [`MediaSession`] runs one end over a connection: the host calls [`MediaSession::send_frame`] once per encoded
//! tile and checks [`MediaSession::admission`] before encoding the next capture; the viewer takes
//! [`Event::Frame`]s from [`MediaSession::next_event`], decodes them, and calls [`MediaSession::ack_ltr`] for frames
//! that carried an LTR token. The host gets [`Event::FrameAcked`], [`Event::FrameLost`] and [`Event::LtrAcked`] from
//! the same call. Swift reaches all of this through `codevisor-net-ffi` (`NetConnectionHandle.openMediaSession`).
//!
//! [`Core`] is the same transport as a state machine without I/O or a clock, which is what the deterministic tests
//! drive over [`netsim`]'s seeded network model.

pub mod bench;
mod core;
mod estimator;
pub mod fec;
pub mod netsim;
mod pacer;
mod receiver;
mod sender;
mod session;
mod transport;
mod types;
pub mod wire;

pub use crate::{
    core::Core,
    session::MediaSession,
    transport::{DatagramTransport, ImpairedTransport, QuicTransport, SendOutcome, UdpTransport},
    types::{
        Admission, Event, FecMode, FrameAck, MediaConfig, OutgoingFrame, Receipt, ReceivedFrame, Recovery, Stats,
        give_up_after,
    },
};

/// The ALPN of a screen sharing connection; its datagrams belong to one [`MediaSession`].
pub const ALPN_SCREEN: &[u8] = b"codevisor/screen/1";
