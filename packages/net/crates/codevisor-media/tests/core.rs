use std::{
    cmp::Reverse,
    collections::BinaryHeap,
    time::{Duration, Instant},
};

use bytes::Bytes;
use codevisor_media::{
    Core, Event, FecMode, FrameAck, MediaConfig, OutgoingFrame, ReceivedFrame, Recovery, fec,
    netsim::{Fate, NetworkConditions, NetworkModel, SplitMix64},
    wire::{self, Kind, PacketHeader},
};

const MS: Duration = Duration::from_millis(1);
const INTERVAL: Duration = Duration::from_micros(16_667);
const MTU: usize = 1200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Direction {
    ToViewer,
    ToHost,
}

type DropRule = Box<dyn FnMut(Direction, &Bytes) -> bool>;

struct Sim {
    epoch: Instant,
    now: Instant,
    host: Core,
    viewer: Core,
    links: [NetworkModel; 2],
    in_flight: BinaryHeap<Reverse<(Instant, u64, Direction, Bytes)>>,
    sequence: u64,
    drop_rule: Option<DropRule>,
    delays: [Duration; 2],
    host_events: Vec<Event>,
    viewer_events: Vec<Event>,
    sent_to_viewer: Vec<(Instant, Bytes)>,
}

impl Sim {
    fn new(conditions: NetworkConditions, config: MediaConfig, seed: u64) -> Self {
        let epoch = Instant::now();
        let delay = Duration::from_secs_f64(conditions.delay_ms / 1000.0) + Duration::from_micros(50);
        let mut host = Core::new(config, epoch);
        let mut viewer = Core::new(config, epoch);
        for core in [&mut host, &mut viewer] {
            core.set_rtt(delay * 2);
            core.set_max_datagram_size(Some(MTU));
        }
        Self {
            epoch,
            now: epoch,
            host,
            viewer,
            links: [NetworkModel::new(conditions, seed), NetworkModel::new(conditions, seed ^ 0xFEED)],
            in_flight: BinaryHeap::new(),
            sequence: 0,
            drop_rule: None,
            delays: [delay; 2],
            host_events: Vec::new(),
            viewer_events: Vec::new(),
            sent_to_viewer: Vec::new(),
        }
    }

    fn drop_when(&mut self, rule: impl FnMut(Direction, &Bytes) -> bool + 'static) {
        self.drop_rule = Some(Box::new(rule));
    }

    fn send(&mut self, frame: OutgoingFrame<'_>) -> u32 {
        let number = self.host.send_frame(self.now, frame).expect("frame is valid");
        self.pump();
        number
    }

    fn pump(&mut self) {
        for direction in [Direction::ToViewer, Direction::ToHost] {
            loop {
                let core = if direction == Direction::ToViewer { &mut self.host } else { &mut self.viewer };
                let Some(datagram) = core.poll_transmit(self.now) else {
                    break;
                };
                if direction == Direction::ToViewer {
                    self.sent_to_viewer.push((self.now, datagram.clone()));
                }
                if self.drop_rule.as_mut().is_some_and(|rule| rule(direction, &datagram)) {
                    continue;
                }
                let link = &mut self.links[direction as usize];
                if let Fate::Delivered(at) = link.send(datagram.len(), self.now - self.epoch) {
                    let delay = &mut self.delays[direction as usize];
                    *delay = delay.mul_f64(7.0 / 8.0) + (self.epoch + at - self.now).mul_f64(1.0 / 8.0);
                    self.sequence += 1;
                    self.in_flight.push(Reverse((self.epoch + at, self.sequence, direction, datagram)));
                }
            }
        }
        let rtt = self.delays[0] + self.delays[1];
        self.host.set_rtt(rtt);
        self.viewer.set_rtt(rtt);
        while let Some(event) = self.host.poll_event() {
            self.host_events.push(event);
        }
        while let Some(event) = self.viewer.poll_event() {
            self.viewer_events.push(event);
        }
    }

