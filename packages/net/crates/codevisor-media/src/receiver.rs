use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    time::{Duration, Instant},
};

use bytes::{Bytes, BytesMut};

use crate::{
    fec::{self, Layout},
    types::{Event, ReceivedFrame, Stats, give_up_after},
    wire::{self, Feedback, FrameFields, FrameReceipt, Kind, Nack, PacketHeader, Recovery},
};

const MAX_AHEAD: u32 = 64;
const OUTCOME_MEMORY: usize = 64;
const MIN_TAIL_WAIT: Duration = Duration::from_millis(1);
const TAIL_GAPS: f64 = 1.5;
const GAP_DECAY: f64 = 15.0 / 16.0;
const RETRY_MARGIN: Duration = Duration::from_millis(1);

#[derive(Debug)]
struct Assembly {
    shape: Option<Shape>,
    data: Vec<Option<Bytes>>,
    parity: Vec<Option<Bytes>>,
    received: usize,
    requested: Vec<Option<Instant>>,
    first_rx: Option<Instant>,
    last_original_rx: Option<Instant>,
    original_bytes: usize,
    last_rx: Option<Instant>,
    end_seen: bool,
    highest_index: Option<u16>,
    tail_at: Option<Instant>,
    next_nack: Option<Instant>,
    give_up_at: Option<Instant>,
    used_fec: bool,
    state: State,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Shape {
    layout: Layout,
    parity_count: usize,
}

#[derive(Debug)]
enum State {
    Assembling,
    Complete { payload: Bytes, at: Instant },
    GivenUp,
}

impl Assembly {
    fn unknown() -> Self {
        Self {
            shape: None,
            data: Vec::new(),
            parity: Vec::new(),
            received: 0,
            requested: Vec::new(),
            first_rx: None,
            last_original_rx: None,
            original_bytes: 0,
            last_rx: None,
            end_seen: true,
            highest_index: None,
            tail_at: None,
            next_nack: None,
            give_up_at: None,
            used_fec: false,
            state: State::Assembling,
        }
    }

    fn recovery(&self) -> Recovery {
        if self.requested.iter().any(Option::is_some) || (self.shape.is_none() && self.give_up_at.is_some()) {
            Recovery::Nack
        } else if self.used_fec {
            Recovery::Fec
        } else {
            Recovery::None
        }
    }

    fn wanted(&self) -> Vec<u16> {
        let Some(shape) = self.shape else {
            return Vec::new();
        };
        let limit = if self.end_seen {
            shape.layout.data_count
        } else {
            usize::from(self.highest_index.unwrap_or(0)).min(shape.layout.data_count)
        };
        let missing = (0..limit).filter(|index| self.data[*index].is_none());
        if shape.parity_count > 0 {
            if !self.end_seen {
                return Vec::new();
            }
            let short = shape.layout.data_count.saturating_sub(self.received);
            missing.take(short).map(|index| index as u16).collect()
        } else {
            missing.map(|index| index as u16).collect()
        }
    }

    fn due(&self, now: Instant, retry: Duration) -> Vec<u16> {
        let mut wanted = self.wanted();
        wanted.retain(|index| self.requested[usize::from(*index)].is_none_or(|at| now >= at + retry));
        wanted
    }
}

#[derive(Debug, Clone, Copy)]
struct Outcome {
    lost: bool,
    receipt: Option<FrameReceipt>,
}

#[derive(Debug, Default)]
struct StreamRx {
    next_due: u32,
    lost_bitmap: u32,
    frames: BTreeMap<u32, Assembly>,
    outcomes: BTreeMap<u32, Outcome>,
    ltr_token: Option<u64>,
    answered: Option<(u32, Instant)>,
}

#[derive(Debug)]
pub struct Receiver {
    epoch: Instant,
    frame_interval: Duration,
    rtt: Duration,
    streams: HashMap<u8, StreamRx>,
    gap_peak: Duration,
    outbox: VecDeque<Bytes>,
}

impl Receiver {
    pub fn new(frame_interval: Duration, epoch: Instant) -> Self {
        Self {
            epoch,
            frame_interval,
            rtt: Duration::ZERO,
            streams: HashMap::new(),
            gap_peak: Duration::ZERO,
            outbox: VecDeque::new(),
        }
    }

