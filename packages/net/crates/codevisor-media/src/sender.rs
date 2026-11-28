use std::{
    collections::{BTreeMap, VecDeque},
    time::{Duration, Instant},
};

use bytes::Bytes;
use reed_solomon_simd::ReedSolomonEncoder;

use crate::{
    arrived::Arrived,
    estimator::{Delivery, Estimator},
    fec::{self, Layout},
    pacer::{Pacer, PacketTag},
    types::{
        Admission, Event, FecMode, FrameAck, MAX_CROSSING, MediaConfig, OutgoingFrame, Receipt, SendError, Stats,
        give_up_after,
    },
    windowed::{Keep, Windowed},
    wire::{self, Feedback, FrameFields, Kind, Nack, PacketHeader, RefreshRequest},
};

const MAX_PROBES: u32 = 6;
const DEEP_QUEUE: u32 = 4;
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
    Sent { at: Instant, position: u64, queued_deep: bool },
}

#[derive(Debug)]
struct SentFrame {
    packets: Vec<Bytes>,
    resends: Vec<Resend>,
    counted_lost: Vec<bool>,
    guessed_to: usize,
    data_count: usize,
    submitted: Instant,
    first_tx: Option<Instant>,
    latest_tx: Option<Instant>,
    last_tx: Option<Instant>,
    originals_out: usize,
    bytes_out: usize,
    sent_before: u64,
    positions: Vec<u64>,
    flight_bytes: usize,
    heard: Option<Instant>,
    probe: Option<Resend>,
    probes: u32,
    unanswered: u32,
    expires: Option<Instant>,
    charges: Charges,
}

impl SentFrame {
    fn arrived_before(&self, index: usize) -> Option<u64> {
        match index.checked_sub(1) {
            None => self.first_tx.map(|_| self.sent_before),
            Some(previous) => {
                let untouched = self.resends.get(previous).is_none_or(|resend| *resend == Resend::Never);
                self.positions.get(previous).copied().filter(|_| untouched && previous >= self.guessed_to)
            }
        }
    }

    fn arrived_complete(&self) -> Option<u64> {
        self.positions.get(self.data_count.min(self.positions.len()).checked_sub(1)?).copied()
    }
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

#[derive(Debug, Clone)]
struct Unreported {
    sent: SendTimes,
    resolved: Instant,
    charges: Charges,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Charge {
    window: u64,
    lost_at: Instant,
    position: u64,
    bytes: usize,
    arrived_lost: Option<u64>,
}

#[derive(Debug, Clone, Default)]
struct Charges {
    per_index: Vec<Option<Charge>>,
    fixed: bool,
    counted: Option<(u64, Instant)>,
    confirmed: bool,
    sent_in: u64,
}

impl Charges {
    fn standing(&self) -> bool {
        self.fixed || self.per_index.iter().any(Option::is_some)
    }

    fn confirm(&mut self, answer: Answer, estimator: &mut Estimator) {
        if std::mem::replace(&mut self.confirmed, true) {
            return;
        }
        for charge in self.per_index.iter_mut().filter_map(Option::take) {
            match answer {
                Answer::Report(at) => estimator.on_lost_earlier(charge.lost_at, charge.bytes, Some(at)),
                Answer::Due(at) => estimator.on_lost_earlier(at, charge.bytes, None),
                Answer::GivenUp => estimator.on_lost_earlier(charge.lost_at, charge.bytes, None),
            }
            self.fixed = true;
        }
    }

    fn unconfirmed(&self) -> bool {
        !self.confirmed && self.per_index.iter().any(Option::is_some)
    }
}

#[derive(Debug, Clone, Copy)]
enum Answer {
    Report(Instant),
    Due(Instant),
    GivenUp,
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
    id: u64,
    started: Option<Instant>,
    sent: u64,
    nacked: u64,
    next_sent: u64,
    next_nacked: u64,
    rate: f64,
}

impl LossWindow {
    fn sending_into(&self, now: Instant) -> u64 {
        let ended = self.started.is_some_and(|started| now.saturating_duration_since(started) >= LOSS_WINDOW);
        self.id + u64::from(ended)
    }

    fn counted_in(&self, sent_in: u64) -> u64 {
        sent_in.max(self.id)
    }

    fn nacked_in(&mut self, window: u64) -> Option<&mut u64> {
        match window.checked_sub(self.id) {
            Some(0) => Some(&mut self.nacked),
            Some(1) => Some(&mut self.next_nacked),
            _ => None,
        }
    }
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
    nack_losses: BTreeMap<(u8, u32), Instant>,
    rtt: Duration,
    ack_delay: Option<AckDelay>,
    tail_backoff: u32,
    in_flight_bytes: usize,
    min_rtt: Windowed<Duration>,
    ceiling_fec_ratio: f64,
    sent_total: u64,
    arrived: Arrived,
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
            nack_losses: BTreeMap::new(),
            rtt: Duration::ZERO,
            ack_delay: None,
            tail_backoff: 0,
            in_flight_bytes: 0,
            min_rtt: Windowed::new(MIN_RTT_WINDOW, Keep::Smallest),
            ceiling_fec_ratio: 0.0,
            sent_total: 0,
            arrived: Arrived::default(),
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
        let sent_in = self.loss.sending_into(now);
        if sent_in == self.loss.id {
            self.loss.sent += layout.data_count as u64;
        } else {
            self.loss.next_sent += layout.data_count as u64;
        }
        stream.unresolved.insert(
            number,
            SentFrame {
                packets,
                resends: vec![Resend::Never; layout.data_count],
                counted_lost: vec![false; layout.data_count],
                guessed_to: 0,
                data_count: layout.data_count,
                submitted: now,
                first_tx: None,
                latest_tx: None,
                last_tx: None,
                originals_out: 0,
                bytes_out: 0,
                sent_before: 0,
                positions: Vec::new(),
                flight_bytes: 0,
                heard: None,
                probe: None,
                probes: 0,
                unanswered: 0,
                expires: None,
                charges: Charges { per_index: vec![None; layout.data_count], sent_in, ..Charges::default() },
            },
        );
        if stream.unresolved.len() > MAX_UNRESOLVED {
            let (oldest, mut dropped) = stream.unresolved.pop_first().expect("over the limit");
            dropped.charges.confirm(Answer::GivenUp, &mut self.estimator);
            self.in_flight_bytes -= dropped.bytes_out;
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
                if long_round_trip || self.recent_loss(now) {
                    (MIN_FEC + 2.0 * self.loss.rate).clamp(MIN_FEC, MAX_FEC)
                } else {
                    0.0
                }
            }
        }
    }