    fn run_until(&mut self, until: Instant) {
        for _ in 0..10_000_000 {
            self.pump();
            let next = [
                self.host.poll_timeout(self.now),
                self.viewer.poll_timeout(self.now),
                self.in_flight.peek().map(|Reverse((at, ..))| *at),
            ]
            .into_iter()
            .flatten()
            .min();
            let Some(next) = next.filter(|next| *next <= until) else {
                self.now = until;
                return;
            };
            self.now = next.max(self.now);
            while self.in_flight.peek().is_some_and(|Reverse((at, ..))| *at <= self.now) {
                let Reverse((_, _, direction, datagram)) = self.in_flight.pop().unwrap();
                let core = if direction == Direction::ToViewer { &mut self.viewer } else { &mut self.host };
                core.handle_datagram(self.now, datagram);
            }
            self.host.handle_timeout(self.now);
            self.viewer.handle_timeout(self.now);
        }
        panic!("the simulation didn't settle");
    }

    fn run_for(&mut self, duration: Duration) {
        self.run_until(self.now + duration);
    }

    fn frames(&self) -> Vec<&ReceivedFrame> {
        self.viewer_events
            .iter()
            .filter_map(|event| if let Event::Frame(frame) = event { Some(frame) } else { None })
            .collect()
    }

    fn acks(&self) -> Vec<&FrameAck> {
        self.host_events
            .iter()
            .filter_map(|event| if let Event::FrameAcked(ack) = event { Some(ack) } else { None })
            .collect()
    }

    fn sent_packets(&self) -> Vec<(Instant, PacketHeader)> {
        self.sent_to_viewer
            .iter()
            .filter_map(|(at, datagram)| Some((*at, PacketHeader::decode(datagram.clone())?.0)))
            .collect()
    }
}

fn config(fec: FecMode) -> MediaConfig {
    MediaConfig { frame_interval: INTERVAL, fec, ..MediaConfig::default() }
}

fn payload(seed: u64, len: usize) -> Bytes {
    let mut random = SplitMix64::new(seed);
    Bytes::from((0..len).map(|_| random.next_u64() as u8).collect::<Vec<u8>>())
}

fn frame(stream: u8, data: &[u8]) -> OutgoingFrame<'_> {
    OutgoingFrame { stream, data, ..OutgoingFrame::default() }
}

fn is_packet(datagram: &Bytes, frame: u32, index: u16) -> bool {
    PacketHeader::decode(datagram.clone()).is_some_and(|(header, _)| header.frame == frame && header.index == index)
}

fn first_time(mut matches: impl FnMut(Direction, &Bytes) -> bool) -> impl FnMut(Direction, &Bytes) -> bool {
    let mut seen = std::collections::HashSet::new();
    move |direction, datagram| matches(direction, datagram) && seen.insert(datagram.clone())
}

fn last_data_index(data_len: usize) -> u16 {
    (fec::Layout::for_payload(data_len + 3, MTU - wire::HEADER_BYTES).unwrap().data_count - 1) as u16
}

fn is_kind(datagram: &Bytes, kind: Kind) -> bool {
    wire::kind_of(datagram) == Some(kind)
}

#[test]
fn frames_arrive_byte_identical_in_order_with_their_fields() {
    let mut sim = Sim::new(NetworkConditions::N0, config(FecMode::Off), 1);
    type Sent = (u8, bool, Option<u64>, Vec<u8>, Bytes);
    let sent: Vec<Sent> = (0..20u64)
        .map(|index| {
            let meta = format!("meta {index}").into_bytes();
            (
                (index % 2) as u8,
                index < 2,
                (index % 5 == 0).then_some(index * 10),
                meta,
                payload(index, 1 + index as usize * 9_000),
            )
        })
        .collect();
    for (stream, keyframe, ltr_token, meta, data) in &sent {
        sim.send(OutgoingFrame { stream: *stream, keyframe: *keyframe, ltr_token: *ltr_token, meta, data });
        sim.run_for(INTERVAL);
    }
    sim.run_for(50 * MS);

    let received: Vec<Sent> = sim
        .frames()
        .iter()
        .map(|frame| (frame.stream, frame.keyframe, frame.ltr_token, frame.meta.clone(), frame.data.clone()))
        .collect();
    assert_eq!(received, sent);
    assert!(sim.frames().iter().all(|frame| frame.recovery == Recovery::None));
    assert_eq!(sim.acks().len(), 20);
}

