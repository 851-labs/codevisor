//! The host half: packetize, protect, pace, retransmit on NACK, probe for missing acks, and turn the viewer's
//! feedback into events and a capacity estimate.

use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    time::{Duration, Instant},
};

use bytes::Bytes;
use reed_solomon_simd::ReedSolomonEncoder;

use crate::{
    estimator::Estimator,
    fec::{self, Layout},
    pacer::{Pacer, PacketTag},
    types::{
        Admission, Event, FecMode, FrameAck, MediaConfig, OutgoingFrame, Receipt, SendError, Stats, give_up_after,
    },
    wire::{self, Feedback, FrameFields, Kind, Nack, PacketHeader},
};

/// Probes for an unanswered frame before the sender stops waiting and reports it lost.
const MAX_PROBES: u32 = 6;
/// Unresolved frames kept per stream; older ones are reported lost.
const MAX_UNRESOLVED: usize = 512;
/// Loss seen within this long keeps adaptive FEC on.
const FEC_MEMORY: Duration = Duration::from_secs(10);
const LOSS_WINDOW: Duration = Duration::from_secs(1);
const MIN_FEC: f64 = 0.05;
const MAX_FEC: f64 = 0.25;
const PACING_GAIN: f64 = 2.0;
const MAX_PACING_GAIN: f64 = 4.0;

#[derive(Debug)]
struct SentFrame {
    /// Data packets, then parity packets, each a whole datagram.
    packets: Vec<Bytes>,
    data_count: usize,
    submitted: Instant,
    first_tx: Option<Instant>,
    /// Set once every original packet is out.
    last_tx: Option<Instant>,
    originals_out: usize,
    probes: u32,
}

#[derive(Debug, Default)]
struct StreamTx {
    next_frame: u32,
    unresolved: BTreeMap<u32, SentFrame>,
    ltr_token: Option<u64>,
}

#[derive(Debug, Default)]
struct LossWindow {
    started: Option<Instant>,
    sent: u64,
    nacked: u64,
    rate: f64,
}

#[derive(Debug)]
pub struct Sender {
    config: MediaConfig,
    epoch: Instant,
    streams: HashMap<u8, StreamTx>,
    pacer: Pacer,
    estimator: Estimator,
    loss: LossWindow,
    last_loss: Option<Instant>,
    rtt: Duration,
}

impl Sender {
    pub fn new(config: MediaConfig, epoch: Instant) -> Self {
        Self {
            config,
            epoch,
            streams: HashMap::new(),
            pacer: Pacer::new(config.initial_rate_bps * 2.0),
            estimator: Estimator::new(config.initial_rate_bps, config.max_rate_bps),
            loss: LossWindow::default(),
            last_loss: None,
            rtt: Duration::ZERO,
        }
    }

    pub fn set_rtt(&mut self, rtt: Duration) {
        self.rtt = rtt;
    }