    pub fn set_rtt(&mut self, rtt: Duration) {
        self.rtt = rtt;
    }

    pub fn poll_transmit(&mut self) -> Option<Bytes> {
        self.outbox.pop_front()
    }

    fn give_up_after(&self) -> Duration {
        give_up_after(self.rtt, self.frame_interval)
    }

    fn retry_after(&self) -> Duration {
        self.rtt + RETRY_MARGIN
    }

    fn tail_wait(&self) -> Duration {
        self.gap_peak.mul_f64(TAIL_GAPS).max(MIN_TAIL_WAIT).min(self.give_up_after())
    }

    pub fn on_packet(
        &mut self,
        now: Instant,
        header: PacketHeader,
        shard: Bytes,
        events: &mut VecDeque<Event>,
        stats: &mut Stats,
    ) {
        stats.packets_received += 1;
        stats.bytes_received += shard.len() as u64 + crate::wire::HEADER_BYTES as u64;
        let tail_wait = self.tail_wait();
        let stream = self.streams.entry(header.stream).or_default();
        if header.frame < stream.next_due {
            stats.duplicate_packets += 1;
            self.answer_resolved(now, header.stream, header.frame);
            return;
        }
        if header.frame - stream.next_due > MAX_AHEAD {
            skip_to(header.stream, stream, header.frame - MAX_AHEAD, events, stats);
        }
        for number in stream.next_due..header.frame {
            let assembly = stream.frames.entry(number).or_insert_with(Assembly::unknown);
            if matches!(assembly.state, State::Assembling) {
                if !assembly.end_seen || assembly.shape.is_none() && assembly.next_nack.is_none() {
                    assembly.next_nack.get_or_insert(now);
                }
                assembly.end_seen = true;
            }
        }
        let placeholder = stream.frames.contains_key(&header.frame);
        let assembly = stream.frames.entry(header.frame).or_insert_with(Assembly::unknown);
        if !matches!(assembly.state, State::Assembling) {
            stats.duplicate_packets += 1;
            self.answer_resolved(now, header.stream, header.frame);
            return;
        }
        let shape = match Layout::new(header.frame_len as usize, usize::from(header.data_count)) {
            Ok(layout) => Shape { layout, parity_count: usize::from(header.parity_count) },
            Err(_) => {
                stats.invalid_datagrams += 1;
                return;
            }
        };
        match assembly.shape {
            None => {
                let requested = assembly.give_up_at.map(|_| now);
                *assembly = Assembly {
                    shape: Some(shape),
                    data: vec![None; shape.layout.data_count],
                    parity: vec![None; shape.parity_count],
                    requested: vec![requested; shape.layout.data_count],
                    end_seen: placeholder,
                    give_up_at: assembly.give_up_at,
                    next_nack: assembly.next_nack,
                    ..Assembly::unknown()
                };
            }
            Some(known) if known != shape => {
                stats.invalid_datagrams += 1;
                return;
            }
            Some(_) => {}
        }
        let index = usize::from(header.index);
        let (slot, expected_len) = if header.kind == Kind::Data {
            (&mut assembly.data[index], shape.layout.data_range(index).len())
        } else {
            (&mut assembly.parity[index - shape.layout.data_count], shape.layout.shard_len)
        };
        if shard.len() != expected_len {
            stats.invalid_datagrams += 1;
            return;
        }
        if slot.is_some() {
            stats.duplicate_packets += 1;
            return;
        }
        let datagram_len = shard.len() + wire::HEADER_BYTES;
        *slot = Some(shard);
        assembly.received += 1;
        let retransmission = header.kind == Kind::Data && assembly.requested[index].is_some();
        if !retransmission {
            if assembly.first_rx.is_some() {
                assembly.original_bytes += datagram_len;
            }
            if let Some(last) = assembly.last_original_rx {
                self.gap_peak = self.gap_peak.max(now.saturating_duration_since(last));
            }
            assembly.last_original_rx = Some(now);
        }
        assembly.first_rx.get_or_insert(now);
        assembly.last_rx = Some(now);
        let last_index = shape.layout.data_count + shape.parity_count - 1;
        if usize::from(header.index) == last_index {
            assembly.end_seen = true;
        }
        let gap_seen = assembly.highest_index.is_some_and(|highest| header.index > highest + 1)
            || assembly.highest_index.is_none() && header.index > 0;
        assembly.highest_index = Some(assembly.highest_index.map_or(header.index, |highest| highest.max(header.index)));
        assembly.tail_at = Some(now + tail_wait);

        if try_complete(assembly, now, stats) {
            self.on_resolved(&[(header.stream, header.frame)], events, stats);
        } else if (gap_seen || assembly.end_seen) && !assembly.due(now, self.rtt + RETRY_MARGIN).is_empty() {
            assembly.next_nack = Some(now);
        }
        self.drain(header.stream, events, stats);
    }

