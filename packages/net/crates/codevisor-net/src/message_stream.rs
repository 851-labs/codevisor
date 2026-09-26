//! A message-oriented pipe over one QUIC bidirectional stream.
//!
//! The existing cloud channel protocol is message-based (it ran over
//! WebSockets: text control frames + binary envelope batches), so the tunnel
//! carries it unchanged as length-prefixed messages:
//!
//! ```text
//! [kind: u8 (0 = text, 1 = binary)] [length: u32 BE] [payload]
//! ```

use anyhow::{Result, bail};
use iroh::endpoint::{ReadExactError, RecvStream, SendStream};
use tokio::sync::Mutex;

/// Upper bound for one message. The cloud protocol caps a relay message at
/// 2 MiB (`MAX_RELAY_MESSAGE_BYTES`); leave headroom, refuse anything absurd.
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageKind {
    Text = 0,
    Binary = 1,
}

impl MessageKind {
    fn from_byte(byte: u8) -> Result<Self> {
        match byte {
            0 => Ok(Self::Text),
            1 => Ok(Self::Binary),
            other => bail!("unknown message kind {other}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub kind: MessageKind,
    pub payload: Vec<u8>,
}

/// Encodes one frame header. Split out so the framing is unit-testable
/// without a QUIC connection.
pub fn encode_header(kind: MessageKind, len: usize) -> Result<[u8; 5]> {
    if len > MAX_MESSAGE_BYTES {
        bail!("message of {len} bytes exceeds the {MAX_MESSAGE_BYTES}-byte limit");
    }
    let mut header = [0u8; 5];
    header[0] = kind as u8;
    header[1..].copy_from_slice(&(len as u32).to_be_bytes());
    Ok(header)
}

pub fn decode_header(header: [u8; 5]) -> Result<(MessageKind, usize)> {
    let kind = MessageKind::from_byte(header[0])?;
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_MESSAGE_BYTES {
        bail!("peer sent a {len}-byte message, over the {MAX_MESSAGE_BYTES}-byte limit");
    }
    Ok((kind, len))
}

pub struct MessageStream {
    send: Mutex<SendStream>,
    recv: Mutex<RecvStream>,
}

impl MessageStream {
    pub fn new(send: SendStream, recv: RecvStream) -> Self {
        Self { send: Mutex::new(send), recv: Mutex::new(recv) }
    }

    /// Writes one message. Concurrent callers are serialized so frames never
    /// interleave.
    pub async fn send(&self, kind: MessageKind, payload: &[u8]) -> Result<()> {
        let header = encode_header(kind, payload.len())?;
        let mut send = self.send.lock().await;
        send.write_all(&header).await?;
        send.write_all(payload).await?;
        Ok(())
    }

    /// Reads the next message; `None` when the peer finished the stream
    /// cleanly between messages.
    pub async fn recv(&self) -> Result<Option<Message>> {
        let mut recv = self.recv.lock().await;
        let mut header = [0u8; 5];
        match recv.read_exact(&mut header).await {
            Ok(()) => {}
            Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
            Err(error) => return Err(error.into()),
        }
        let (kind, len) = decode_header(header)?;
        let mut payload = vec![0u8; len];
        recv.read_exact(&mut payload).await?;
        Ok(Some(Message { kind, payload }))
    }

    /// Gracefully ends our sending half; the peer's `recv` returns `None`.
    pub async fn finish(&self) -> Result<()> {
        self.send.lock().await.finish()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_round_trips_kind_and_length() {
        let header = encode_header(MessageKind::Binary, 70_000).unwrap();
        assert_eq!(decode_header(header).unwrap(), (MessageKind::Binary, 70_000));
        let header = encode_header(MessageKind::Text, 0).unwrap();
        assert_eq!(decode_header(header).unwrap(), (MessageKind::Text, 0));
    }

    #[test]
    fn refuses_oversized_and_unknown_frames() {
        assert!(encode_header(MessageKind::Binary, MAX_MESSAGE_BYTES + 1).is_err());
        let mut header = encode_header(MessageKind::Binary, 1).unwrap();
        header[1..].copy_from_slice(&((MAX_MESSAGE_BYTES as u32) + 1).to_be_bytes());
        assert!(decode_header(header).is_err());
        header[0] = 9;
        assert!(decode_header(header).is_err());
    }
}