    pub fn send_frame(
        &mut self,
        now: Instant,
        frame: OutgoingFrame<'_>,
        max_datagram: usize,
        events: &mut VecDeque<Event>,
        stats: &mut Stats,
    ) -> Result<u32, SendError> {
        if frame.meta.len() > wire::MAX_META_BYTES {
            return Err(SendError::MetaTooLarge);
        }
        let max_shard =
            max_datagram.checked_sub(wire::HEADER_BYTES).filter(|shard| *shard >= 2).ok_or(SendError::PathTooSmall)?;
        // The fields and the access unit become one payload (FEC protects both), then packets.
        let fields = FrameFields { keyframe: frame.keyframe, ltr_token: frame.ltr_token, meta: frame.meta.to_vec() };
        let payload = fields.payload(frame.data);
        let frame_len =
            u32::try_from(payload.len()).ok().filter(|len| *len < u32::MAX).ok_or(SendError::FrameTooLarge)?;
        let layout = Layout::for_payload(payload.len(), max_shard).map_err(|_| SendError::FrameTooLarge)?;
        let parity_count = self.parity_count(now, layout.data_count);
        let parity = fec::encode_parity(&payload, layout, parity_count).map_err(|_| SendError::FrameTooLarge)?;

        let stream = self.streams.entry(frame.stream).or_default();
        let number = stream.next_frame;
        stream.next_frame = stream.next_frame.wrapping_add(1);
        let header = |kind, index: usize| PacketHeader {
            kind,
            stream: frame.stream,
            frame: number,
            index: index as u16,
            data_count: layout.data_count as u16,
            parity_count: parity_count as u16,
            frame_len,
        };
        let mut packets = Vec::with_capacity(layout.data_count + parity_count);
        for index in 0..layout.data_count {
            packets.push(header(Kind::Data, index).encode(&payload[layout.data_range(index)]));
        }
        for (offset, shard) in parity.iter().enumerate() {
            packets.push(header(Kind::Parity, layout.data_count + offset).encode(shard));
        }
        let tag = PacketTag { stream: frame.stream, frame: number, original: true };
        for packet in &packets {
            self.pacer.push(packet.clone(), tag);
        }
        stats.frames_sent += 1;
        stats.parity_packets_sent += parity_count as u64;
        self.loss.sent += layout.data_count as u64;
        stream.unresolved.insert(
            number,
            SentFrame {
                packets,
                data_count: layout.data_count,
                submitted: now,
                first_tx: None,
                last_tx: None,
                originals_out: 0,
                probes: 0,
            },
        );
        if stream.unresolved.len() > MAX_UNRESOLVED {
            let (oldest, _) = stream.unresolved.pop_first().expect("over the limit");
            stats.frames_lost += 1;
            events.push_back(Event::FrameLost { stream: frame.stream, frame: oldest });
        }
        self.update_pacing_rate(now);
        Ok(number)
    }

    fn parity_count(&mut self, now: Instant, data_count: usize) -> usize {
        let ratio = self.fec_ratio(now);
        if ratio <= 0.0 {
            return 0;
        }
        let wanted = ((data_count as f64 * ratio).ceil() as usize).max(1);
        let mut count = wanted.min(fec::MAX_PACKETS - data_count);
        while count > 0 && !ReedSolomonEncoder::supports(data_count, count) {
            count /= 2;
        }
        count
    }

    pub fn fec_ratio(&mut self, now: Instant) -> f64 {
        self.roll_loss_window(now);
        match self.config.fec {
            FecMode::Off => 0.0,
            FecMode::Fixed(ratio) => ratio.max(0.0),
            FecMode::Adaptive => {
                let long_round_trip = self.rtt > self.config.frame_interval / 4;
                let recent_loss = self.last_loss.is_some_and(|at| now.saturating_duration_since(at) < FEC_MEMORY);
                if long_round_trip || recent_loss {
                    (MIN_FEC + 2.0 * self.loss.rate).clamp(MIN_FEC, MAX_FEC)
                } else {
                    0.0
                }
            }
        }
    }

    fn roll_loss_window(&mut self, now: Instant) {
        let started = *self.loss.started.get_or_insert(now);
        if now.saturating_duration_since(started) < LOSS_WINDOW {
            return;
        }
        let current = if self.loss.sent == 0 { 0.0 } else { self.loss.nacked as f64 / self.loss.sent as f64 };
        // Rise at once, decay by halves, so one quiet window doesn't switch protection off.
        self.loss.rate = current.max(self.loss.rate / 2.0).min(1.0);
        self.loss = LossWindow { started: Some(now), sent: 0, nacked: 0, rate: self.loss.rate };
    }

    /// Twice the estimate, so every frame probes for more; faster when that wouldn't drain the backlog within half a
    /// frame interval, but never past four times the estimate, which would only overflow a slow link's queue.
    fn update_pacing_rate(&mut self, now: Instant) {
        let estimate = self.estimator.estimate_bps();
        let spread = self.config.frame_interval.as_secs_f64() / 2.0;
        let drain = self.pacer.backlog_bytes() as f64 * 8.0 / spread;
        self.pacer.set_rate(now, drain.clamp(estimate * PACING_GAIN, estimate * MAX_PACING_GAIN));
    }