#[test]
fn a_frame_is_spread_over_at_most_half_an_interval_and_feedback_times_it() {
    let mut sim = Sim::new(NetworkConditions::N0, MediaConfig { initial_rate_bps: 300e6, ..config(FecMode::Off) }, 2);
    sim.send(frame(0, &payload(1, 1 << 20)));
    sim.run_for(30 * MS);
    let packets = sim.sent_packets();
    let spread = packets.last().unwrap().0 - packets.first().unwrap().0;
    assert!(spread <= INTERVAL / 2 && spread >= INTERVAL / 2 - MS, "{spread:?}");

    let ack = sim.acks()[0];
    assert_eq!(ack.sending, spread);
    let receipt = ack.receipt.expect("the ack arrived");
    assert_eq!(receipt.arriving.as_micros(), spread.as_micros());
    assert_eq!(receipt.assembling, receipt.arriving);
}

#[test]
fn a_lost_packet_is_nacked_at_the_next_arrival_and_back_one_round_trip_later() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 3);
    sim.drop_when(first_time(|direction, datagram| direction == Direction::ToViewer && is_packet(datagram, 0, 3)));
    sim.send(frame(0, &payload(1, 20 * 1000)));
    sim.run_for(30 * MS);

    let frame = sim.frames()[0];
    assert_eq!(frame.recovery, Recovery::Nack);
    let receipt = sim.acks()[0].receipt.unwrap();
    let recovery = receipt.assembling - receipt.arriving;
    assert!(recovery < 2 * MS + Duration::from_micros(100), "{recovery:?}");
    assert_eq!(sim.viewer.stats(sim.now).nacks_sent, 1);
}

#[test]
fn a_lost_last_packet_is_nacked_after_the_tail_wait() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 4);
    let data = payload(1, 10 * 1000);
    let last = last_data_index(data.len());
    sim.drop_when(first_time(move |direction, datagram| {
        direction == Direction::ToViewer && is_packet(datagram, 0, last)
    }));
    sim.send(frame(0, &data));
    sim.run_for(30 * MS);

    assert_eq!(sim.frames()[0].data, data);
    let receipt = sim.acks()[0].receipt.unwrap();
    let recovery = receipt.assembling - receipt.arriving;
    assert!(recovery >= MS + 2 * MS && recovery < 4 * MS, "1 ms tail wait plus a 2.1 ms round trip: {recovery:?}");
}

#[test]
fn parity_repairs_a_loss_without_a_round_trip() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Fixed(0.2)), 5);
    sim.drop_when(|direction, datagram| direction == Direction::ToViewer && is_packet(datagram, 0, 2));
    let data = payload(1, 10 * 1000);
    sim.send(frame(0, &data));
    sim.run_for(30 * MS);

    assert_eq!(sim.frames()[0].data, data);
    assert_eq!(sim.frames()[0].recovery, Recovery::Fec);
    assert_eq!(sim.viewer.stats(sim.now).nacks_sent, 0);
    let receipt = sim.acks()[0].receipt.unwrap();
    assert_eq!(receipt.assembling, receipt.arriving);
}

#[test]
fn a_frame_lost_whole_before_idle_is_probed_and_delivered() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 6);
    sim.drop_when(first_time(|direction, datagram| {
        direction == Direction::ToViewer
            && PacketHeader::decode(datagram.clone()).is_some_and(|(header, _)| header.frame == 1)
    }));
    sim.send(frame(0, &payload(1, 3000)));
    sim.run_for(INTERVAL);
    let last = payload(2, 3000);
    sim.send(frame(0, &last));
    sim.run_for(200 * MS);

    let rtt = sim.host.stats(sim.now).rtt;
    let probes = sim.host.stats(sim.now).probes_sent;
    let frames = sim.frames();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[1].data, last);
    let probe_at = sim.epoch + INTERVAL + 25 * MS + rtt + MS;
    assert!(frames[1].first_packet_at >= probe_at, "{:?}", frames[1].first_packet_at - probe_at);
    assert!(frames[1].completed_at < probe_at + 5 * MS);
    assert_eq!(probes, 1);
}