    fn roll_loss_window(&mut self, now: Instant) {
        let started = *self.loss.started.get_or_insert(now);
        let age = now.saturating_duration_since(started);
        if age < LOSS_WINDOW {
            return;
        }
        let answer_due = self.rtt + self.config.frame_interval * IN_FLIGHT_INTERVALS;
        if age < LOSS_WINDOW * 2 && self.losses_still_to_be_answered(self.loss.id, now, answer_due) {
            return;
        }
        self.confirm_unanswered(now);
        let current = if self.loss.sent == 0 { 0.0 } else { self.loss.nacked as f64 / self.loss.sent as f64 };
        if self.loss.sent >= MIN_LOSS_SAMPLE && current > HEAVY_LOSS {
            self.estimator.on_heavy_loss(now, current.min(1.0));
        }
        self.loss.rate = current.max(self.loss.rate / 2.0).min(1.0);
        self.loss = LossWindow {
            id: self.loss.id + 1,
            started: Some(now),
            sent: self.loss.next_sent,
            nacked: self.loss.next_nacked,
            rate: self.loss.rate,
            ..LossWindow::default()
        };
    }

    fn confirm_unanswered(&mut self, now: Instant) {
        let unreported_for = self.unreported_for();
        for stream in self.streams.values_mut() {
            for unreported in stream.unreported.values_mut().filter(|unreported| now >= unreported.resolved + unreported_for) {
                unreported.charges.confirm(Answer::Due(unreported.resolved + unreported_for), &mut self.estimator);
            }
        }
    }

    fn unreported_for(&self) -> Duration {
        self.rtt * 2 + self.config.frame_interval
    }

    fn recent_loss(&self, now: Instant) -> bool {
        let recent = |at: &Instant| now.saturating_duration_since(*at) < FEC_MEMORY;
        self.last_loss.as_ref().is_some_and(recent) || self.nack_losses.values().any(recent)
    }

    fn take_back_late_originals(&mut self, stream_id: u8, number: u32, late: &wire::LateOriginals) {
        let Some(stream) = self.streams.get_mut(&stream_id) else {
            return;
        };
        let charges = match stream.unresolved.get_mut(&number) {
            Some(frame) => &mut frame.charges,
            None => match stream.unreported.get_mut(&number) {
                Some(unreported) => &mut unreported.charges,
                None => return,
            },
        };
        for &(start, count) in late.ranges() {
            let end = (usize::from(start) + usize::from(count)).min(charges.per_index.len());
            let slots = charges.per_index.get_mut(usize::from(start).min(end)..end).unwrap_or_default();
            for charge in slots.iter_mut().filter_map(Option::take) {
                if let Some(nacked) = self.loss.nacked_in(charge.window) {
                    *nacked = nacked.saturating_sub(1);
                }
                if let Some(generation) = charge.arrived_lost {
                    self.arrived.give_back(generation, charge.position, charge.bytes as u64);
                }
            }
        }
        if !charges.standing() {
            charges.counted = None;
            self.nack_losses.remove(&(stream_id, number));
        }
    }