    pub fn ack_ltr(&mut self, stream_id: u8, token: u64) {
        let stream = self.streams.entry(stream_id).or_default();
        stream.ltr_token = Some(token);
        let last = stream.next_due.checked_sub(1);
        let report = match last.and_then(|frame| Some((frame, *stream.outcomes.get(&frame)?))) {
            Some((frame, outcome)) => feedback(stream_id, stream, frame, outcome),
            None => feedback(stream_id, stream, wire::NO_FRAME, Outcome { lost: false, receipt: None }),
        };
        self.outbox.push_back(report.encode());
    }

    pub fn handle_timeout(&mut self, now: Instant, events: &mut VecDeque<Event>, stats: &mut Stats) {
        let give_up = self.give_up_after();
        let retry = self.retry_after();
        let mut resolved = Vec::new();
        for (&stream_id, stream) in &mut self.streams {
            for (&number, assembly) in &mut stream.frames {
                if !matches!(assembly.state, State::Assembling) {
                    continue;
                }
                if assembly.give_up_at.is_some_and(|at| now >= at) {
                    assembly.state = State::GivenUp;
                    resolved.push((stream_id, number));
                    continue;
                }
                if assembly.tail_at.is_some_and(|at| now >= at) && !assembly.end_seen {
                    assembly.end_seen = true;
                    assembly.next_nack = Some(now);
                }
                if assembly.next_nack.is_some_and(|at| now >= at) {
                    let nack = match assembly.shape {
                        None => Some(Nack::whole_frame(stream_id, number)),
                        Some(_) => {
                            let due = assembly.due(now, retry);
                            for index in &due {
                                assembly.requested[usize::from(*index)] = Some(now);
                            }
                            (!due.is_empty()).then(|| Nack::from_indices(stream_id, number, due))
                        }
                    };
                    if let Some(nack) = nack {
                        stats.nacks_sent += 1;
                        self.outbox.push_back(nack.encode());
                        assembly.give_up_at.get_or_insert(now + give_up);
                    }
                    let wanted = assembly.wanted();
                    let oldest = wanted.iter().filter_map(|index| assembly.requested[usize::from(*index)]).min();
                    let outstanding = assembly.shape.is_none() || !wanted.is_empty();
                    assembly.next_nack = outstanding.then(|| oldest.unwrap_or(now) + retry);
                }
            }
        }
        self.on_resolved(&resolved, events, stats);
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        self.streams
            .values()
            .flat_map(|stream| stream.frames.values())
            .filter(|assembly| matches!(assembly.state, State::Assembling))
            .flat_map(|assembly| {
                let tail = assembly.tail_at.filter(|_| !assembly.end_seen);
                [tail, assembly.next_nack, assembly.give_up_at]
            })
            .flatten()
            .min()
    }

