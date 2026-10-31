pub mod config;
pub mod endpoint;
pub mod media;
pub mod message_stream;
pub mod screen_transport;

pub use config::{NetConfig, PathPolicy, RelaySpec, secret_key_from_hex};
pub use endpoint::{CancelToken, DatagramSendError, NetAddr, NetConnection, NetEndpoint, PathInfo, endpoint_id_for, generate_secret_key};
pub use media::{DatagramRouter, MediaFlow, MediaStats};
pub use message_stream::{MAX_MESSAGE_BYTES, Message, MessageKind, MessageStream};

pub const ALPN_CHANNELS: &[u8] = b"codevisor/channels/1";
pub const ALPN_MEDIA: &[u8] = b"codevisor/media/1";
pub const ALPN_SCREEN: &[u8] = b"codevisor/screen/1";
