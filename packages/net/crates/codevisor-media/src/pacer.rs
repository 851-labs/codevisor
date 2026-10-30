//! Frame-spread pacing: a token bucket in front of the transport. Retransmissions and probes go before new packets.

use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

use bytes::Bytes;

/// What a queued packet is, so the sender can time the frame it belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketTag {
    pub stream: u8,
    pub frame: u32,
    /// The first transmission of this packet, rather than a retransmission or probe.
    pub original: bool,
}

#[derive(Debug)]
pub struct Pacer {
    urgent: VecDeque<(Bytes, PacketTag)>,
    queue: VecDeque<(Bytes, PacketTag)>,
    backlog_bytes: usize,
    credit_bytes: f64,
    rate_bps: f64,
    burst_bytes: f64,
    updated: Option<Instant>,
}

/// The bucket holds this much sending time, so a timer that fires late (tokio's resolution is 1 ms) still keeps up.
const BURST_TIME: Duration = Duration::from_millis(1);
const MIN_BURST_BYTES: f64 = 4.0 * 1500.0;

impl Pacer {
    pub fn new(rate_bps: f64) -> Self {
        let burst_bytes = burst_for(rate_bps);
        Self {
            urgent: VecDeque::new(),
            queue: VecDeque::new(),
            backlog_bytes: 0,
            credit_bytes: burst_bytes,
            rate_bps,
            burst_bytes,
            updated: None,
        }
    }

    pub fn push(&mut self, packet: Bytes, tag: PacketTag) {
        self.backlog_bytes += packet.len();
        if tag.original {
            self.queue.push_back((packet, tag));
        } else {
            self.urgent.push_back((packet, tag));
        }
    }

    pub fn backlog_bytes(&self) -> usize {
        self.backlog_bytes
    }

    pub fn is_empty(&self) -> bool {
        self.urgent.is_empty() && self.queue.is_empty()
    }

    /// Changes the rate from now on, keeping the credit earned at the old rate.
    pub fn set_rate(&mut self, now: Instant, rate_bps: f64) {
        self.refill(now);
        self.rate_bps = rate_bps.max(1.0);
        self.burst_bytes = burst_for(self.rate_bps);
    }

    /// The next packet, if the bucket allows sending at `now`.
    pub fn poll(&mut self, now: Instant) -> Option<(Bytes, PacketTag)> {
        self.refill(now);
        if self.credit_bytes <= 0.0 {
            return None;
        }
        let (packet, tag) = self.urgent.pop_front().or_else(|| self.queue.pop_front())?;
        self.backlog_bytes -= packet.len();
        self.credit_bytes -= packet.len() as f64;
        Some((packet, tag))
    }

    /// When [`poll`](Self::poll) will next return a packet; `None` when nothing is queued.
    pub fn next_send(&self, now: Instant) -> Option<Instant> {
        if self.is_empty() {
            return None;
        }
        let since = self.updated.map_or(Duration::ZERO, |updated| now.saturating_duration_since(updated));
        let credit = (self.credit_bytes + since.as_secs_f64() * self.rate_bps / 8.0).min(self.burst_bytes);
        if credit > 0.0 {
            return Some(now);
        }
        // A hair past the exact instant, so the credit is positive when the timer fires.
        Some(now + Duration::from_secs_f64(-credit * 8.0 / self.rate_bps) + Duration::from_micros(1))
    }

    fn refill(&mut self, now: Instant) {
        if let Some(updated) = self.updated {
            let earned = now.saturating_duration_since(updated).as_secs_f64() * self.rate_bps / 8.0;
            self.credit_bytes = (self.credit_bytes + earned).min(self.burst_bytes);
        }
        self.updated = Some(now);
    }
}

fn burst_for(rate_bps: f64) -> f64 {
    (rate_bps / 8.0 * BURST_TIME.as_secs_f64()).max(MIN_BURST_BYTES)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(original: bool) -> PacketTag {
        PacketTag { stream: 0, frame: 0, original }
    }

    #[test]
    fn spreads_a_backlog_at_the_rate_after_one_burst() {
        let start = Instant::now();
        // 48 Mbit/s: 6000 bytes per ms, so the burst is the 6000-byte minimum (five 1200-byte packets).
        let mut pacer = Pacer::new(48e6);
        for _ in 0..10 {
            pacer.push(Bytes::from(vec![0; 1200]), tag(true));
        }
        let mut sent = 0;
        while pacer.poll(start).is_some() {
            sent += 1;
        }
        assert_eq!(sent, 5);
        let next = pacer.next_send(start).unwrap();
        assert!(next > start && next <= start + Duration::from_micros(2));

        let later = start + Duration::from_micros(700);
        while pacer.poll(later).is_some() {
            sent += 1;
        }
        // 700 µs earns 4200 bytes: four more packets, the last on credit.
        assert_eq!(sent, 9);
        assert_eq!(pacer.backlog_bytes(), 1200);
    }

    #[test]
    fn retransmissions_go_before_queued_frames() {
        let start = Instant::now();
        let mut pacer = Pacer::new(1e9);
        pacer.push(Bytes::from_static(b"new"), tag(true));
        pacer.push(Bytes::from_static(b"again"), tag(false));
        assert_eq!(pacer.poll(start).unwrap().0, Bytes::from_static(b"again"));
        assert_eq!(pacer.poll(start).unwrap().0, Bytes::from_static(b"new"));
        assert_eq!(pacer.next_send(start), None);
    }
}