    /// The next packet the pacer allows out at `now`.
    pub fn poll_transmit(&mut self, now: Instant, stats: &mut Stats) -> Option<Bytes> {
        let (packet, tag) = self.pacer.poll(now)?;
        stats.packets_sent += 1;
        stats.bytes_sent += packet.len() as u64;
        if tag.original
            && let Some(frame) =
                self.streams.get_mut(&tag.stream).and_then(|stream| stream.unresolved.get_mut(&tag.frame))
        {
            frame.first_tx.get_or_insert(now);
            frame.originals_out += 1;
            if frame.originals_out == frame.packets.len() {
                frame.last_tx = Some(now);
            }
        }
        if self.pacer.is_empty() {
            self.update_pacing_rate(now);
        }
        Some(packet)
    }

    pub fn on_nack(&mut self, now: Instant, nack: &Nack, stats: &mut Stats) {
        stats.nacks_received += 1;
        let Some(frame) = self.streams.get_mut(&nack.stream).and_then(|stream| stream.unresolved.get_mut(&nack.frame))
        else {
            return;
        };
        let tag = PacketTag { stream: nack.stream, frame: nack.frame, original: false };
        let mut requested = 0;
        for &(start, count) in &nack.ranges {
            let range = if count == wire::WHOLE_FRAME {
                0..frame.data_count
            } else {
                usize::from(start).min(frame.data_count)
                    ..(usize::from(start) + usize::from(count)).min(frame.data_count)
            };
            for index in range {
                self.pacer.push(frame.packets[index].clone(), tag);
                requested += 1;
            }
        }
        if requested > 0 {
            stats.packets_retransmitted += requested;
            self.loss.nacked += requested;
            self.last_loss = Some(now);
            self.update_pacing_rate(now);
        }
    }