    fn on_resolved(&mut self, resolved: &[(u8, u32)], events: &mut VecDeque<Event>, stats: &mut Stats) {
        let outcomes: Vec<Outcome> =
            resolved.iter().map(|&(stream_id, number)| self.record_outcome(stream_id, number)).collect();
        for &(stream_id, _) in resolved {
            self.drain(stream_id, events, stats);
        }
        for (&(stream_id, number), outcome) in resolved.iter().zip(outcomes) {
            let stream = &self.streams[&stream_id];
            self.outbox.push_back(feedback(stream_id, stream, number, outcome).encode());
        }
    }

    fn record_outcome(&mut self, stream_id: u8, number: u32) -> Outcome {
        let epoch = self.epoch;
        let stream = self.streams.get_mut(&stream_id).expect("resolved frames belong to a stream");
        let assembly = &stream.frames[&number];
        let receipt = |completed: Option<Instant>| {
            let first = assembly.first_rx?;
            Some(FrameReceipt {
                first_rx_us: first.saturating_duration_since(epoch).as_micros() as u64,
                last_rx_offset_us: micros(assembly.last_original_rx.unwrap_or(first) - first),
                complete_offset_us: completed.map_or(0, |at| micros(at - first)),
                original_bytes: assembly.original_bytes.min(u32::MAX as usize) as u32,
                recovery: assembly.recovery(),
            })
        };
        let outcome = match &assembly.state {
            State::Complete { at, .. } => Outcome { lost: false, receipt: receipt(Some(*at)) },
            State::GivenUp => Outcome { lost: true, receipt: receipt(None) },
            State::Assembling => unreachable!("only resolved frames get here"),
        };
        stream.outcomes.insert(number, outcome);
        self.gap_peak = self.gap_peak.mul_f64(GAP_DECAY);
        outcome
    }

    fn drain(&mut self, stream_id: u8, events: &mut VecDeque<Event>, stats: &mut Stats) {
        let Some(stream) = self.streams.get_mut(&stream_id) else {
            return;
        };
        while let Some(entry) = stream.frames.first_entry() {
            if *entry.key() != stream.next_due || matches!(entry.get().state, State::Assembling) {
                break;
            }
            let (frame, assembly) = entry.remove_entry();
            let lost = deliver(stream_id, frame, assembly, events);
            if lost {
                stats.frames_skipped += 1;
                stream.outcomes.insert(frame, Outcome { lost: true, receipt: None });
            } else {
                stats.frames_received += 1;
            }
            stream.lost_bitmap = stream.lost_bitmap << 1 | u32::from(lost);
            stream.next_due += 1;
        }
        while stream.outcomes.len() > OUTCOME_MEMORY {
            stream.outcomes.pop_first();
        }
    }

