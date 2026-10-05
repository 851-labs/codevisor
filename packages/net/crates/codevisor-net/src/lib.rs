//! Codevisor's peer-to-peer tunnel core (see docs/plans/codevisor-tunnel.md).
//!
//! One QUIC connection per device pair over iroh: direct (LAN, tailnet,
//! hole-punched) when possible, through our relays otherwise. Services are
//! selected by ALPN:
//!
//! - [`ALPN_CHANNELS`]: the existing sealed cloud channel protocol, carried as
//!   messages on one bidirectional stream ([`MessageStream`]).
//! - [`ALPN_MEDIA`]: UDP media flows as QUIC datagrams ([`MediaFlow`]).

pub mod config;
pub mod endpoint;
pub mod media;
pub mod message_stream;

pub use config::{NetConfig, PathPolicy, RelaySpec, secret_key_from_hex};
pub use endpoint::{CancelToken, NetAddr, NetConnection, NetEndpoint, PathInfo, endpoint_id_for, generate_secret_key};
pub use media::{DatagramRouter, MediaFlow};
pub use message_stream::{MAX_MESSAGE_BYTES, Message, MessageKind, MessageStream};

pub const ALPN_CHANNELS: &[u8] = b"codevisor/channels/1";
pub const ALPN_MEDIA: &[u8] = b"codevisor/media/1";