#[test]
fn giving_up_skips_the_frame_tells_the_host_and_releases_the_next_one() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 7);
    sim.drop_when(|direction, datagram| direction == Direction::ToViewer && is_packet(datagram, 0, 1));
    sim.send(frame(0, &payload(1, 5000)));
    sim.run_for(INTERVAL);
    let next = payload(2, 5000);
    sim.send(frame(0, &next));
    sim.run_for(5 * MS);
    assert!(sim.frames().is_empty(), "frame 1 is complete but waits for frame 0's repair");

    sim.run_for(100 * MS);
    let skipped = sim.viewer_events.iter().position(|event| *event == Event::FrameSkipped { stream: 0, frame: 0 });
    let delivered =
        sim.viewer_events.iter().position(|event| matches!(event, Event::Frame(frame) if frame.data == next));
    assert!(skipped.unwrap() < delivered.unwrap());
    assert!(sim.host_events.contains(&Event::FrameLost { stream: 0, frame: 0 }));
    assert_eq!(sim.acks().iter().map(|ack| ack.frame).collect::<Vec<_>>(), vec![1]);
}

#[test]
fn streams_never_wait_for_each_other() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 8);
    sim.drop_when(|direction, datagram| {
        direction == Direction::ToViewer
            && PacketHeader::decode(datagram.clone()).is_some_and(|(header, _)| header.stream == 0 && header.index == 1)
    });
    sim.send(frame(0, &payload(1, 5000)));
    sim.send(frame(1, &payload(2, 5000)));
    sim.run_for(5 * MS);
    assert_eq!(sim.frames().iter().map(|frame| frame.stream).collect::<Vec<_>>(), vec![1]);
}

#[test]
fn ltr_acks_reach_the_host_even_when_the_first_report_is_lost() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 9);
    sim.send(OutgoingFrame { ltr_token: Some(42), ..frame(0, &payload(1, 2000)) });
    sim.run_for(INTERVAL);
    let mut first = true;
    sim.drop_when(move |direction, datagram| {
        let drop = direction == Direction::ToHost && is_kind(datagram, Kind::Feedback) && first;
        first &= !drop;
        drop
    });
    sim.viewer.ack_ltr(0, 42);
    sim.run_for(INTERVAL);
    assert!(!sim.host_events.iter().any(|event| matches!(event, Event::LtrAcked { .. })));

    sim.send(frame(0, &payload(2, 2000)));
    sim.run_for(INTERVAL);
    assert_eq!(
        sim.host_events.iter().filter(|event| matches!(event, Event::LtrAcked { .. })).collect::<Vec<_>>(),
        vec![&Event::LtrAcked { stream: 0, token: 42 }]
    );
}

#[test]
fn a_lost_ack_is_settled_by_the_next_report() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 10);
    let mut first = true;
    sim.drop_when(move |direction, datagram| {
        let drop = direction == Direction::ToHost && is_kind(datagram, Kind::Feedback) && first;
        first &= !drop;
        drop
    });
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    sim.send(frame(0, &payload(2, 2000)));
    sim.run_for(INTERVAL);

    let acks = sim.acks();
    assert_eq!(
        acks.iter().map(|ack| (ack.frame, ack.receipt.is_some())).collect::<Vec<_>>(),
        vec![(1, true), (0, false)]
    );
    assert_eq!(sim.host.stats(sim.now).probes_sent, 0);
}

#[test]
fn admission_and_the_estimate_keep_a_slow_link_from_queueing() {
    let mut sim = Sim::new(NetworkConditions::N5, config(FecMode::Off), 11);
    let mut sent = 0;
    for index in 0..300 {
        let admission = sim.host.admission();
        if admission.admit {
            let ceiling = (admission.encoder_ceiling_bps / 8.0 * INTERVAL.as_secs_f64()) as usize;
            sim.send(frame(0, &payload(index, ceiling.min(250_000))));
            sent += 1;
        }
        sim.run_for(INTERVAL);
    }
    sim.run_for(500 * MS);

    let estimate = sim.host.admission().estimate_bps;
    assert!((25e6..33e6).contains(&estimate), "{estimate}");
    let settled: Vec<&FrameAck> = sim.acks().into_iter().filter(|ack| ack.frame >= 60).collect();
    let frames_after = sim.frames().iter().filter(|frame| frame.frame >= 60).count();
    assert_eq!(settled.len(), frames_after);
    assert!(frames_after * 100 >= (sent - 60) * 95, "{frames_after} of {} frames", sent - 60);
    let slowest = settled.iter().map(|ack| ack.queued + ack.acked_after).max().unwrap();
    assert!(slowest < 4 * INTERVAL, "{slowest:?}");
}

