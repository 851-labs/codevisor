use anyhow::{Result, anyhow, bail};
use reed_solomon_simd::{ReedSolomonDecoder, ReedSolomonEncoder};

pub const MAX_PACKETS: usize = u16::MAX as usize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    pub frame_len: usize,
    pub data_count: usize,
    pub shard_len: usize,
}

impl Layout {
    pub fn for_payload(frame_len: usize, max_shard: usize) -> Result<Self> {
        let max_shard = max_shard & !1;
        if frame_len == 0 || max_shard == 0 {
            bail!("frame payload ({frame_len} bytes) or packet size ({max_shard} bytes) is empty");
        }
        let data_count = frame_len.div_ceil(max_shard);
        if data_count > MAX_PACKETS {
            bail!(
                "a {frame_len}-byte frame needs {data_count} packets of {max_shard} bytes; the limit is {MAX_PACKETS}"
            );
        }
        Self::new(frame_len, data_count)
    }

    pub fn new(frame_len: usize, data_count: usize) -> Result<Self> {
        if frame_len == 0 || data_count == 0 || data_count > frame_len {
            bail!("no layout splits {frame_len} bytes into {data_count} packets");
        }
        let shard_len = frame_len.div_ceil(data_count).next_multiple_of(2);
        if (data_count - 1) * shard_len >= frame_len {
            bail!("splitting {frame_len} bytes into {data_count} packets leaves the last one empty");
        }
        Ok(Self { frame_len, data_count, shard_len })
    }

    pub fn data_range(&self, index: usize) -> std::ops::Range<usize> {
        let start = (index * self.shard_len).min(self.frame_len);
        start..((index + 1) * self.shard_len).min(self.frame_len)
    }
}

pub fn encode_parity(payload: &[u8], layout: Layout, parity_count: usize) -> Result<Vec<Vec<u8>>> {
    if parity_count == 0 {
        return Ok(Vec::new());
    }
    let mut encoder = ReedSolomonEncoder::new(layout.data_count, parity_count, layout.shard_len)
        .map_err(|error| anyhow!("FEC setup for {layout:?} + {parity_count}: {error}"))?;
    let mut padded = vec![0u8; layout.shard_len];
    for index in 0..layout.data_count {
        let shard = &payload[layout.data_range(index)];
        if shard.len() == layout.shard_len {
            encoder.add_original_shard(shard)
        } else {
            padded[..shard.len()].copy_from_slice(shard);
            padded[shard.len()..].fill(0);
            encoder.add_original_shard(&padded)
        }
        .map_err(|error| anyhow!("FEC encode: {error}"))?;
    }
    let result = encoder.encode().map_err(|error| anyhow!("FEC encode: {error}"))?;
    Ok(result.recovery_iter().map(<[u8]>::to_vec).collect())
}

pub fn recover(
    layout: Layout,
    parity_count: usize,
    data: &[(usize, &[u8])],
    parity: &[(usize, &[u8])],
) -> Result<Vec<(usize, Vec<u8>)>> {
    let mut decoder = ReedSolomonDecoder::new(layout.data_count, parity_count, layout.shard_len)
        .map_err(|error| anyhow!("FEC setup for {layout:?} + {parity_count}: {error}"))?;
    let mut padded = vec![0u8; layout.shard_len];
    for (index, shard) in data {
        if shard.len() == layout.shard_len {
            decoder.add_original_shard(*index, shard)
        } else {
            padded[..shard.len()].copy_from_slice(shard);
            padded[shard.len()..].fill(0);
            decoder.add_original_shard(*index, &padded)
        }
        .map_err(|error| anyhow!("FEC decode: {error}"))?;
    }
    for (index, shard) in parity {
        decoder.add_recovery_shard(*index, shard).map_err(|error| anyhow!("FEC decode: {error}"))?;
    }
    let result = decoder.decode().map_err(|error| anyhow!("FEC decode: {error}"))?;
    Ok(result
        .restored_original_iter()
        .map(|(index, shard)| (index, shard[..layout.data_range(index).len()].to_vec()))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts_split_payloads_into_balanced_even_shards() {
        let layout = Layout::for_payload(2500, 1200).unwrap();
        assert_eq!((layout.data_count, layout.shard_len), (3, 834));
        assert_eq!(layout.data_range(2), 1668..2500);
        assert_eq!(Layout::for_payload(1, 1200).unwrap().shard_len, 2);
        assert!(Layout::for_payload(0, 1200).is_err());
        assert!(Layout::for_payload(70_000_000, 1000).is_err());
    }

    #[test]
    fn parity_rebuilds_any_lost_data_shards_including_the_short_last_one() {
        let payload: Vec<u8> = (0..5001u32).map(|value| (value * 7 % 251) as u8).collect();
        let layout = Layout::for_payload(payload.len(), 1000).unwrap();
        let parity = encode_parity(&payload, layout, 2).unwrap();
        let shards: Vec<&[u8]> = (0..layout.data_count).map(|index| &payload[layout.data_range(index)]).collect();
        let last = layout.data_count - 1;

        let data: Vec<(usize, &[u8])> = (1..last).map(|index| (index, shards[index])).collect();
        let parity: Vec<(usize, &[u8])> = parity.iter().enumerate().map(|(index, shard)| (index, &shard[..])).collect();
        let mut restored = recover(layout, 2, &data, &parity).unwrap();
        restored.sort();
        assert_eq!(restored, vec![(0, shards[0].to_vec()), (last, shards[last].to_vec())]);
    }
}