    fn losses_still_to_be_answered(&self, window: u64, now: Instant, answer_due: Duration) -> bool {
        let waiting = |charges: &Charges| {
            charges.counted.is_some_and(|(counted_in, at)| counted_in == window && now < at + answer_due)
        };
        self.streams.values().any(|stream| {
            stream.unresolved.values().any(|frame| waiting(&frame.charges))
                || stream.unreported.values().any(|unreported| waiting(&unreported.charges))
        })
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
        let sent_before = self.sent_total;
        self.sent_total += packet.len() as u64;
        let position = self.sent_total;
        if !tag.original
            && let Some(frame) =
                self.streams.get_mut(&tag.stream).and_then(|stream| stream.unresolved.get_mut(&tag.frame))
            && let Some(resend) = frame.resends.get_mut(usize::from(tag.index))
        {
            let known_bps = self.estimator.measured().then(|| self.estimator.estimate_bps());
            let deep = self.rtt.max(self.config.frame_interval) * DEEP_QUEUE;
            let queued_deep = self.arrived.wait_for(now, position, known_bps).is_some_and(|wait| wait > deep);
            let sent = Resend::Sent { at: now, position, queued_deep };
            if *resend == Resend::Never {
                frame.probe = Some(sent);
            } else {
                *resend = sent;
            }
        }
        if tag.original
            && let Some(frame) =
                self.streams.get_mut(&tag.stream).and_then(|stream| stream.unresolved.get_mut(&tag.frame))
        {
            if frame.first_tx.is_none() {
                frame.first_tx = Some(now);
                frame.sent_before = sent_before;
                if self.in_flight_bytes == 0 {
                    let known_bps = self.estimator.measured().then(|| self.estimator.estimate_bps());
                    let at = now + self.min_rtt.best().unwrap_or(self.rtt);
                    self.arrived.restart(at, sent_before, known_bps);
                }
            }
            frame.positions.push(position);
            frame.latest_tx = Some(now);
            frame.originals_out += 1;
            frame.bytes_out += packet.len();
            self.in_flight_bytes += packet.len();
            self.estimator.on_sent(now, packet.len());
            if frame.originals_out == frame.packets.len() {
                frame.last_tx = Some(now);
                frame.flight_bytes = self.in_flight_bytes;
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
        let asked = |index: usize| {
            nack.ranges.iter().any(|&(start, count)| {
                count == wire::WHOLE_FRAME || (usize::from(start)..usize::from(start) + usize::from(count)).contains(&index)
            })
        };
        let sent = frame.originals_out.min(frame.data_count);
        let ends = nack
            .ranges
            .iter()
            .filter(|&&(_, count)| count != wire::WHOLE_FRAME)
            .map(|&(start, count)| usize::from(start) + usize::from(count));
        let named_to = ends.max();
        if let Some(named_to) = named_to.filter(|named_to| *named_to > sent) {
            frame.guessed_to = frame.guessed_to.max(named_to.min(frame.data_count));
        }
        let named = || {
            nack.ranges.iter().flat_map(|&(start, count)| match count {
                wire::WHOLE_FRAME => 0..sent,
                _ => usize::from(start).min(sent)..(usize::from(start) + usize::from(count)).min(sent),
            })
        };
        let first_time = |index: &usize| frame.resends[*index] == Resend::Never;
        let follows_an_arrival = |index: &usize| index.checked_sub(1).is_none_or(|previous| !asked(previous));
        let sighted =
            named().filter(first_time).filter(follows_an_arrival).filter_map(|index| frame.arrived_before(index)).max();
        if let Some(position) = sighted {
            self.arrived.note(now, position);
        }
        for index in named() {
            if !frame.counted_lost[index] {
                let bytes = frame.packets[index].len() as u64;
                frame.counted_lost[index] = self.arrived.note_lost(frame.positions[index], bytes);
                if let Some(charge) = frame.charges.per_index[index].as_mut() {
                    charge.arrived_lost = frame.counted_lost[index].then_some(self.arrived.generation());
                }
            }
        }
        let known_bps = self.estimator.measured().then(|| self.estimator.estimate_bps());
        let reached = self.arrived.reached(now, known_bps);
        let mut requested = 0;
        let mut first_losses = 0;
        let mut lost_bytes = 0;
        self.loss.started.get_or_insert(now);
        let window = self.loss.counted_in(frame.charges.sent_in);
        let mut repeated = 0;
        let mut held = 0;
        let mut resent_again = false;
        for index in named() {
            let first = frame.resends[index] == Resend::Never;
            if first {
                first_losses += 1;
                let bytes = frame.packets[index].len();
                let position = frame.positions[index];
                let arrived_lost = frame.counted_lost[index].then_some(self.arrived.generation());
                let charge = Charge { window, lost_at: now, position, bytes, arrived_lost };
                frame.charges.per_index[index] = Some(charge);
                if index + 1 == frame.data_count
                    && let Some(probe) = frame.probe
                {
                    frame.resends[index] = probe;
                    frame.charges.per_index[index] = None;
                    frame.charges.fixed = true;
                    lost_bytes += bytes;
                }
            }
            let recent = match frame.resends[index] {
                Resend::Never => false,
                Resend::Queued => true,
                Resend::Sent { at, position, queued_deep } => {
                    let on_its_way = queued_deep && reached.is_some_and(|reached| reached < position);
                    held += u32::from(on_its_way && now >= at + self.rtt / 2 && now < at + MAX_CROSSING);
                    now < at + self.rtt / 2 || on_its_way && now < at + MAX_CROSSING
                }
            };
            if recent {
                repeated += 1;
                continue;
            }
            frame.resends[index] = Resend::Queued;
            let tag = PacketTag { stream: nack.stream, frame: nack.frame, index: index as u16, original: false };
            self.pacer.push(frame.packets[index].clone(), tag);
            requested += 1;
            if !first && let Some(charge) = frame.charges.per_index[index].take() {
                self.estimator.on_lost_earlier(charge.lost_at, charge.bytes, Some(now));
            }
            resent_again |= !first;
        }
        stats.retransmissions_skipped += repeated;
        if first_losses > 0 || held > 0 || requested > 0 {
            frame.heard = Some(now);
            frame.unanswered = 0;
            frame.expires = None;
            frame.flight_bytes = self.in_flight_bytes + self.pacer.backlog_bytes();
        }
        if first_losses > 0 {
            frame.charges.counted = Some((window, now));
            if let Some(nacked) = self.loss.nacked_in(window) {
                *nacked += first_losses;
            }
        }
        frame.charges.fixed |= resent_again;
        if first_losses > 0 || requested > 0 {
            self.estimator.on_lost(now, lost_bytes);
            self.nack_losses.retain(|_, at| now.saturating_duration_since(*at) < FEC_MEMORY);
            self.nack_losses.insert((nack.stream, nack.frame), now);
            self.update_pacing_rate(now);
        }
        stats.packets_retransmitted += requested;
    }

    pub fn on_feedback(&mut self, now: Instant, feedback: &Feedback, events: &mut VecDeque<Event>, stats: &mut Stats) {
        self.confirm_unanswered(now);
        if let Some(receipt) = feedback.receipt.filter(|receipt| !feedback.lost && !receipt.late_originals.is_empty()) {
            self.take_back_late_originals(feedback.stream, feedback.frame, &receipt.late_originals);
        }
        if let Some(unreported) =
            self.streams.get_mut(&feedback.stream).and_then(|stream| stream.unreported.get_mut(&feedback.frame))
        {
            unreported.charges.confirm(Answer::Report(now), &mut self.estimator);
        }
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
        if let Some(mut frame) = stream.unresolved.remove(&feedback.frame) {
            frame.charges.confirm(Answer::Report(now), &mut self.estimator);
            self.in_flight_bytes -= frame.bytes_out;
            if feedback.lost {
                self.last_loss = Some(now);
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: feedback.stream, frame: feedback.frame });
            } else {
                let ack = acknowledge(feedback.stream, feedback.frame, &frame, now, feedback.receipt.map(receipt));
                if let Some(position) = frame.arrived_complete() {
                    self.arrived.note(now, position);
                }
                stats.frames_acked += 1;
                events.push_back(Event::FrameAcked(ack));
            }
            if feedback.receipt.is_some_and(|receipt| receipt.recovery == crate::Recovery::Fec) {
                if let Some(nacked) = self.loss.nacked_in(self.loss.counted_in(frame.charges.sent_in)) {
                    *nacked += 1;
                }
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
            && now.saturating_duration_since(unreported.resolved) <= self.unreported_for()
        {
            self.estimator.on_delivery(now, unreported.sent.delivery(receipt));
        }
        let stream = self.streams.get_mut(&feedback.stream).expect("looked up above");
        while let Some(entry) = stream.unresolved.first_entry() {
            let number = *entry.key();
            if number >= feedback.resolved_below {
                break;
            }
            let mut frame = entry.remove();
            self.in_flight_bytes -= frame.bytes_out;
            let age = feedback.resolved_below - 1 - number;
            if age >= 32 || feedback.lost_bitmap & (1 << age) != 0 {
                frame.charges.confirm(Answer::GivenUp, &mut self.estimator);
                stats.frames_lost += 1;
                events.push_back(Event::FrameLost { stream: feedback.stream, frame: number });
            } else {
                stats.frames_acked += 1;
                self.estimator.on_acked(now, frame.bytes_out);
                if let Some(position) = frame.arrived_complete() {
                    self.arrived.note(now, position);
                }
                events.push_back(Event::FrameAcked(acknowledge(feedback.stream, number, &frame, now, None)));
                if let Some(first) = frame.first_tx {
                    let sent = SendTimes { first, latest: frame.latest_tx };
                    let charges = std::mem::take(&mut frame.charges);
                    stream.unreported.insert(number, Unreported { sent, resolved: now, charges });
                    if stream.unreported.len() > MAX_UNREPORTED
                        && let Some((_, mut evicted)) = stream.unreported.pop_first()
                    {
                        evicted.charges.confirm(Answer::GivenUp, &mut self.estimator);
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
        self.confirm_unanswered(now);
        let waits = self.probe_waits();
        let mut probed = false;
        for (&stream_id, stream) in &mut self.streams {
            let mut expired = Vec::new();
            let newest = stream.next_frame.wrapping_sub(1);
            for (&number, frame) in &mut stream.unresolved {
                let Some(due) = waits.next_wake(frame, number == newest) else {
                    continue;
                };
                if now < due {
                    continue;
                }
                if frame.unanswered == MAX_PROBES {
                    expired.push(number);
                    continue;
                }
                if frame.probes == 0 && number == newest && frame.heard.is_none() {
                    self.tail_backoff = (self.tail_backoff + 1).min(MAX_TAIL_BACKOFF);
                }
                frame.probes += 1;
                frame.unanswered += 1;
                if frame.unanswered == MAX_PROBES {
                    frame.expires = Some(waits.expiry(frame, now, self.estimator.carried_bps(now)));
                }
                stats.probes_sent += 1;
                let index = frame.data_count - 1;
                let tag = PacketTag { stream: stream_id, frame: number, index: index as u16, original: false };
                self.pacer.push(frame.packets[index].clone(), tag);
                if frame.resends[index] == Resend::Never {
                    frame.probe = Some(Resend::Queued);
                }
                probed = true;
            }
            for number in expired {
                if let Some(mut frame) = stream.unresolved.remove(&number) {
                    frame.charges.confirm(Answer::GivenUp, &mut self.estimator);
                    self.in_flight_bytes -= frame.bytes_out;
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

    fn probe_waits(&self) -> ProbeWaits {
        ProbeWaits { tail_probe: self.tail_probe_after(), timeout: self.ack_timeout() }
    }

    fn ack_timeout(&self) -> Duration {
        give_up_after(self.rtt, self.config.frame_interval) + self.rtt + Duration::from_millis(1)
    }

    pub fn poll_timeout(&self, now: Instant) -> Option<Instant> {
        let waits = self.probe_waits();
        let probe = self
            .streams
            .values()
            .flat_map(|stream| {
                let newest = stream.next_frame.wrapping_sub(1);
                stream.unresolved.iter().map(move |(number, frame)| (*number == newest, frame))
            })
            .filter_map(|(newest, frame)| waits.next_wake(frame, newest))
            .min();
        let unreported_for = self.unreported_for();
        let unanswered = self
            .streams
            .values()
            .flat_map(|stream| stream.unreported.values())
            .filter(|unreported| unreported.charges.unconfirmed())
            .map(|unreported| unreported.resolved + unreported_for)
            .min();
        [self.pacer.next_send(now), probe, unanswered].into_iter().flatten().min()
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
            sampled: self.estimator.sampled(),
        }
    }

    pub fn fill_stats(&mut self, now: Instant, stats: &mut Stats) {
        stats.estimate_bps = self.estimator.estimate_bps();
        stats.queue_delay_us = self.estimator.queue_delay_us();
        stats.fec_ratio = self.fec_ratio(now);
        stats.loss_rate = self.loss.rate;
    }
}

#[derive(Debug, Clone, Copy)]
struct ProbeWaits {
    tail_probe: Duration,
    timeout: Duration,
}

impl ProbeWaits {
    fn next_wake(self, frame: &SentFrame, newest: bool) -> Option<Instant> {
        let last_tx = frame.last_tx?;
        let heard = frame.heard.map_or(last_tx, |heard| heard.max(last_tx));
        let first = if newest && frame.heard.is_none() { self.tail_probe } else { self.timeout };
        let due = heard + first + self.timeout * frame.unanswered;
        if frame.unanswered < MAX_PROBES { Some(due) } else { frame.expires.or(Some(due)) }
    }

    fn expiry(self, frame: &SentFrame, last_probe: Instant, carried_bps: f64) -> Instant {
        let heard = [frame.heard, frame.last_tx].into_iter().flatten().max().unwrap_or(last_probe);
        let crossing = Duration::from_secs_f64(frame.flight_bytes as f64 * 8.0 / carried_bps).min(MAX_CROSSING);
        last_probe.max(heard + crossing) + self.timeout
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

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);

    struct Host {
        sender: Sender,
        now: Instant,
        stats: Stats,
        events: VecDeque<Event>,
    }

    impl Host {
        fn with_a_frame_sent(packets: usize) -> Self {
            let mut host = Self::with_a_frame_queued(packets);
            host.drain();
            host
        }

        fn with_a_frame_queued(packets: usize) -> Self {
            let now = Instant::now();
            let config = MediaConfig { fec: FecMode::Off, ..MediaConfig::default() };
            let mut host = Self { sender: Sender::new(config, now), now, stats: Stats::default(), events: VecDeque::new() };
            host.sender.set_rtt(100 * MS);
            let data = vec![7u8; packets * 1_100];
            let frame = OutgoingFrame { data: &data, ..OutgoingFrame::default() };
            host.sender.send_frame(now, frame, 1_200, &mut host.events, &mut host.stats).expect("the frame is valid");
            host
        }

        fn leave(&mut self, packets: usize) {
            for _ in 0..packets {
                self.now = self.sender.pacer.next_send(self.now).expect("a packet is waiting");
                self.sender.poll_transmit(self.now, &mut self.stats).expect("the pacer has credit");
            }
        }

        fn drain(&mut self) {
            while let Some(at) = self.sender.pacer.next_send(self.now) {
                self.now = self.now.max(at);
                self.sender.poll_transmit(self.now, &mut self.stats);
            }
        }

        fn frame(&self) -> &SentFrame {
            &self.sender.streams[&0].unresolved[&0]
        }

        fn asked_for(&mut self, ranges: &[(u16, u16)]) {
            let nack = Nack { stream: 0, frame: 0, ranges: ranges.to_vec() };
            self.sender.on_nack(self.now, &nack, &mut self.stats);
        }

        fn probe(&mut self) {
            self.now = self.sender.poll_timeout(self.now).expect("a probe is due");
            self.sender.handle_timeout(self.now, &mut self.events, &mut self.stats);
        }

        fn send_another(&mut self, packets: usize) {
            let data = vec![9u8; packets * 1_100];
            let frame = OutgoingFrame { data: &data, ..OutgoingFrame::default() };
            self.sender.send_frame(self.now, frame, 1_200, &mut self.events, &mut self.stats).expect("valid");
            self.drain();
        }

        fn reported(&mut self, frame: u32, late: &[u16], resolved_below: u32) {
            let receipt = wire::FrameReceipt {
                first_rx_us: 1,
                last_rx_offset_us: 0,
                complete_offset_us: 0,
                original_bytes: 0,
                recovery: crate::Recovery::Nack,
                late_originals: wire::LateOriginals::from_indices(late.iter().copied()),
            };
            let feedback = Feedback {
                stream: 0,
                frame,
                lost: false,
                receipt: Some(receipt),
                resolved_below,
                lost_bitmap: 0,
                ltr_token: None,
            };
            self.sender.on_feedback(self.now, &feedback, &mut self.events, &mut self.stats);
        }
    }

    #[test]
    fn a_late_original_takes_its_loss_back_from_the_window_the_estimate_and_the_fec_trigger() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 2)]);
        assert_eq!(host.sender.loss.nacked, 2);
        assert!(host.sender.recent_loss(host.now));
        assert_eq!(host.sender.estimator.lost_bytes(), 0, "held out until the frame is answered");

        host.now += 30 * MS;
        host.reported(0, &[4, 5], 1);

        assert_eq!(host.sender.loss.nacked, 0);
        assert_eq!(host.sender.estimator.lost_bytes(), 0);
        assert!(!host.sender.recent_loss(host.now), "nothing was lost, so FEC has nothing to answer");
    }

    #[test]
    fn a_late_original_beside_a_real_loss_keeps_the_fec_trigger() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 2)]);

        host.now += 30 * MS;
        host.reported(0, &[4], 1);

        assert_eq!(host.sender.loss.nacked, 1);
        assert!(host.sender.recent_loss(host.now), "packet 5 was really lost");
    }

    #[test]
    fn two_frames_whose_requests_were_both_only_late_leave_no_loss_whichever_reports_first() {
        for first_report in [0, 1] {
            let mut host = Host::with_a_frame_sent(10);
            host.send_another(10);
            host.asked_for(&[(4, 1)]);
            host.now += 5 * MS;
            host.sender.on_nack(host.now, &Nack { stream: 0, frame: 1, ranges: vec![(4, 1)] }, &mut host.stats);

            host.now += 30 * MS;
            host.reported(first_report, &[4], 0);
            host.reported(1 - first_report, &[4], 2);

            assert_eq!(host.sender.loss.nacked, 0, "frame {first_report} reported first");
            assert!(!host.sender.recent_loss(host.now), "frame {first_report} reported first");
        }
    }

    #[test]
    fn a_frame_whose_requests_were_only_late_doesnt_clear_another_frames_real_loss() {
        let mut host = Host::with_a_frame_sent(10);
        host.send_another(10);
        host.asked_for(&[(4, 1)]);
        host.now += 5 * MS;
        host.sender.on_nack(host.now, &Nack { stream: 0, frame: 1, ranges: vec![(4, 1)] }, &mut host.stats);
        host.now += 5 * MS;
        host.asked_for(&[(6, 1)]);

        host.now += 30 * MS;
        host.reported(0, &[4, 6], 0);

        assert_eq!(host.sender.loss.nacked, 1);
        assert!(host.sender.recent_loss(host.now), "frame 1 really lost packet 4");
    }

    #[test]
    fn only_the_losses_still_standing_when_a_frame_is_answered_reach_the_estimate() {
        let mut host = Host::with_a_frame_sent(10);
        host.send_another(10);
        host.asked_for(&[(4, 3)]);
        host.sender.on_nack(host.now, &Nack { stream: 0, frame: 1, ranges: vec![(2, 1)] }, &mut host.stats);
        let real = host.sender.streams[&0].unresolved[&1].packets[2].len();
        assert_eq!(host.sender.estimator.lost_bytes(), 0);

        host.now += 30 * MS;
        host.reported(0, &[4, 5, 6], 0);
        host.reported(1, &[], 2);

        assert_eq!(host.sender.estimator.lost_bytes(), real);
    }

    #[test]
    fn a_late_original_gives_its_bytes_back_to_the_arrival_count() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(5, 1)]);
        host.now += 101 * MS;
        host.asked_for(&[(8, 1)]);
        host.asked_for(&[(5, 1)]);
        assert_eq!(host.sender.arrived.lost(), host.frame().packets[5].len() as u64);

        host.reported(0, &[5], 1);

        assert_eq!(host.sender.arrived.lost(), 0);
    }

    #[test]
    fn a_frame_resolved_early_is_not_confirmed_by_the_roll_while_its_own_report_can_still_come() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 1)]);
        host.send_another(5);
        host.reported(1, &[], 2);
        host.now += 100 * MS;
        host.sender.loss.started = Some(host.now - LOSS_WINDOW * 2);
        host.sender.fec_ratio(host.now);

        host.reported(0, &[4], 1);

        assert_eq!(host.sender.estimator.lost_bytes(), 0);
    }

    #[test]
    fn a_frame_resolved_early_whose_own_report_never_comes_reaches_the_drop_check_once_its_wait_is_over() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 1)]);
        host.send_another(5);
        host.reported(1, &[], 2);
        let lost = host.sender.streams[&0].unreported[&0].charges.per_index[4].map_or(0, |charge| charge.bytes);
        let due = host.sender.poll_timeout(host.now).expect("the unanswered frame is due");
        assert!(due <= host.now + host.sender.unreported_for());

        host.now = due;
        host.sender.handle_timeout(host.now, &mut host.events, &mut host.stats);
        host.now += 400 * MS;
        host.send_another(5);

        assert_eq!(host.sender.estimator.lost_bytes_in_drop_check(), lost);
    }

    #[test]
    fn a_late_report_after_the_loss_was_confirmed_takes_nothing_back() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 1)]);
        host.send_another(5);
        host.reported(1, &[], 2);
        host.now += host.sender.unreported_for() + MS;
        host.sender.handle_timeout(host.now, &mut host.events, &mut host.stats);

        host.reported(0, &[4], 1);

        assert_eq!(host.sender.loss.nacked, 1, "the estimate already has it as a loss");
        assert!(host.sender.recent_loss(host.now));
    }

    #[test]
    fn a_frame_parity_repaired_counts_in_the_window_it_was_sent_in() {
        let mut host = Host::with_a_frame_sent(10);
        host.sender.loss.started = Some(host.now - LOSS_WINDOW - 10 * MS);
        host.asked_for(&[(2, 1)]);
        host.send_another(10);
        let fec = |host: &mut Host| {
            let receipt = wire::FrameReceipt {
                first_rx_us: 1,
                last_rx_offset_us: 0,
                complete_offset_us: 0,
                original_bytes: 0,
                recovery: crate::Recovery::Fec,
                late_originals: wire::LateOriginals::default(),
            };
            let feedback =
                Feedback { stream: 0, frame: 1, lost: false, receipt: Some(receipt), resolved_below: 0, lost_bitmap: 0, ltr_token: None };
            host.sender.on_feedback(host.now, &feedback, &mut host.events, &mut host.stats);
        };

        fec(&mut host);

        assert_eq!((host.sender.loss.nacked, host.sender.loss.next_nacked), (1, 1));
    }

    #[test]
    fn a_frame_sent_after_its_window_ended_counts_with_its_losses_in_the_next_window() {
        let mut host = Host::with_a_frame_sent(10);
        host.sender.loss.started = Some(host.now - LOSS_WINDOW - 10 * MS);
        host.asked_for(&[(2, 1)]);
        host.send_another(10);
        host.sender.on_nack(host.now, &Nack { stream: 0, frame: 1, ranges: vec![(0, 8)] }, &mut host.stats);
        assert_eq!((host.sender.loss.sent, host.sender.loss.nacked), (10, 1));

        host.now += 200 * MS;
        host.sender.fec_ratio(host.now);

        assert_eq!((host.sender.loss.sent, host.sender.loss.nacked), (10, 8));
    }

    #[test]
    fn an_ended_window_waits_for_the_report_on_a_request_that_came_during_its_wait() {
        let mut host = Host::with_a_frame_sent(10);
        host.send_another(10);
        host.sender.loss.sent = 40;
        host.sender.loss.started = Some(host.now - LOSS_WINDOW + 10 * MS);
        host.asked_for(&[(2, 1)]);
        host.now += 90 * MS;
        host.sender.on_nack(host.now, &Nack { stream: 0, frame: 1, ranges: vec![(0, 8)] }, &mut host.stats);
        host.now += 90 * MS;
        host.sender.fec_ratio(host.now);
        assert_eq!(host.sender.loss.nacked, 9, "the window is still waiting for frame 1's report");

        host.reported(1, &(0..8).collect::<Vec<_>>(), 0);
        host.now += 200 * MS;
        host.sender.fec_ratio(host.now);

        assert!(host.sender.loss.rate < HEAVY_LOSS, "the window read {:.2}", host.sender.loss.rate);
    }

    #[test]
    fn a_packet_sent_again_for_a_repeated_request_stays_a_loss_even_if_reported_late() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 1)]);
        host.drain();
        host.now += 101 * MS;
        host.asked_for(&[(4, 1)]);
        assert_eq!(host.stats.packets_retransmitted, 2);

        host.now += 30 * MS;
        host.reported(0, &[4], 1);

        assert!(host.sender.recent_loss(host.now), "its first resend was lost too");
        assert_eq!(host.sender.loss.nacked, 1);
    }

    #[test]
    fn a_late_original_charged_in_the_window_before_still_comes_off_the_estimate() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 1)]);
        host.now += 300 * MS;
        host.sender.loss.started = Some(host.now - LOSS_WINDOW - 300 * MS);
        host.sender.fec_ratio(host.now);
        assert_eq!(host.sender.loss.nacked, 0, "the window rolled");

        host.now += 20 * MS;
        host.reported(0, &[4], 1);

        assert_eq!(host.sender.estimator.lost_bytes(), 0);
        assert!(!host.sender.recent_loss(host.now));
    }

    #[test]
    fn a_tail_probe_out_keeps_the_fec_trigger_on_when_the_frames_other_losses_were_late() {
        let mut host = Host::with_a_frame_sent(10);
        host.probe();
        host.drain();
        host.asked_for(&[(5, 1), (9, 1)]);

        host.now += 10 * MS;
        host.reported(0, &[5], 1);

        assert_eq!(host.sender.loss.nacked, 1);
        assert!(host.sender.recent_loss(host.now), "the last packet's loss can't be taken back");
    }

    #[test]
    fn the_window_waits_for_a_frame_another_report_resolved_before_its_own_arrived() {
        let mut host = Host::with_a_frame_sent(10);
        host.send_another(5);
        for _ in 0..30 {
            host.sender.loss.sent += 1;
        }
        host.sender.loss.started = Some(host.now - LOSS_WINDOW + 10 * MS);
        host.asked_for(&[(0, 10)]);
        host.now += 20 * MS;
        host.reported(1, &[], 2);
        assert!(!host.sender.streams[&0].unresolved.contains_key(&0));
        host.sender.fec_ratio(host.now);

        host.now += 5 * MS;
        host.reported(0, &(0..10).collect::<Vec<_>>(), 2);

        assert_eq!(host.sender.loss.nacked, 0, "the take-back landed in the window it was charged in");
        assert_eq!(host.sender.loss.rate, 0.0, "the window didn't roll with the late packets counted as lost");
    }

    #[test]
    fn a_request_answered_by_the_tail_probes_copy_is_not_taken_back_as_late() {
        let mut host = Host::with_a_frame_sent(10);
        host.probe();
        host.drain();
        host.asked_for(&[(9, 1)]);
        assert_eq!(host.sender.loss.nacked, 1);

        host.now += 10 * MS;
        host.reported(0, &[9], 1);

        assert_eq!(host.sender.loss.nacked, 1, "the probe's copy arrived early, not the lost original");
    }

    #[test]
    fn a_frame_resolved_by_a_later_frames_report_still_takes_back_its_late_originals() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(4, 1)]);
        host.send_another(5);
        host.reported(1, &[], 2);
        assert!(!host.sender.streams[&0].unresolved.contains_key(&0));

        host.reported(0, &[4], 1);

        assert_eq!(host.sender.loss.nacked, 0);
    }

    #[test]
    fn a_packet_is_counted_lost_once_it_is_still_asked_for_with_the_reach_past_it() {
        let mut host = Host::with_a_frame_sent(10);
        let packet = host.frame().packets[5].len() as u64;

        host.asked_for(&[(5, 1)]);
        host.drain();
        host.now += 101 * MS;
        host.asked_for(&[(5, 1)]);
        assert_eq!(host.sender.arrived.lost(), 0, "nothing after it is known to have arrived: it may only be late");

        host.asked_for(&[(8, 1)]);
        host.asked_for(&[(5, 1)]);
        host.asked_for(&[(5, 1)]);
        assert_eq!(host.sender.arrived.lost(), packet, "7 arrived and 5 is still missing");
    }

    #[test]
    fn packets_named_behind_what_the_same_request_shows_arrived_are_lost_at_once() {
        let mut host = Host::with_a_frame_sent(10);
        let behind = (host.frame().packets[2].len() + host.frame().packets[3].len()) as u64;

        host.asked_for(&[(2, 2), (7, 1), (2, 2)]);

        assert_eq!(host.sender.arrived.lost(), behind, "2 and 3 are behind packet 6, which arrived; 7 may only be late");
        assert_eq!(host.stats.packets_retransmitted, 3);
    }

    #[test]
    fn a_packet_the_viewer_asked_for_before_it_was_sent_is_never_taken_as_arrived() {
        let mut host = Host::with_a_frame_queued(12);
        host.leave(5);
        host.asked_for(&[(3, 4)]);
        host.drain();
        assert_eq!(host.sender.arrived.position(), Some(0), "the viewer is guessing: 5 and 6 hadn't left");

        host.asked_for(&[(7, 1)]);
        assert_eq!(host.sender.arrived.position(), Some(0), "6 was asked for before it was sent");

        host.asked_for(&[(9, 1)]);
        assert_eq!(host.sender.arrived.position(), Some(host.frame().positions[8]));
    }

    #[test]
    fn the_first_request_for_a_probed_packet_is_an_answer_and_a_loss_counted_once() {
        let mut host = Host::with_a_frame_sent(10);
        host.probe();
        host.drain();
        assert_eq!(host.frame().unanswered, 1);

        host.now += 10 * MS;
        host.asked_for(&[(9, 1)]);
        assert_eq!(host.stats.packets_retransmitted, 0, "the probe left 10 ms ago");
        assert_eq!((host.frame().heard, host.frame().unanswered), (Some(host.now), 0));
        assert_eq!(host.sender.loss.nacked, 1);

        host.now += 101 * MS;
        host.asked_for(&[(9, 1)]);
        host.drain();
        host.now += 101 * MS;
        host.asked_for(&[(9, 1)]);
        assert_eq!(host.sender.loss.nacked, 1);
        assert_eq!(host.stats.packets_retransmitted, 2);
    }

    #[test]
    fn a_repeat_the_host_sends_again_is_an_answer() {
        let mut host = Host::with_a_frame_sent(10);
        host.asked_for(&[(5, 1)]);
        host.drain();
        for _ in 0..2 {
            host.probe();
            host.drain();
        }
        assert_eq!(host.frame().unanswered, 2);

        host.asked_for(&[(5, 1)]);

        assert_eq!(host.stats.packets_retransmitted, 2);
        assert_eq!((host.frame().heard, host.frame().unanswered), (Some(host.now), 0));
    }

    #[test]
    fn a_whole_frame_request_doesnt_make_the_viewer_look_like_it_is_guessing_past_what_was_sent() {
        let mut host = Host::with_a_frame_queued(12);
        host.leave(5);
        host.sender.on_nack(host.now, &Nack::whole_frame(0, 0), &mut host.stats);
        host.drain();

        host.asked_for(&[(9, 1)]);

        assert_eq!(host.sender.arrived.position(), Some(host.frame().positions[8]));
    }

    #[test]
    fn a_request_that_arrives_while_the_probe_waits_to_leave_doesnt_queue_a_second_copy() {
        let mut host = Host::with_a_frame_sent(10);
        host.probe();

        host.asked_for(&[(9, 1)]);

        assert_eq!((host.stats.packets_retransmitted, host.stats.retransmissions_skipped), (0, 1));
    }

    #[test]
    fn the_wait_for_what_was_in_flight_runs_from_the_end_of_the_send_when_the_viewer_answered_before_it() {
        let start = Instant::now();
        let second = Duration::from_secs(1);
        let frame = SentFrame {
            packets: Vec::new(),
            resends: Vec::new(),
            counted_lost: Vec::new(),
            guessed_to: 0,
            data_count: 0,
            submitted: start,
            first_tx: Some(start),
            latest_tx: Some(start + 2 * second),
            last_tx: Some(start + 2 * second),
            originals_out: 0,
            bytes_out: 0,
            sent_before: 0,
            positions: Vec::new(),
            flight_bytes: 125_000,
            heard: Some(start + second / 4),
            probe: None,
            probes: MAX_PROBES,
            unanswered: MAX_PROBES,
            expires: None,
            charges: Charges::default(),
        };
        let waits = ProbeWaits { tail_probe: second / 10, timeout: second / 5 };

        let expiry = waits.expiry(&frame, start + 2 * second + second / 10, 1e6);

        assert_eq!(expiry, start + 3 * second + second / 5, "1 s to cross from the last packet, then one timeout");
    }
}