#[test]
fn n3_loss_costs_at_most_a_round_trip_plus_two_ms_for_999_in_1000_frames() {
    let mut sim = Sim::new(NetworkConditions::N3, config(FecMode::Adaptive), 12);
    let mut sizes = SplitMix64::new(99);
    let mut sent = Vec::new();
    for index in 0..3000u64 {
        let len = if index % 60 == 0 { 300_000 } else { 500 + (sizes.next_u64() % 60_000) as usize };
        let data = payload(index, len);
        sim.send(frame((index % 4) as u8, &data));
        sent.push(data);
        sim.run_for(INTERVAL / 4);
    }
    sim.run_for(200 * MS);

    let mut received: Vec<Vec<Bytes>> = vec![Vec::new(); 4];
    for frame in sim.frames() {
        received[usize::from(frame.stream)].push(frame.data.clone());
    }
    for (stream, received) in received.iter().enumerate() {
        let expected: Vec<Bytes> = sent.iter().skip(stream).step_by(4).cloned().collect();
        assert_eq!(received, &expected, "stream {stream}");
    }
    let rtt = sim.host.stats(sim.now).rtt;
    assert_eq!(sim.acks().len(), 3000);
    let timed: Vec<_> = sim.acks().iter().filter_map(|ack| ack.receipt).collect();
    assert!(timed.len() > 2900, "{}", timed.len());
    let late = timed.iter().filter(|receipt| receipt.assembling - receipt.arriving > rtt + 2 * MS).count();
    assert!(late * 1000 <= timed.len(), "{late} of {} frames took longer", timed.len());
    let stats = sim.viewer.stats(sim.now);
    assert!(stats.fec_recoveries > 0 && stats.nacks_sent > 0, "{stats:?}");
}

fn single_packet(frame: u32, payload: &[u8]) -> Bytes {
    PacketHeader {
        kind: Kind::Data,
        stream: 0,
        frame,
        index: 0,
        data_count: 1,
        parity_count: 0,
        frame_len: payload.len() as u32,
    }
    .encode(payload)
}

fn viewer_core() -> (Core, Instant) {
    let now = Instant::now();
    let mut viewer = Core::new(config(FecMode::Off), now);
    viewer.set_rtt(2 * MS);
    viewer.set_max_datagram_size(Some(MTU));
    (viewer, now)
}

#[test]
fn a_jump_billions_of_frames_ahead_skips_them_in_one_step() {
    let (mut viewer, now) = viewer_core();
    let fields = wire::FrameFields::default();
    viewer.handle_datagram(now, single_packet(4_000_000_000, &fields.payload(b"far")));
    let mut at = now;
    while let Some(next) = viewer.poll_timeout(at).filter(|next| *next < now + Duration::from_secs(1)) {
        at = next;
        viewer.handle_timeout(at);
    }

    let events: Vec<Event> = std::iter::from_fn(|| viewer.poll_event()).collect();
    assert_eq!(events[0], Event::FrameSkipped { stream: 0, frame: 4_000_000_000 - 65 });
    assert!(
        matches!(events.last(), Some(Event::Frame(frame)) if frame.frame == 4_000_000_000 && &frame.data[..] == b"far")
    );
}

#[test]
fn a_frame_whose_fields_dont_parse_is_reported_lost_not_delivered() {
    let (mut viewer, now) = viewer_core();
    viewer.handle_datagram(now, single_packet(0, &[0, 0xFF, 0xFF, 1, 2, 3]));

    assert_eq!(viewer.poll_event(), Some(Event::FrameSkipped { stream: 0, frame: 0 }));
    let report = std::iter::from_fn(|| viewer.poll_transmit(now))
        .find_map(|datagram| wire::Feedback::decode(&datagram))
        .expect("the viewer reports the frame");
    assert_eq!((report.frame, report.lost), (0, true));
}