    pub fn on_feedback(&mut self, now: Instant, feedback: &Feedback, events: &mut VecDeque<Event>, stats: &mut Stats) {
        let Some(stream) = self.streams.get_mut(&feedback.stream) else {
            return;
        };
        if let Some(token) = feedback.ltr_token
            && stream.ltr_token != Some(token)
        {
            stream.ltr_token = Some(token);
            events.push_back(Event::LtrAcked { stream: feedback.stream, token });
        }
        if let Some(frame) = stream.unresolved.remove(&feedback.frame) {
            if feedback.lost {
                self.last_loss = Some(now);
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: feedback.stream, frame: feedback.frame });
            } else {
                let ack = acknowledge(feedback.stream, feedback.frame, &frame, now, feedback.receipt.map(receipt));
                stats.frames_acked += 1;
                events.push_back(Event::FrameAcked(ack));
            }
            if let (Some(first_tx), Some(receipt)) = (frame.first_tx, feedback.receipt) {
                // A first packet that was lost and resent would read as queueing; only clean frames time the delay.
                if !feedback.lost && receipt.recovery == crate::Recovery::None {
                    let first_tx_us = first_tx.saturating_duration_since(self.epoch).as_micros() as i64;
                    let hold_off = self.rtt + self.config.frame_interval;
                    self.estimator.on_delay(now, receipt.first_rx_us as i64 - first_tx_us, hold_off);
                }
                let span = Duration::from_micros(receipt.last_rx_offset_us.into());
                self.estimator.on_delivery(now, receipt.original_bytes as usize, span);
            }
        }
        // Everything below `resolved_below` is settled at the viewer; the bitmap says which of the last 32 it lost.
        let stream = self.streams.get_mut(&feedback.stream).expect("looked up above");
        while let Some(entry) = stream.unresolved.first_entry() {
            let number = *entry.key();
            if number >= feedback.resolved_below {
                break;
            }
            let frame = entry.remove();
            // Past the bitmap's 32 frames the viewer's outcome is unknown here; a needless refresh is cheaper than
            // encoding on top of a frame the viewer skipped.
            let age = feedback.resolved_below - 1 - number;
            if age >= 32 || feedback.lost_bitmap & (1 << age) != 0 {
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: feedback.stream, frame: number });
            } else {
                stats.frames_acked += 1;
                events.push_back(Event::FrameAcked(acknowledge(feedback.stream, number, &frame, now, None)));
            }
        }
    }

    /// Re-sends the last data packet of every frame whose ack is overdue, which makes the viewer answer for it or
    /// NACK what it lacks. Frames still unanswered after [`MAX_PROBES`] probes are reported lost.
    pub fn handle_timeout(&mut self, now: Instant, events: &mut VecDeque<Event>, stats: &mut Stats) {
        let timeout = self.ack_timeout();
        let mut probed = false;
        for (&stream_id, stream) in &mut self.streams {
            let mut expired = Vec::new();
            for (&number, frame) in &mut stream.unresolved {
                let Some(last_tx) = frame.last_tx else {
                    continue;
                };
                if now < last_tx + timeout * (frame.probes + 1) {
                    continue;
                }
                if frame.probes == MAX_PROBES {
                    expired.push(number);
                    continue;
                }
                frame.probes += 1;
                stats.probes_sent += 1;
                let tag = PacketTag { stream: stream_id, frame: number, original: false };
                self.pacer.push(frame.packets[frame.data_count - 1].clone(), tag);
                probed = true;
            }
            for number in expired {
                stream.unresolved.remove(&number);
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: stream_id, frame: number });
            }
        }
        if probed {
            self.update_pacing_rate(now);
        }
    }

    fn ack_timeout(&self) -> Duration {
        give_up_after(self.rtt, self.config.frame_interval) + self.rtt + Duration::from_millis(1)
    }

    pub fn poll_timeout(&self, now: Instant) -> Option<Instant> {
        let timeout = self.ack_timeout();
        let probe = self
            .streams
            .values()
            .flat_map(|stream| stream.unresolved.values())
            .filter_map(|frame| Some(frame.last_tx? + timeout * (frame.probes + 1)))
            .min();
        [self.pacer.next_send(now), probe].into_iter().flatten().min()
    }

    pub fn admission(&self) -> Admission {
        let estimate_bps = self.estimator.estimate_bps();
        let budget_bytes = (estimate_bps / 8.0 * self.config.frame_interval.as_secs_f64()) as usize;
        let backlog_bytes = self.pacer.backlog_bytes();
        Admission {
            admit: backlog_bytes <= budget_bytes,
            backlog_bytes,
            budget_bytes,
            estimate_bps,
            encoder_ceiling_bps: estimate_bps * 0.85,
        }
    }

    pub fn fill_stats(&mut self, now: Instant, stats: &mut Stats) {
        stats.estimate_bps = self.estimator.estimate_bps();
        stats.queue_delay_us = self.estimator.queue_delay_us();
        stats.fec_ratio = self.fec_ratio(now);
        stats.loss_rate = self.loss.rate;
    }
}

fn receipt(receipt: wire::FrameReceipt) -> Receipt {
    Receipt {
        arriving: Duration::from_micros(receipt.last_rx_offset_us.into()),
        assembling: Duration::from_micros(receipt.complete_offset_us.into()),
        recovery: receipt.recovery,
    }
}

fn acknowledge(stream: u8, number: u32, frame: &SentFrame, now: Instant, receipt: Option<Receipt>) -> FrameAck {
    let first_tx = frame.first_tx.unwrap_or(now);
    FrameAck {
        stream,
        frame: number,
        queued: first_tx.saturating_duration_since(frame.submitted),
        sending: frame.last_tx.unwrap_or(now).saturating_duration_since(first_tx),
        acked_after: now.saturating_duration_since(first_tx),
        receipt,
    }
}