    fn answer_resolved(&mut self, now: Instant, stream_id: u8, number: u32) {
        let retry = self.retry_after();
        let stream = self.streams.get_mut(&stream_id).expect("caller looked it up");
        let Some(outcome) = stream.outcomes.get(&number).copied() else {
            return;
        };
        if stream.answered.is_some_and(|(frame, at)| frame == number && now < at + retry) {
            return;
        }
        stream.answered = Some((number, now));
        self.outbox.push_back(feedback(stream_id, stream, number, outcome).encode());
    }
}

fn micros(duration: Duration) -> u32 {
    duration.as_micros().min(u128::from(u32::MAX)) as u32
}

fn feedback(stream_id: u8, stream: &StreamRx, frame: u32, outcome: Outcome) -> Feedback {
    Feedback {
        stream: stream_id,
        frame,
        lost: outcome.lost,
        receipt: outcome.receipt,
        resolved_below: stream.next_due,
        lost_bitmap: stream.lost_bitmap,
        ltr_token: stream.ltr_token,
    }
}

fn try_complete(assembly: &mut Assembly, now: Instant, stats: &mut Stats) -> bool {
    let Some(shape) = assembly.shape else { return false };
    let data_received = assembly.data.iter().filter(|shard| shard.is_some()).count();
    if data_received < shape.layout.data_count {
        if assembly.received < shape.layout.data_count {
            return false;
        }
        let data: Vec<(usize, &[u8])> =
            assembly.data.iter().enumerate().filter_map(|(index, shard)| Some((index, &shard.as_ref()?[..]))).collect();
        let parity: Vec<(usize, &[u8])> = assembly
            .parity
            .iter()
            .enumerate()
            .filter_map(|(index, shard)| Some((index, &shard.as_ref()?[..])))
            .collect();
        let Ok(restored) = fec::recover(shape.layout, shape.parity_count, &data, &parity) else {
            stats.invalid_datagrams += 1;
            assembly.state = State::GivenUp;
            return true;
        };
        for (index, shard) in restored {
            assembly.data[index] = Some(Bytes::from(shard));
        }
        assembly.used_fec = true;
        stats.fec_recoveries += 1;
    }
    let mut payload = BytesMut::with_capacity(shape.layout.frame_len);
    for shard in &assembly.data {
        payload.extend_from_slice(shard.as_ref().expect("every data shard is present"));
    }
    assembly.data.clear();
    assembly.parity.clear();
    let payload = payload.freeze();
    assembly.state = if FrameFields::parse(payload.clone()).is_some() {
        State::Complete { payload, at: now }
    } else {
        stats.invalid_datagrams += 1;
        State::GivenUp
    };
    true
}

fn skip_to(stream_id: u8, stream: &mut StreamRx, keep_from: u32, events: &mut VecDeque<Event>, stats: &mut Stats) {
    let mut last_reported = None;
    while let Some(entry) = stream.frames.first_entry() {
        if *entry.key() >= keep_from {
            break;
        }
        let (frame, mut assembly) = entry.remove_entry();
        if matches!(assembly.state, State::Assembling) {
            assembly.state = State::GivenUp;
        }
        if deliver(stream_id, frame, assembly, events) {
            stats.frames_skipped += 1;
        } else {
            stats.frames_received += 1;
        }
        last_reported = Some(frame);
    }
    if last_reported != Some(keep_from - 1) {
        events.push_back(Event::FrameSkipped { stream: stream_id, frame: keep_from - 1 });
        stats.frames_skipped += 1;
    }
    let (old_due, old_bitmap) = (stream.next_due, stream.lost_bitmap);
    let mut bitmap = 0;
    for age in 0..32 {
        let Some(frame) = keep_from.checked_sub(1 + age) else { break };
        let lost = if frame < old_due {
            let old_age = old_due - 1 - frame;
            old_age < 32 && old_bitmap & (1 << old_age) != 0
        } else {
            stream.outcomes.entry(frame).or_insert(Outcome { lost: true, receipt: None }).lost
        };
        bitmap |= u32::from(lost) << age;
    }
    stream.next_due = keep_from;
    stream.lost_bitmap = bitmap;
}

fn deliver(stream: u8, frame: u32, assembly: Assembly, events: &mut VecDeque<Event>) -> bool {
    let recovery = assembly.recovery();
    match assembly.state {
        State::Complete { payload, at } => match FrameFields::parse(payload) {
            Some((fields, data)) => {
                events.push_back(Event::Frame(ReceivedFrame {
                    stream,
                    frame,
                    keyframe: fields.keyframe,
                    ltr_token: fields.ltr_token,
                    meta: fields.meta,
                    data,
                    first_packet_at: assembly.first_rx.unwrap_or(at),
                    completed_at: at,
                    recovery,
                }));
                false
            }
            None => {
                events.push_back(Event::FrameSkipped { stream, frame });
                true
            }
        },
        State::GivenUp => {
            events.push_back(Event::FrameSkipped { stream, frame });
            true
        }
        State::Assembling => unreachable!("only resolved frames are delivered"),
    }
}
