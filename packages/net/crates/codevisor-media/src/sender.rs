use std::{
    collections::{BTreeMap, VecDeque},
    time::{Duration, Instant},
};

use bytes::Bytes;
use reed_solomon_simd::ReedSolomonEncoder;

use crate::{
    estimator::{Delivery, Estimator},
    flight::{Arrival, Flights},
    fec::{self, Layout},
    pacer::{Pacer, PacketTag},
    types::{
        Admission, Event, FecMode, FrameAck, MediaConfig, OutgoingFrame, Receipt, SendError, Stats, give_up_after,
    },
    windowed::{Keep, Windowed},
    wire::{self, Feedback, FrameFields, Kind, Nack, PacketHeader, RefreshRequest},
};

const MAX_PROBES: u32 = 6;
const MAX_UNRESOLVED: usize = 512;
const MAX_UNREPORTED: usize = 32;
const FEC_MEMORY: Duration = Duration::from_secs(10);
const LOSS_WINDOW: Duration = Duration::from_secs(1);
const MIN_FEC: f64 = 0.05;
const MAX_FEC: f64 = 0.25;
const PACING_GAIN: f64 = 2.0;
const MAX_PACING_GAIN: f64 = 4.0;
const CONSTRAINED_PACING_GAIN: f64 = 1.25;
const CONSTRAINED_BPS: f64 = 100e6;
const HEAVY_LOSS: f64 = 0.1;
const MIN_LOSS_SAMPLE: u64 = 30;
const TAIL_PROBE_MARGIN: Duration = Duration::from_millis(1);
const ACK_DELAY_GAIN: f64 = 1.0 / 8.0;
const ACK_VARIATION_GAIN: f64 = 1.0 / 4.0;
const MAX_TAIL_BACKOFF: u32 = 4;
const MIN_RTT_WINDOW: Duration = Duration::from_secs(10);
const ENCODER_SHARE: f64 = 0.85;
const IN_FLIGHT_INTERVALS: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Resend {
    Never,
    Queued,
    Sent(Instant),
}

#[derive(Debug)]
struct SentFrame {
    packets: Vec<Bytes>,
    resends: Vec<Resend>,
    data_count: usize,
    submitted: Instant,
    first_tx: Option<Instant>,
    latest_tx: Option<Instant>,
    last_tx: Option<Instant>,
    originals_out: usize,
    bytes_out: usize,
    probes: u32,
    flight: u64,
}

#[derive(Debug, Default)]
struct StreamTx {
    next_frame: u32,
    unresolved: BTreeMap<u32, SentFrame>,
    unreported: BTreeMap<u32, Unreported>,
    ltr_token: Option<u64>,
    last_recovery: Option<u32>,
    last_keyframe: Option<u32>,
    refresh: Option<AnsweredRequest>,
}

#[derive(Debug, Clone, Copy)]
struct SendTimes {
    first: Instant,
    latest: Option<Instant>,
}

