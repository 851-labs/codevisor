use bytes::{BufMut, Bytes, BytesMut};

pub const VERSION: u8 = 1;
pub const HEADER_BYTES: usize = 16;
pub const WHOLE_FRAME: u16 = u16::MAX;
pub const NO_FRAME: u32 = u32::MAX;
const FEEDBACK_BYTES: usize = 36;
const LTR_BYTES: usize = 8;
const MAX_NACK_RANGES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Data = 0,
    Parity = 1,
    Feedback = 2,
    Nack = 3,
}

impl Kind {
    fn from_nibble(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Data),
            1 => Some(Self::Parity),
            2 => Some(Self::Feedback),
            3 => Some(Self::Nack),
            _ => None,
        }
    }
}

fn first_byte(kind: Kind) -> u8 {
    VERSION << 4 | kind as u8
}

pub fn kind_of(datagram: &[u8]) -> Option<Kind> {
    let first = *datagram.first()?;
    if first >> 4 != VERSION {
        return None;
    }
    Kind::from_nibble(first & 0x0F)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketHeader {
    pub kind: Kind,
    pub stream: u8,
    pub frame: u32,
    pub index: u16,
    pub data_count: u16,
    pub parity_count: u16,
    pub frame_len: u32,
}

impl PacketHeader {
    pub fn encode(&self, shard: &[u8]) -> Bytes {
        let mut out = BytesMut::with_capacity(HEADER_BYTES + shard.len());
        out.put_u8(first_byte(self.kind));
        out.put_u8(self.stream);
        out.put_u32(self.frame);
        out.put_u16(self.index);
        out.put_u16(self.data_count);
        out.put_u16(self.parity_count);
        out.put_u32(self.frame_len);
        out.put_slice(shard);
        out.freeze()
    }

    pub fn decode(mut datagram: Bytes) -> Option<(Self, Bytes)> {
        let kind = kind_of(&datagram)?;
        if !matches!(kind, Kind::Data | Kind::Parity) || datagram.len() < HEADER_BYTES {
            return None;
        }
        let header = datagram.split_to(HEADER_BYTES);
        let header = Self {
            kind,
            stream: header[1],
            frame: u32::from_be_bytes(header[2..6].try_into().ok()?),
            index: u16::from_be_bytes(header[6..8].try_into().ok()?),
            data_count: u16::from_be_bytes(header[8..10].try_into().ok()?),
            parity_count: u16::from_be_bytes(header[10..12].try_into().ok()?),
            frame_len: u32::from_be_bytes(header[12..16].try_into().ok()?),
        };
        let valid = header.data_count > 0
            && header.frame_len > 0
            && header.index < header.data_count.saturating_add(header.parity_count)
            && (header.kind == Kind::Data) == (header.index < header.data_count);
        valid.then_some((header, datagram))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Recovery {
    #[default]
    None,
    Fec,
    Nack,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameReceipt {
    pub first_rx_us: u64,
    pub last_rx_offset_us: u32,
    pub complete_offset_us: u32,
    pub original_bytes: u32,
    pub recovery: Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Feedback {
    pub stream: u8,
    pub frame: u32,
    pub lost: bool,
    pub receipt: Option<FrameReceipt>,
    pub resolved_below: u32,
    pub lost_bitmap: u32,
    pub ltr_token: Option<u64>,
}

const FLAG_LOST: u8 = 1;
const FLAG_RECEIPT: u8 = 2;
const FLAG_LTR: u8 = 4;

impl Feedback {
    pub fn encode(&self) -> Bytes {
        let mut out = BytesMut::with_capacity(FEEDBACK_BYTES + LTR_BYTES);
        out.put_u8(first_byte(Kind::Feedback));
        out.put_u8(self.stream);
        out.put_u32(self.frame);
        let mut flags = 0;
        if self.lost {
            flags |= FLAG_LOST;
        }
        if self.receipt.is_some() {
            flags |= FLAG_RECEIPT;
        }
        if self.ltr_token.is_some() {
            flags |= FLAG_LTR;
        }
        out.put_u8(flags);
        out.put_u8(match self.receipt.map(|receipt| receipt.recovery) {
            None | Some(Recovery::None) => 0,
            Some(Recovery::Fec) => 1,
            Some(Recovery::Nack) => 2,
        });
        out.put_u32(self.resolved_below);
        out.put_u32(self.lost_bitmap);
        let receipt = self.receipt.unwrap_or(FrameReceipt {
            first_rx_us: 0,
            last_rx_offset_us: 0,
            complete_offset_us: 0,
            original_bytes: 0,
            recovery: Recovery::None,
        });
        out.put_u64(receipt.first_rx_us);
        out.put_u32(receipt.last_rx_offset_us);
        out.put_u32(receipt.complete_offset_us);
        out.put_u32(receipt.original_bytes);
        if let Some(token) = self.ltr_token {
            out.put_u64(token);
        }
        out.freeze()
    }

    pub fn decode(datagram: &[u8]) -> Option<Self> {
        if kind_of(datagram)? != Kind::Feedback || datagram.len() < FEEDBACK_BYTES {
            return None;
        }
        let u32_at = |at: usize| u32::from_be_bytes(datagram[at..at + 4].try_into().unwrap());
        let u64_at = |at: usize| u64::from_be_bytes(datagram[at..at + 8].try_into().unwrap());
        let flags = datagram[6];
        let recovery = match datagram[7] {
            1 => Recovery::Fec,
            2 => Recovery::Nack,
            _ => Recovery::None,
        };
        let ltr_token = if flags & FLAG_LTR != 0 {
            if datagram.len() < FEEDBACK_BYTES + LTR_BYTES {
                return None;
            }
            Some(u64_at(FEEDBACK_BYTES))
        } else {
            None
        };
        Some(Self {
            stream: datagram[1],
            frame: u32_at(2),
            lost: flags & FLAG_LOST != 0,
            receipt: (flags & FLAG_RECEIPT != 0).then(|| FrameReceipt {
                first_rx_us: u64_at(16),
                last_rx_offset_us: u32_at(24),
                complete_offset_us: u32_at(28),
                original_bytes: u32_at(32),
                recovery,
            }),
            resolved_below: u32_at(8),
            lost_bitmap: u32_at(12),
            ltr_token,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nack {
    pub stream: u8,
    pub frame: u32,
    pub ranges: Vec<(u16, u16)>,
}

impl Nack {
    pub fn from_indices(stream: u8, frame: u32, indices: impl IntoIterator<Item = u16>) -> Self {
        let mut ranges: Vec<(u16, u16)> = Vec::new();
        for index in indices {
            if let Some((start, count)) = ranges.last_mut()
                && u32::from(*start) + u32::from(*count) == u32::from(index)
            {
                *count += 1;
            } else if ranges.len() == MAX_NACK_RANGES {
                break;
            } else {
                ranges.push((index, 1));
            }
        }
        Self { stream, frame, ranges }
    }

    pub fn whole_frame(stream: u8, frame: u32) -> Self {
        Self { stream, frame, ranges: vec![(0, WHOLE_FRAME)] }
    }

    pub fn encode(&self) -> Bytes {
        let mut out = BytesMut::with_capacity(8 + self.ranges.len() * 4);
        out.put_u8(first_byte(Kind::Nack));
        out.put_u8(self.stream);
        out.put_u32(self.frame);
        out.put_u16(self.ranges.len() as u16);
        for (start, count) in &self.ranges {
            out.put_u16(*start);
            out.put_u16(*count);
        }
        out.freeze()
    }

    pub fn decode(datagram: &[u8]) -> Option<Self> {
        if kind_of(datagram)? != Kind::Nack || datagram.len() < 8 {
            return None;
        }
        let count = usize::from(u16::from_be_bytes([datagram[6], datagram[7]]));
        if count > MAX_NACK_RANGES || datagram.len() < 8 + count * 4 {
            return None;
        }
        let ranges = datagram[8..8 + count * 4]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|range| (u16::from_be_bytes([range[0], range[1]]), u16::from_be_bytes([range[2], range[3]])))
            .collect();
        Some(Self { stream: datagram[1], frame: u32::from_be_bytes(datagram[2..6].try_into().unwrap()), ranges })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FrameFields {
    pub keyframe: bool,
    pub ltr_token: Option<u64>,
    pub meta: Vec<u8>,
}

pub const MAX_META_BYTES: usize = u16::MAX as usize;

impl FrameFields {
    pub fn prefix_len(&self) -> usize {
        1 + if self.ltr_token.is_some() { 8 } else { 0 } + 2 + self.meta.len()
    }

    pub fn payload(&self, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.prefix_len() + data.len());
        out.push(u8::from(self.keyframe) | if self.ltr_token.is_some() { 2 } else { 0 });
        if let Some(token) = self.ltr_token {
            out.extend_from_slice(&token.to_be_bytes());
        }
        out.extend_from_slice(&(self.meta.len() as u16).to_be_bytes());
        out.extend_from_slice(&self.meta);
        out.extend_from_slice(data);
        out
    }

    pub fn parse(mut payload: Bytes) -> Option<(Self, Bytes)> {
        let flags = *payload.first()?;
        let mut at = 1;
        let ltr_token = if flags & 2 != 0 {
            let token = u64::from_be_bytes(payload.get(at..at + 8)?.try_into().ok()?);
            at += 8;
            Some(token)
        } else {
            None
        };
        let meta_len = usize::from(u16::from_be_bytes(payload.get(at..at + 2)?.try_into().ok()?));
        at += 2;
        let meta = payload.get(at..at + meta_len)?.to_vec();
        let data = payload.split_off(at + meta_len);
        Some((Self { keyframe: flags & 1 != 0, ltr_token, meta }, data))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_header_layout_is_the_documented_sixteen_bytes() {
        let header = PacketHeader {
            kind: Kind::Parity,
            stream: 3,
            frame: 0x0102_0304,
            index: 7,
            data_count: 5,
            parity_count: 3,
            frame_len: 0x0A0B_0C0D,
        };
        let packet = header.encode(b"xy");
        assert_eq!(&packet[..], &[0x11, 3, 1, 2, 3, 4, 0, 7, 0, 5, 0, 3, 0x0A, 0x0B, 0x0C, 0x0D, b'x', b'y']);
        assert_eq!(PacketHeader::decode(packet), Some((header, Bytes::from_static(b"xy"))));
    }

    #[test]
    fn rejects_media_headers_that_contradict_themselves() {
        let base = PacketHeader {
            kind: Kind::Data,
            stream: 0,
            frame: 0,
            index: 0,
            data_count: 2,
            parity_count: 1,
            frame_len: 10,
        };
        for header in [
            PacketHeader { index: 2, ..base },
            PacketHeader { kind: Kind::Parity, index: 1, ..base },
            PacketHeader { index: 3, kind: Kind::Parity, ..base },
            PacketHeader { data_count: 0, ..base },
            PacketHeader { frame_len: 0, ..base },
        ] {
            assert_eq!(PacketHeader::decode(header.encode(b"")), None, "{header:?}");
        }
        let mut other_version = base.encode(b"").to_vec();
        other_version[0] = 0x20;
        assert_eq!(PacketHeader::decode(Bytes::from(other_version)), None);
    }

    #[test]
    fn feedback_carries_receipt_history_and_ltr_token() {
        let feedback = Feedback {
            stream: 2,
            frame: 41,
            lost: false,
            receipt: Some(FrameReceipt {
                first_rx_us: 1 << 40,
                last_rx_offset_us: 900,
                complete_offset_us: 2100,
                original_bytes: 48_000,
                recovery: Recovery::Nack,
            }),
            resolved_below: 40,
            lost_bitmap: 0b101,
            ltr_token: Some(77),
        };
        let encoded = feedback.encode();
        assert_eq!(encoded.len(), 44);
        assert_eq!(Feedback::decode(&encoded), Some(feedback));

        let lost = Feedback { lost: true, receipt: None, ltr_token: None, ..feedback };
        let encoded = lost.encode();
        assert_eq!(encoded.len(), 36);
        assert_eq!(Feedback::decode(&encoded), Some(lost));
    }

    #[test]
    fn nack_ranges_merge_consecutive_indices() {
        let nack = Nack::from_indices(1, 9, [0, 1, 2, 5, 7, 8]);
        assert_eq!(nack.ranges, vec![(0, 3), (5, 1), (7, 2)]);
        assert_eq!(Nack::decode(&nack.encode()), Some(nack));
    }

    #[test]
    fn frame_fields_round_trip_in_front_of_the_access_unit() {
        let fields = FrameFields { keyframe: true, ltr_token: Some(9), meta: b"timing".to_vec() };
        let payload = fields.payload(b"access unit");
        assert_eq!(payload.len(), fields.prefix_len() + 11);
        let (parsed, data) = FrameFields::parse(Bytes::from(payload)).unwrap();
        assert_eq!(parsed, fields);
        assert_eq!(&data[..], b"access unit");

        let plain = FrameFields::default();
        let (parsed, data) = FrameFields::parse(Bytes::from(plain.payload(b""))).unwrap();
        assert_eq!(parsed, plain);
        assert!(data.is_empty());
    }
}