impl SendTimes {
    fn delivery(self, receipt: wire::FrameReceipt) -> Delivery {
        Delivery {
            bytes: receipt.original_bytes as usize,
            receive_span: Duration::from_micros(receipt.last_rx_offset_us.into()),
            send_span: self.latest.map_or(Duration::ZERO, |latest| latest.saturating_duration_since(self.first)),
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Unreported {
    sent: SendTimes,
    resolved: Instant,
}

#[derive(Debug, Clone, Copy)]
struct AnsweredRequest {
    request: u16,
    keyframe: bool,
    answers_from: u32,
}

impl StreamTx {
    fn answer_to(&self, request: AnsweredRequest) -> Option<u32> {
        let answer = if request.keyframe { self.last_keyframe } else { self.last_recovery };
        answer.filter(|frame| *frame >= request.answers_from)
    }
}

#[derive(Debug, Clone, Copy)]
struct AckDelay {
    smoothed: f64,
    variation: f64,
}

impl AckDelay {
    fn update(previous: Option<Self>, sample: Duration) -> Self {
        let sample = sample.as_secs_f64();
        let Some(previous) = previous else { return Self { smoothed: sample, variation: sample / 2.0 } };
        let deviation = (sample - previous.smoothed).abs();
        Self {
            smoothed: previous.smoothed + ACK_DELAY_GAIN * (sample - previous.smoothed),
            variation: previous.variation + ACK_VARIATION_GAIN * (deviation - previous.variation),
        }
    }

    fn tail_probe_after(&self) -> Duration {
        Duration::from_secs_f64(self.smoothed) + Duration::from_secs_f64(2.0 * self.variation).max(TAIL_PROBE_MARGIN)
    }
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
    streams: BTreeMap<u8, StreamTx>,
    pacer: Pacer,
    estimator: Estimator,
    loss: LossWindow,
    last_loss: Option<Instant>,
    rtt: Duration,
    ack_delay: Option<AckDelay>,
    tail_backoff: u32,
    in_flight_bytes: usize,
    min_rtt: Windowed<Duration>,
    ceiling_fec_ratio: f64,
    flights: Flights,
}

impl Sender {
    pub fn new(config: MediaConfig, epoch: Instant) -> Self {
        Self {
            config,
            epoch,
            streams: BTreeMap::new(),
            pacer: Pacer::new(config.initial_rate_bps * 2.0),
            estimator: Estimator::new(config.initial_rate_bps, config.max_rate_bps, config.frame_interval),
            loss: LossWindow::default(),
            last_loss: None,
            rtt: Duration::ZERO,
            ack_delay: None,
            tail_backoff: 0,
            in_flight_bytes: 0,
            min_rtt: Windowed::new(MIN_RTT_WINDOW, Keep::Smallest),
            ceiling_fec_ratio: 0.0,
            flights: Flights::default(),
        }
    }

    pub fn set_rtt(&mut self, rtt: Duration) {
        self.rtt = rtt;
    }

    fn note_rtt(&mut self, now: Instant) {
        if !self.rtt.is_zero() {
            self.min_rtt.push(now, self.rtt);
        }
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
        let fields = FrameFields {
            keyframe: frame.keyframe,
            refresh: frame.refresh,
            ltr_token: frame.ltr_token,
            meta: frame.meta.to_vec(),
        };
        let payload = fields.payload(frame.data);
        let frame_len =
            u32::try_from(payload.len()).ok().filter(|len| *len < u32::MAX).ok_or(SendError::FrameTooLarge)?;
        let layout = Layout::for_payload(payload.len(), max_shard).map_err(|_| SendError::FrameTooLarge)?;
        let parity_count = self.parity_count(now, layout.data_count);
        let parity = fec::encode_parity(&payload, layout, parity_count).map_err(|_| SendError::FrameTooLarge)?;

        let stream = self.streams.entry(frame.stream).or_default();
        let number = stream.next_frame;
        stream.next_frame = stream.next_frame.wrapping_add(1);
        if frame.keyframe || frame.refresh {
            stream.last_recovery = Some(number);
        }
        if frame.keyframe {
            stream.last_keyframe = Some(number);
        }
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
        for (index, packet) in packets.iter().enumerate() {
            self.pacer.push(
                packet.clone(),
                PacketTag { stream: frame.stream, frame: number, index: index as u16, original: true },
            );
        }
        stats.frames_sent += 1;
        stats.parity_packets_sent += parity_count as u64;
        self.loss.sent += layout.data_count as u64;
        let flight = self.flights.join(now, self.config.frame_interval / 4);
        stream.unresolved.insert(
            number,
            SentFrame {
                packets,
                resends: vec![Resend::Never; layout.data_count],
                data_count: layout.data_count,
                submitted: now,
                first_tx: None,
                latest_tx: None,
                last_tx: None,
                originals_out: 0,
                bytes_out: 0,
                probes: 0,
                flight,
            },
        );
        if stream.unresolved.len() > MAX_UNRESOLVED {
            let (oldest, dropped) = stream.unresolved.pop_first().expect("over the limit");
            self.in_flight_bytes -= dropped.bytes_out;
            self.flights.report(dropped.flight, None);
            stats.frames_lost += 1;
            events.push_back(Event::FrameLost { stream: frame.stream, frame: oldest });
        }
        self.update_pacing_rate(now);
        Ok(number)
    }

    fn parity_count(&mut self, now: Instant, data_count: usize) -> usize {
        let ratio = self.fec_ratio(now);
        self.ceiling_fec_ratio = ratio;
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
        if self.loss.sent >= MIN_LOSS_SAMPLE && current > HEAVY_LOSS {
            self.estimator.on_heavy_loss(now, current.min(1.0));
        }
        self.loss.rate = current.max(self.loss.rate / 2.0).min(1.0);
        self.loss = LossWindow { started: Some(now), sent: 0, nacked: 0, rate: self.loss.rate };
    }

    fn update_pacing_rate(&mut self, now: Instant) {
        let estimate = self.estimator.estimate_bps();
        let spread = self.config.frame_interval.as_secs_f64() / 2.0;
        let drain = self.pacer.backlog_bytes() as f64 * 8.0 / spread;
        let headroom = ((estimate - CONSTRAINED_BPS) / CONSTRAINED_BPS).clamp(0.0, 1.0);
        let large = self.pacer.backlog_bytes() as f64 * 8.0 > estimate * spread;
        let floor_gain = if large { 1.0 } else { CONSTRAINED_PACING_GAIN };
        let gain = floor_gain + (PACING_GAIN - floor_gain) * headroom;
        let max_gain = floor_gain + (MAX_PACING_GAIN - floor_gain) * headroom;
        self.pacer.set_rate(now, drain.clamp(estimate * gain, estimate * max_gain));
    }

    pub fn poll_transmit(&mut self, now: Instant, stats: &mut Stats) -> Option<Bytes> {
        let (packet, tag) = self.pacer.poll(now)?;
        stats.packets_sent += 1;
        stats.bytes_sent += packet.len() as u64;
        if !tag.original
            && let Some(frame) =
                self.streams.get_mut(&tag.stream).and_then(|stream| stream.unresolved.get_mut(&tag.frame))
            && let Some(resend) = frame.resends.get_mut(usize::from(tag.index))
        {
            *resend = Resend::Sent(now);
        }
        if tag.original
            && let Some(frame) =
                self.streams.get_mut(&tag.stream).and_then(|stream| stream.unresolved.get_mut(&tag.frame))
        {
            frame.first_tx.get_or_insert(now);
            frame.latest_tx = Some(now);
            frame.originals_out += 1;
            frame.bytes_out += packet.len();
            self.in_flight_bytes += packet.len();
            self.estimator.on_sent(now, packet.len());
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
        let mut requested = 0;
        let mut first_losses = 0;
        let mut lost_bytes = 0;
        let mut repeated = 0;
        for &(start, count) in &nack.ranges {
            let range = if count == wire::WHOLE_FRAME {
                0..frame.data_count
            } else {
                usize::from(start).min(frame.data_count)
                    ..(usize::from(start) + usize::from(count)).min(frame.data_count)
            };
            for index in range {
                if index >= frame.originals_out {
                    continue;
                }
                let recent = match frame.resends[index] {
                    Resend::Never => false,
                    Resend::Queued => true,
                    Resend::Sent(at) => now < at + self.rtt / 2,
                };
                if recent {
                    repeated += 1;
                    continue;
                }
                if frame.resends[index] == Resend::Never {
                    first_losses += 1;
                    lost_bytes += frame.packets[index].len();
                }
                frame.resends[index] = Resend::Queued;
                let tag = PacketTag { stream: nack.stream, frame: nack.frame, index: index as u16, original: false };
                self.pacer.push(frame.packets[index].clone(), tag);
                requested += 1;
            }
        }
        stats.retransmissions_skipped += repeated;
        if requested > 0 {
            stats.packets_retransmitted += requested;
            self.loss.nacked += first_losses;
            self.estimator.on_lost(now, lost_bytes);
            self.last_loss = Some(now);
            self.update_pacing_rate(now);
        }
    }

    pub fn on_feedback(&mut self, now: Instant, feedback: &Feedback, events: &mut VecDeque<Event>, stats: &mut Stats) {
        self.note_rtt(now);
        self.ceiling_fec_ratio = self.fec_ratio(now);
        self.estimator.set_admitting(self.admission().admit);
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
            self.in_flight_bytes -= frame.bytes_out;
            let arrival = feedback.receipt.zip(frame.first_tx).filter(|_| !feedback.lost).map(|(receipt, first_tx)| {
                Arrival {
                    first_tx,
                    latest_tx: frame.latest_tx,
                    first_rx_us: receipt.first_rx_us,
                    last_rx_us: receipt.first_rx_us + u64::from(receipt.last_rx_offset_us),
                    original_bytes: receipt.original_bytes as usize,
                    first_packet_bytes: frame.packets[0].len(),
                }
            });
            if let Some(delivery) = self.flights.report(frame.flight, arrival) {
                self.estimator.on_flight(now, delivery);
            }
            if feedback.lost {
                self.last_loss = Some(now);
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: feedback.stream, frame: feedback.frame });
            } else {
                let ack = acknowledge(feedback.stream, feedback.frame, &frame, now, feedback.receipt.map(receipt));
                stats.frames_acked += 1;
                events.push_back(Event::FrameAcked(ack));
            }
            if feedback.receipt.is_some_and(|receipt| receipt.recovery == crate::Recovery::Fec) {
                self.loss.nacked += 1;
                self.last_loss = Some(now);
            }
            if let (Some(first_tx), Some(receipt)) = (frame.first_tx, feedback.receipt) {
                if let Some(last_tx) = frame.last_tx
                    && !feedback.lost
                    && frame.probes == 0
                    && receipt.recovery == crate::Recovery::None
                {
                    self.ack_delay = Some(AckDelay::update(self.ack_delay, now.saturating_duration_since(last_tx)));
                    self.tail_backoff = 0;
                }
                let first_may_be_resent = receipt.recovery == crate::Recovery::Nack && frame.data_count <= 2;
                if !feedback.lost && frame.probes == 0 && !first_may_be_resent {
                    let first_tx_us = first_tx.saturating_duration_since(self.epoch).as_micros() as i64;
                    let hold_off =
                        self.rtt.min(self.min_rtt.best().unwrap_or(self.rtt) * 2) + self.config.frame_interval;
                    self.estimator.on_delay(now, receipt.first_rx_us as i64 - first_tx_us, hold_off);
                }
                if !feedback.lost {
                    self.estimator.on_acked(now, frame.bytes_out);
                    let sent = SendTimes { first: first_tx, latest: frame.latest_tx };
                    self.estimator.on_delivery(now, sent.delivery(receipt));
                }
            }
        } else if let Some(receipt) = feedback.receipt.filter(|_| !feedback.lost)
            && let Some(unreported) = stream.unreported.remove(&feedback.frame)
            && now.saturating_duration_since(unreported.resolved) <= self.rtt * 2 + self.config.frame_interval
        {
            self.estimator.on_delivery(now, unreported.sent.delivery(receipt));
        }
        let stream = self.streams.get_mut(&feedback.stream).expect("looked up above");
        while let Some(entry) = stream.unresolved.first_entry() {
            let number = *entry.key();
            if number >= feedback.resolved_below {
                break;
            }
            let frame = entry.remove();
            self.in_flight_bytes -= frame.bytes_out;
            self.flights.report(frame.flight, None);
            let age = feedback.resolved_below - 1 - number;
            if age >= 32 || feedback.lost_bitmap & (1 << age) != 0 {
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: feedback.stream, frame: number });
            } else {
                stats.frames_acked += 1;
                self.estimator.on_acked(now, frame.bytes_out);
                events.push_back(Event::FrameAcked(acknowledge(feedback.stream, number, &frame, now, None)));
                if let Some(first) = frame.first_tx {
                    let sent = SendTimes { first, latest: frame.latest_tx };
                    stream.unreported.insert(number, Unreported { sent, resolved: now });
                    if stream.unreported.len() > MAX_UNREPORTED {
                        stream.unreported.pop_first();
                    }
                }
            }
        }
    }

    pub fn on_refresh_request(&mut self, request: &RefreshRequest, events: &mut VecDeque<Event>, stats: &mut Stats) {
        let Some(stream) = self.streams.get_mut(&request.stream) else {
            return;
        };
        if let Some(answered) = stream.refresh {
            let age = request.request.wrapping_sub(answered.request) as i16;
            if age < 0 {
                return;
            }
            let failed = stream.answer_to(answered).is_some_and(|frame| frame < request.resolved_below);
            if age == 0 && !failed {
                return;
            }
        }
        stream.refresh = Some(AnsweredRequest {
            request: request.request,
            keyframe: request.keyframe,
            answers_from: stream.next_frame,
        });
        stats.refreshes_requested += 1;
        events.push_back(Event::RefreshRequested { stream: request.stream, keyframe: request.keyframe });
    }

    pub fn handle_timeout(&mut self, now: Instant, events: &mut VecDeque<Event>, stats: &mut Stats) {
        let tail_probe = self.tail_probe_after();
        let timeout = self.ack_timeout();
        let mut probed = false;
        for (&stream_id, stream) in &mut self.streams {
            let mut expired = Vec::new();
            let newest = stream.next_frame.wrapping_sub(1);
            for (&number, frame) in &mut stream.unresolved {
                let Some(due) = probe_due(frame, number == newest, tail_probe, timeout) else {
                    continue;
                };
                if now < due {
                    continue;
                }
                if frame.probes == MAX_PROBES {
                    expired.push(number);
                    continue;
                }
                if frame.probes == 0 && number == newest {
                    self.tail_backoff = (self.tail_backoff + 1).min(MAX_TAIL_BACKOFF);
                }
                frame.probes += 1;
                stats.probes_sent += 1;
                let index = frame.data_count - 1;
                let tag = PacketTag { stream: stream_id, frame: number, index: index as u16, original: false };
                self.pacer.push(frame.packets[index].clone(), tag);
                probed = true;
            }
            for number in expired {
                if let Some(frame) = stream.unresolved.remove(&number) {
                    self.in_flight_bytes -= frame.bytes_out;
                    self.flights.report(frame.flight, None);
                }
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: stream_id, frame: number });
            }
        }
        if probed {
            self.update_pacing_rate(now);
        }
    }

    fn tail_probe_after(&self) -> Duration {
        let base = self.ack_delay.map_or(self.rtt + TAIL_PROBE_MARGIN, |delay| delay.tail_probe_after());
        (base * (1 << self.tail_backoff)).min(self.ack_timeout())
    }

    fn ack_timeout(&self) -> Duration {
        give_up_after(self.rtt, self.config.frame_interval) + self.rtt + Duration::from_millis(1)
    }

    pub fn poll_timeout(&self, now: Instant) -> Option<Instant> {
        let tail_probe = self.tail_probe_after();
        let timeout = self.ack_timeout();
        let probe = self
            .streams
            .values()
            .flat_map(|stream| {
                let newest = stream.next_frame.wrapping_sub(1);
                stream.unresolved.iter().map(move |(number, frame)| (*number == newest, frame))
            })
            .filter_map(|(newest, frame)| probe_due(frame, newest, tail_probe, timeout))
            .min();
        [self.pacer.next_send(now), probe].into_iter().flatten().min()
    }

    pub fn admission(&self) -> Admission {
        let estimate_bps = self.estimator.estimate_bps();
        let budget_bytes = (estimate_bps / 8.0 * self.config.frame_interval.as_secs_f64()) as usize;
        let path_bytes = if self.estimator.measured() {
            let min_rtt = self.min_rtt.best().unwrap_or(self.rtt);
            let in_flight_time = min_rtt + self.config.frame_interval * IN_FLIGHT_INTERVALS;
            (estimate_bps / 8.0 * in_flight_time.as_secs_f64()) as usize
        } else {
            0
        };
        let backlog_bytes = self.pacer.backlog_bytes() + self.in_flight_bytes.saturating_sub(path_bytes);
        Admission {
            admit: backlog_bytes <= budget_bytes,
            backlog_bytes,
            budget_bytes,
            estimate_bps,
            encoder_ceiling_bps: estimate_bps * ENCODER_SHARE / (1.0 + self.ceiling_fec_ratio),
        }
    }

    pub fn fill_stats(&mut self, now: Instant, stats: &mut Stats) {
        stats.estimate_bps = self.estimator.estimate_bps();
        stats.queue_delay_us = self.estimator.queue_delay_us();
        stats.fec_ratio = self.fec_ratio(now);
        stats.loss_rate = self.loss.rate;
    }
}

fn probe_due(frame: &SentFrame, newest: bool, tail_probe: Duration, timeout: Duration) -> Option<Instant> {
    let first = if newest { tail_probe } else { timeout };
    Some(frame.last_tx? + first + timeout * frame.probes)
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
