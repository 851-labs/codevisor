use std::{
    cmp::Reverse,
    collections::BinaryHeap,
    time::{Duration, Instant},
};

use bytes::Bytes;
use codevisor_media::{
    Core, Event, FecMode, FrameAck, MediaConfig, OutgoingFrame, ReceivedFrame, Recovery, fec,
    netsim::{Fate, NetworkConditions, NetworkModel, SplitMix64},
    wire::{self, Kind, PacketHeader, RefreshRequest},
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
    original_arrivals: std::collections::HashMap<(u8, u32, u16), Option<Instant>>,
    nacks_to_host: Vec<(Instant, wire::Nack)>,
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
            original_arrivals: std::collections::HashMap::new(),
            nacks_to_host: Vec::new(),
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
                if direction == Direction::ToHost
                    && let Some(nack) = wire::Nack::decode(&datagram)
                {
                    self.nacks_to_host.push((self.now, nack));
                }
                let link = &mut self.links[direction as usize];
                let fate = link.send(datagram.len(), self.now - self.epoch);
                if direction == Direction::ToViewer
                    && let Some((header, _)) = PacketHeader::decode(datagram.clone())
                    && header.kind == Kind::Data
                {
                    let arrival = if let Fate::Delivered(at) = fate { Some(self.epoch + at) } else { None };
                    self.original_arrivals.entry((header.stream, header.frame, header.index)).or_insert(arrival);
                }
                if let Fate::Delivered(at) = fate {
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

    fn nacked_before_arriving(&self) -> usize {
        let originals = &self.original_arrivals;
        self.nacks_to_host
            .iter()
            .flat_map(|(at, nack)| {
                nack.ranges.iter().filter(|(_, count)| *count != wire::WHOLE_FRAME).flat_map(move |&(start, count)| {
                    (start..start + count).filter(move |index| {
                        originals.get(&(nack.stream, nack.frame, *index)).is_some_and(|arrival| arrival.is_some_and(|arrival| arrival > *at))
                    })
                })
            })
            .count()
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
        sim.send(OutgoingFrame {
            stream: *stream,
            keyframe: *keyframe,
            refresh: false,
            ltr_token: *ltr_token,
            meta,
            data,
        });
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
fn a_nack_repeated_while_its_retransmission_waits_to_leave_queues_it_once() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 25);
    sim.send(frame(0, &payload(1, 5000)));
    let nack = wire::Nack::whole_frame(0, 0).encode();
    sim.host.handle_datagram(sim.now, nack.clone());
    sim.host.handle_datagram(sim.now, nack.clone());
    let queued = sim.host.stats(sim.now).packets_retransmitted;
    sim.run_for(MS / 4);
    sim.host.handle_datagram(sim.now, nack);

    assert_eq!(queued, 5);
    assert_eq!(sim.host.stats(sim.now).packets_retransmitted, 5, "sent less than a round trip ago");
    assert_eq!(sim.host.stats(sim.now).retransmissions_skipped, 10);
}

#[test]
fn a_frame_still_arriving_on_a_slow_link_is_neither_given_up_nor_resent_whole() {
    let slow = NetworkConditions { id: "slow", delay_ms: 50.0, capacity_kbps: Some(1_000), ..NetworkConditions::N0 };
    for fec in [FecMode::Off, FecMode::Adaptive] {
        let mut sim = Sim::new(slow, config(fec), 1);
        sim.drop_when(first_time(|direction, datagram| direction == Direction::ToViewer && is_packet(datagram, 0, 1)));
        let data = payload(1, 60_000);
        sim.send(frame(0, &data));
        sim.run_for(Duration::from_secs(2));

        assert_eq!(sim.frames().iter().map(|frame| &frame.data).collect::<Vec<_>>(), vec![&data], "{fec:?}");
        let resent = sim.host.stats(sim.now).packets_retransmitted;
        assert!(resent < 5, "{fec:?}: {resent} packets resent for one loss");
    }
}

#[test]
fn a_lost_tail_on_a_fast_link_is_asked_for_in_one_round() {
    let mut sim = Sim::new(NetworkConditions::N0, config(FecMode::Off), 1);
    sim.send(frame(0, &payload(1, 12_000)));
    sim.run_for(INTERVAL);
    sim.drop_when(first_time(|direction, datagram| {
        direction == Direction::ToViewer && (1..10).any(|index| is_packet(datagram, 1, index))
    }));
    let sent_at = sim.now;
    sim.send(frame(0, &payload(2, 12_000)));
    sim.run_for(INTERVAL);

    let repaired = sim.frames().into_iter().find(|frame| frame.frame == 1).expect("frame 1 arrived");
    assert!(repaired.completed_at - sent_at < 3 * MS, "{:?}", repaired.completed_at - sent_at);
    assert_eq!(sim.viewer.stats(sim.now).nacks_sent, 1, "one NACK for the whole tail");
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
    let probe_at = sim.epoch + INTERVAL + rtt + MS;
    assert!(frames[1].first_packet_at >= probe_at, "{:?}", frames[1].first_packet_at - probe_at);
    assert!(frames[1].completed_at < probe_at + rtt + 2 * MS, "{:?}", frames[1].completed_at - probe_at);
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
    sim.run_for(MS / 2);
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
fn a_lost_ack_at_idle_is_repaired_by_the_tail_probe_one_round_trip_later() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 10);
    let mut first = true;
    sim.drop_when(move |direction, datagram| {
        let drop = direction == Direction::ToHost && is_kind(datagram, Kind::Feedback) && first;
        first &= !drop;
        drop
    });
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);

    let rtt = sim.host.stats(sim.now).rtt;
    let acks = sim.acks();
    assert_eq!(acks.iter().map(|ack| ack.frame).collect::<Vec<_>>(), vec![0]);
    assert!(acks[0].acked_after < 2 * rtt + 3 * MS, "{:?}", acks[0].acked_after);
    assert_eq!(sim.host.stats(sim.now).probes_sent, 1);
}

fn refresh_requests(events: &[Event]) -> Vec<bool> {
    events
        .iter()
        .filter_map(|event| match event {
            Event::RefreshRequested { keyframe, .. } => Some(*keyframe),
            _ => None,
        })
        .collect()
}

#[test]
fn a_refresh_request_is_repeated_until_a_refresh_arrives_and_reaches_the_host_once() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 20);
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    let mut first = true;
    sim.drop_when(move |direction, datagram| {
        let drop = direction == Direction::ToHost && is_kind(datagram, Kind::Refresh) && first;
        first &= !drop;
        drop
    });
    sim.viewer.request_refresh(sim.now, 0, false);
    sim.run_for(40 * MS);
    assert_eq!(refresh_requests(&sim.host_events), vec![false]);

    sim.run_for(100 * MS);
    assert_eq!(refresh_requests(&sim.host_events), vec![false], "repeats before the answer are not new requests");
    sim.send(OutgoingFrame { refresh: true, ..frame(0, &payload(2, 2000)) });
    sim.run_for(INTERVAL);
    let sent = sim.viewer.stats(sim.now).refresh_requests_sent;
    sim.run_for(200 * MS);

    assert!(sim.frames().last().is_some_and(|frame| frame.refresh));
    assert_eq!(sim.viewer.stats(sim.now).refresh_requests_sent, sent);
    assert_eq!(refresh_requests(&sim.host_events), vec![false]);
}

#[test]
fn an_unanswered_refresh_request_stops_repeating_after_fifty_sends() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 26);
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    sim.viewer.request_refresh(sim.now, 0, false);
    sim.run_for(5_000 * MS);

    assert_eq!(sim.viewer.stats(sim.now).refresh_requests_sent, 50);
    assert_eq!(refresh_requests(&sim.host_events), vec![false]);
}

#[test]
fn a_request_still_open_after_its_answer_was_lost_reaches_the_host_again() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 21);
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    sim.viewer.request_refresh(sim.now, 0, false);
    sim.run_for(5 * MS);
    sim.drop_when(|direction, datagram| direction == Direction::ToViewer && is_packet(datagram, 1, 0));
    sim.send(OutgoingFrame { refresh: true, ..frame(0, &payload(2, 2000)) });
    sim.run_for(INTERVAL);
    sim.send(frame(0, &payload(3, 2000)));
    sim.run_for(150 * MS);

    assert!(sim.host_events.contains(&Event::FrameLost { stream: 0, frame: 1 }));
    assert_eq!(refresh_requests(&sim.host_events), vec![false, false]);
}

#[test]
fn a_keyframe_request_replaces_a_refresh_request_and_only_a_keyframe_settles_it() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 22);
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    sim.viewer.request_refresh(sim.now, 0, false);
    sim.viewer.request_refresh(sim.now, 0, true);
    sim.viewer.request_refresh(sim.now, 0, false);
    sim.run_for(5 * MS);
    assert_eq!(refresh_requests(&sim.host_events), vec![true]);

    sim.send(OutgoingFrame { refresh: true, ..frame(0, &payload(2, 2000)) });
    sim.run_for(INTERVAL);
    let after_refresh = sim.viewer.stats(sim.now).refresh_requests_sent;
    sim.run_for(100 * MS);
    assert!(sim.viewer.stats(sim.now).refresh_requests_sent > after_refresh);

    sim.send(OutgoingFrame { keyframe: true, ..frame(0, &payload(3, 2000)) });
    sim.run_for(INTERVAL);
    let after_keyframe = sim.viewer.stats(sim.now).refresh_requests_sent;
    sim.run_for(100 * MS);
    assert_eq!(sim.viewer.stats(sim.now).refresh_requests_sent, after_keyframe);
}

#[test]
fn an_ltr_refresh_sent_after_a_keyframe_request_is_not_taken_as_its_answer() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 23);
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    sim.viewer.request_refresh(sim.now, 0, true);
    sim.run_for(5 * MS);
    sim.send(OutgoingFrame { refresh: true, ..frame(0, &payload(2, 2000)) });
    sim.run_for(100 * MS);
    assert_eq!(refresh_requests(&sim.host_events), vec![true], "the keyframe is still on its way");

    sim.send(OutgoingFrame { keyframe: true, ..frame(0, &payload(3, 2000)) });
    sim.run_for(100 * MS);
    assert_eq!(refresh_requests(&sim.host_events), vec![true]);
}

#[test]
fn a_late_repeat_of_an_older_request_is_ignored() {
    let mut sim = Sim::new(NetworkConditions::N1, config(FecMode::Off), 24);
    sim.send(frame(0, &payload(1, 2000)));
    sim.run_for(INTERVAL);
    let request = |number| RefreshRequest { stream: 0, request: number, keyframe: false, resolved_below: 1 };
    for number in [2, 1, u16::MAX] {
        sim.host.handle_datagram(sim.now, request(number).encode());
    }
    sim.host.handle_datagram(sim.now, request(3).encode());
    sim.pump();

    assert_eq!(refresh_requests(&sim.host_events), vec![false, false]);
}

#[test]
fn jitter_without_a_queue_doesnt_pull_the_estimate_down() {
    let conditions = NetworkConditions { delay_sd_ms: 1.0, ..NetworkConditions::N3 };
    let mut sim = Sim::new(conditions, config(FecMode::Adaptive), 2);
    let mut lowest = f64::MAX;
    for index in 0..1800u64 {
        let admission = sim.host.admission();
        if index >= 120 {
            lowest = lowest.min(admission.estimate_bps);
        }
        assert!(admission.admit, "frame {index} was refused at {:.1} Mbit/s", admission.estimate_bps / 1e6);
        sim.send(frame(0, &payload(index, 6000)));
        sim.run_for(INTERVAL);
    }

    assert!(lowest > 30e6, "{:.1} Mbit/s", lowest / 1e6);
}

#[test]
fn the_estimate_comes_back_within_seconds_after_the_link_does() {
    let mut sim = Sim::new(NetworkConditions::N3, config(FecMode::Adaptive), 4);
    let mut encoder = EncoderModel::new(1.0, 4);
    let mut lowest = f64::MAX;
    let mut recovered_at = None;
    for index in 0..900u64 {
        let narrow = (120..240).contains(&index);
        sim.links[0].conditions.capacity_kbps = Some(if narrow { 20_000 } else { 1_000_000 });
        let admission = sim.host.admission();
        if admission.admit {
            sim.send(frame(0, &payload(index, encoder.frame_len(sim.now, admission.encoder_ceiling_bps))));
        }
        sim.run_for(INTERVAL);
        let estimate = sim.host.admission().estimate_bps;
        if (200..240).contains(&index) {
            lowest = lowest.min(estimate);
        }
        if index >= 240 && recovered_at.is_none() && estimate >= 40e6 {
            recovered_at = Some(index - 240);
        }
    }

    assert!(lowest < 25e6, "the estimate followed the link down: {:.1} Mbit/s", lowest / 1e6);
    let frames = recovered_at.expect("the estimate came back to 40 Mbit/s");
    assert!(frames <= 240, "back to 40 Mbit/s {frames} frames after the link");
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

struct EncoderModel {
    ceiling_bps: f64,
    checked: Option<Instant>,
    last_encode: Option<Instant>,
    carry: f64,
    sizes: SplitMix64,
}

impl EncoderModel {
    fn new(carry: f64, seed: u64) -> Self {
        Self { ceiling_bps: 45e6, checked: None, last_encode: None, carry, sizes: SplitMix64::new(seed) }
    }

    fn frame_len(&mut self, now: Instant, wanted_bps: f64) -> usize {
        if self.checked.is_none_or(|at| now - at >= 250 * MS) {
            self.checked = Some(now);
            let target = wanted_bps.clamp(200e3, 45e6);
            if (target - self.ceiling_bps).abs() > self.ceiling_bps * 0.1 {
                self.ceiling_bps = target;
            }
        }
        let intervals = self.last_encode.map_or(1.0, |at| (now - at).as_secs_f64() / INTERVAL.as_secs_f64());
        self.last_encode = Some(now);
        let noise = 0.6 + 0.8 * self.sizes.next_unit();
        let len = self.ceiling_bps * INTERVAL.as_secs_f64() / 8.0 * intervals.min(self.carry) * noise;
        (len as usize).max(300)
    }
}

struct SceneResult {
    frames_per_second: f64,
    ages: Vec<Duration>,
    rtt: Duration,
    estimate_bps: f64,
}

impl SceneResult {
    fn age(&self, range: std::ops::Range<usize>, share: f64) -> Duration {
        let mut sorted = self.ages[range].to_vec();
        sorted.sort();
        sorted[((sorted.len() - 1) as f64 * share) as usize]
    }

    fn median(&self) -> Duration {
        self.age(0..self.ages.len(), 0.5)
    }

    fn first_and_last_thirds(&self) -> (Duration, Duration) {
        let third = self.ages.len() / 3;
        (self.age(0..third, 0.5), self.age(self.ages.len() - third..self.ages.len(), 0.5))
    }
}

fn stream_scene(conditions: NetworkConditions, seed: u64, carry: f64) -> SceneResult {
    const WARM_UP: Duration = Duration::from_secs(5);
    const MEASURED: Duration = Duration::from_secs(30);
    let mut sim = Sim::new(conditions, config(FecMode::Adaptive), seed);
    let mut encoder = EncoderModel::new(carry, seed);
    let mut captured_at = std::collections::HashMap::new();
    let mut waiting: Option<Instant> = None;
    let mut next_capture = sim.now;
    let end = sim.now + WARM_UP + MEASURED;
    let mut index = 0u64;
    while sim.now < end {
        if sim.now >= next_capture {
            waiting = Some(next_capture);
            next_capture += INTERVAL;
        }
        let admission = sim.host.admission();
        if let Some(captured) = waiting.filter(|_| admission.admit) {
            let mut len = encoder.frame_len(sim.now, admission.encoder_ceiling_bps);
            if index.is_multiple_of(300) {
                len *= 3;
            }
            captured_at.insert(sim.send(frame(0, &payload(index, len))), captured);
            index += 1;
            waiting = None;
        }
        sim.run_until((sim.now + MS).min(next_capture).max(sim.now + Duration::from_micros(1)));
    }
    sim.run_for(Duration::from_secs(1));
    let measured_from = sim.epoch + WARM_UP;
    let mut ages: Vec<(Instant, Duration)> = sim
        .frames()
        .iter()
        .filter_map(|frame| captured_at.get(&frame.frame).map(|captured| (*captured, frame.completed_at - *captured)))
        .filter(|(captured, _)| *captured >= measured_from)
        .collect();
    ages.sort();
    SceneResult {
        frames_per_second: ages.len() as f64 / MEASURED.as_secs_f64(),
        ages: ages.into_iter().map(|(_, age)| age).collect(),
        rtt: sim.host.stats(sim.now).rtt,
        estimate_bps: sim.host.admission().estimate_bps,
    }
}

fn assert_interactive(result: &SceneResult, rtt: Duration, min_frames_per_second: f64) {
    let median = result.median();
    let (first, last) = result.first_and_last_thirds();
    assert!(result.frames_per_second >= min_frames_per_second, "{:.1} frames/s", result.frames_per_second);
    assert!(median <= rtt + 2 * INTERVAL, "p50 {median:?} over a round trip ({rtt:?}) and two frames");
    assert!(last <= first + 2 * INTERVAL, "the age grew from {first:?} to {last:?}");
}

#[test]
fn a_slow_link_with_a_short_queue_keeps_the_frame_rate_and_the_age_flat() {
    for carry in [1.0, 8.0] {
        let result = stream_scene(NetworkConditions::N5, 1, carry);
        assert_interactive(&result, 20 * MS, 54.0);
        assert!(result.age(0..result.ages.len(), 0.95) <= result.rtt + 2 * INTERVAL, "carry {carry}");
        assert!((25e6..33e6).contains(&result.estimate_bps), "{:.1} Mbit/s", result.estimate_bps / 1e6);
    }
}

#[test]
fn a_long_jittery_path_keeps_the_frame_rate_and_the_age_flat() {
    for carry in [1.0, 8.0] {
        assert_interactive(&stream_scene(NetworkConditions::N6, 2, carry), 50 * MS, 45.0);
    }
}

#[test]
fn a_one_megabit_lossy_link_brings_the_estimate_down_to_the_link_after_a_big_first_frame() {
    let mut sim = Sim::new(NetworkConditions::N7, config(FecMode::Adaptive), 3);
    let settled_from = sim.now + Duration::from_millis(2_500);
    let end = sim.now + Duration::from_secs(8);
    let mut next = sim.now;
    let mut index = 0u64;
    let mut highest = 0.0f64;
    while sim.now < end {
        let admission = sim.host.admission();
        if sim.now >= next && admission.admit {
            let len = if index == 0 { 190_000 } else { 3_000 };
            sim.send(frame(0, &payload(index, len)));
            index += 1;
            next = sim.now + INTERVAL;
        }
        if sim.now >= settled_from {
            highest = highest.max(admission.estimate_bps);
        }
        sim.run_until(sim.now + MS);
    }
    assert!(highest < 3e6, "{:.1} Mbit/s after 2.5 s", highest / 1e6);
}

#[test]
fn a_one_megabit_lossy_link_keeps_the_age_flat() {
    let paced = stream_scene(NetworkConditions::N7, 3, 1.0);
    assert_interactive(&paced, 100 * MS, 50.0);
    let two_frames = stream_scene(NetworkConditions::N7, 3, 2.0);
    assert_interactive(&two_frames, 100 * MS, 45.0);
    let carrying = stream_scene(NetworkConditions::N7, 3, 8.0);
    assert!(carrying.frames_per_second >= 18.0, "{:.1} frames/s", carrying.frames_per_second);
    let median = carrying.median();
    assert!(median < 160 * MS, "p50 {median:?} with frames that carry the time since the last encode");
}

fn app_limited_estimates(
    conditions: NetworkConditions,
    seed: u64,
    duration: Duration,
    mut frame_len: impl FnMut(u64, Duration) -> usize,
) -> Vec<(Duration, f64)> {
    let mut sim = Sim::new(conditions, config(FecMode::Adaptive), seed);
    let end = sim.now + duration;
    let mut next = sim.now;
    let mut index = 0u64;
    let mut estimates = Vec::new();
    while sim.now < end {
        if sim.now >= next && sim.host.admission().admit {
            sim.send(frame(0, &payload(index, frame_len(index, sim.now - sim.epoch))));
            index += 1;
            next = (next + INTERVAL).max(sim.now);
        }
        estimates.push((sim.now - sim.epoch, sim.host.admission().estimate_bps));
        sim.run_until(sim.now + MS);
    }
    estimates
}

#[test]
fn a_big_frame_on_an_app_limited_stream_doesnt_pull_the_estimate_down_to_the_stream() {
    let big_at = 300 * INTERVAL;
    for capacity_kbps in [1_000_000, 200_000, 50_000] {
        for seed in 1..=3 {
            let conditions = NetworkConditions { capacity_kbps: Some(capacity_kbps), ..NetworkConditions::N3 };
            let estimates = app_limited_estimates(conditions, seed, Duration::from_secs(7), |index, _| {
                if index == 300 { 470_000 } else { 3_000 }
            });
            let lowest = estimates
                .iter()
                .filter(|(at, _)| *at >= big_at)
                .map(|(_, estimate)| *estimate)
                .fold(f64::MAX, f64::min);
            let link = capacity_kbps as f64 * 1e3;
            assert!(
                lowest >= link.min(100e6) / 2.0,
                "{capacity_kbps} kbit/s, seed {seed}: {:.1} Mbit/s after the big frame",
                lowest / 1e6
            );
        }
    }
}

#[test]
fn an_app_limited_stream_doesnt_let_the_estimate_grow_past_the_link() {
    for seed in 1..=3 {
        let estimates = app_limited_estimates(NetworkConditions::N5, seed, Duration::from_secs(10), |index, _| {
            if index == 0 { 470_000 } else { 3_000 }
        });
        let settled = estimates.iter().filter(|(at, _)| *at >= Duration::from_millis(1_500));
        let highest = settled.map(|(_, estimate)| *estimate).fold(0.0, f64::max);
        assert!(highest <= 60e6, "seed {seed}: {:.1} Mbit/s on a 30 Mbit/s link", highest / 1e6);
    }
}

#[test]
fn a_queue_that_outlasts_the_base_delay_window_stays_seen_while_it_drains() {
    let link =
        NetworkConditions { id: "1 Mbit/s", delay_ms: 50.0, capacity_kbps: Some(1_000), ..NetworkConditions::N0 };
    let mut sim = Sim::new(link, config(FecMode::Adaptive), 1);
    let mut captured_at = std::collections::HashMap::new();
    for index in 0..50 {
        captured_at.insert(sim.send(frame(0, &payload(index, 30_000))), sim.now);
    }
    let mut index = 50;
    let mut next = sim.now;
    let mut checked = 0;
    while sim.now < sim.epoch + Duration::from_secs(30) {
        let admission = sim.host.admission();
        if sim.now >= next && admission.admit {
            let len = (admission.encoder_ceiling_bps / 8.0 * INTERVAL.as_secs_f64()) as usize;
            captured_at.insert(sim.send(frame(0, &payload(index, len.max(300)))), sim.now);
            index += 1;
            next = sim.now + INTERVAL;
        }
        sim.run_until(sim.now + 10 * MS);
        let Some(latest) = sim.frames().last().copied() else {
            continue;
        };
        let waited = latest.completed_at - captured_at[&latest.frame];
        if sim.now - latest.completed_at <= 10 * MS && waited > Duration::from_secs(6) {
            let seen = Duration::from_micros(sim.host.stats(sim.now).queue_delay_us.max(0) as u64);
            assert!(seen >= waited / 2, "a frame waited {waited:?} but the queue reads {seen:?}");
            checked += 1;
        }
    }
    assert!(checked > 0);
}

#[test]
fn a_nack_for_packets_still_waiting_to_leave_resends_only_those_already_sent() {
    let mut sim = Sim::new(NetworkConditions::N1, MediaConfig { initial_rate_bps: 1e6, ..config(FecMode::Off) }, 27);
    sim.send(frame(0, &payload(1, 50 * 1000)));
    let sent = sim.host.stats(sim.now).packets_sent;
    sim.host.handle_datagram(sim.now, wire::Nack::whole_frame(0, 0).encode());

    assert!(sent < 40, "{sent} of 42 packets left at once");
    assert_eq!(sim.host.stats(sim.now).packets_retransmitted, sent);
}

#[test]
fn an_app_limited_tiled_stream_on_a_fast_link_comes_back_after_a_squeeze() {
    let mut sim = Sim::new(NetworkConditions::N3, config(FecMode::Adaptive), 5);
    let start = sim.now;
    let squeeze = start + Duration::from_secs(12)..start + Duration::from_secs(13);
    let mut index = 0u64;
    let mut lowest = f64::MAX;
    while sim.now < start + Duration::from_secs(25) {
        let squeezed = squeeze.contains(&sim.now);
        sim.links[0].conditions.capacity_kbps = Some(if squeezed { 2_000 } else { 1_000_000 });
        if sim.host.admission().admit {
            for tile in 0..16u8 {
                let len = if index == 0 { 12_000 } else { 400 };
                sim.send(frame(tile, &payload(index * 16 + u64::from(tile), len)));
            }
            index += 1;
        }
        sim.run_for(INTERVAL);
        if sim.now >= squeeze.end {
            lowest = lowest.min(sim.host.admission().estimate_bps);
        }
    }

    assert!(lowest < 10e6, "the squeeze cut the estimate: {:.1} Mbit/s", lowest / 1e6);
    let estimate = sim.host.admission().estimate_bps;
    assert!(estimate >= 100e6, "{:.1} Mbit/s 12 s after the squeeze", estimate / 1e6);
}

fn estimates_while_sending(
    sim: &mut Sim,
    duration: Duration,
    mut frame_len: impl FnMut(&mut Sim, u64) -> Option<usize>,
) -> Vec<(Duration, f64)> {
    let end = sim.now + duration;
    let mut index = 0u64;
    let mut estimates = Vec::new();
    while sim.now < end {
        if sim.host.admission().admit
            && let Some(len) = frame_len(sim, index)
        {
            sim.send(frame(0, &payload(index, len)));
            index += 1;
        }
        estimates.push((sim.now - sim.epoch, sim.host.admission().estimate_bps));
        sim.run_until(sim.now + MS);
    }
    estimates
}

fn range_from(estimates: &[(Duration, f64)], from: Duration) -> (f64, f64) {
    let after = estimates.iter().filter(|(at, _)| *at >= from).map(|(_, estimate)| *estimate);
    (after.clone().fold(f64::MAX, f64::min), after.fold(0.0, f64::max))
}

#[test]
fn a_slow_link_doesnt_ask_again_for_packets_still_on_their_way() {
    for seed in 1..=3 {
        let mut sim = Sim::new(NetworkConditions::N7, config(FecMode::Adaptive), seed);
        let mut encoder = EncoderModel::new(2.0, seed);
        let mut next = sim.now;
        let estimates = estimates_while_sending(&mut sim, Duration::from_secs(20), |sim, index| {
            if sim.now < next {
                return None;
            }
            next = (next + INTERVAL).max(sim.now);
            Some(if index == 0 { 250_000 } else { encoder.frame_len(sim.now, sim.host.admission().encoder_ceiling_bps) })
        });

        let (lowest, _) = range_from(&estimates, Duration::ZERO);
        assert!(lowest >= 500e3, "seed {seed}: the estimate fell to {:.2} Mbit/s", lowest / 1e6);
        let retransmitted = sim.host.stats(sim.now).packets_retransmitted;
        let early = sim.nacked_before_arriving();
        assert!(early * 20 <= retransmitted as usize, "seed {seed}: {early} of {retransmitted} were still on the link");
    }
}

fn typing(start: Instant, keyframe: usize) -> impl FnMut(&mut Sim, u64) -> Option<usize> {
    let mut next = start;
    move |sim, index| {
        if sim.now < next {
            return None;
        }
        next = (next + 4 * INTERVAL).max(sim.now);
        Some(if index == 0 { keyframe } else { 400 })
    }
}

#[test]
fn typing_measures_a_slow_lossy_link_and_leaves_a_fast_one_fast() {
    for seed in 1..=3 {
        let mut slow = Sim::new(NetworkConditions::N7, config(FecMode::Adaptive), seed);
        let keys = typing(slow.now, 100_000);
        let (_, highest) = range_from(&estimates_while_sending(&mut slow, Duration::from_secs(20), keys), 2_000 * MS);
        assert!(highest < 3e6, "N7, seed {seed}: {:.1} Mbit/s after 2 s", highest / 1e6);

        let mut fast = Sim::new(NetworkConditions::N0, config(FecMode::Adaptive), seed);
        let keys = typing(fast.now, 100_000);
        let (lowest, _) = range_from(&estimates_while_sending(&mut fast, Duration::from_secs(20), keys), 2_000 * MS);
        assert!(lowest >= 60e6, "N0, seed {seed}: {:.1} Mbit/s after 2 s", lowest / 1e6);
    }
}

#[test]
fn a_big_frame_repaired_by_nacks_still_measures_the_link() {
    let link = NetworkConditions { id: "20 Mbit/s", delay_ms: 25.0, capacity_kbps: Some(20_000), ..NetworkConditions::N0 };
    let mut sim = Sim::new(link, config(FecMode::Off), 1);
    sim.drop_when(first_time(|direction, datagram| {
        direction == Direction::ToViewer && [10, 40, 70].into_iter().any(|index| is_packet(datagram, 0, index))
    }));
    let keys = typing(sim.now, 100_000);
    let estimates = estimates_while_sending(&mut sim, Duration::from_secs(20), keys);

    assert_eq!(sim.frames()[0].recovery, Recovery::Nack);
    let (lowest, highest) = range_from(&estimates, 2_000 * MS);
    assert!((15e6..30e6).contains(&lowest) && highest < 30e6, "{:.1}..{:.1} Mbit/s after 2 s", lowest / 1e6, highest / 1e6);
}

#[test]
fn frames_bigger_than_the_pacing_spread_still_find_the_link() {
    for seed in 1..=3 {
        let config = MediaConfig { initial_rate_bps: 10e6, ..config(FecMode::Adaptive) };
        let mut sim = Sim::new(NetworkConditions::N5, config, seed);
        let estimates = estimates_while_sending(&mut sim, Duration::from_secs(10), |_, _| Some(200_000));

        let (lowest, highest) = range_from(&estimates, Duration::from_secs(5));
        assert!(lowest >= 20e6, "seed {seed}: {:.1} Mbit/s on a 30 Mbit/s link", lowest / 1e6);
        assert!(highest <= 60e6, "seed {seed}: {:.1} Mbit/s on a 30 Mbit/s link", highest / 1e6);
    }
}

#[test]
fn a_tiled_keyframe_draining_on_a_slow_lossy_link_doesnt_drive_the_estimate_to_the_floor() {
    for seed in 1..=3 {
        let mut sim = Sim::new(NetworkConditions::N7, config(FecMode::Adaptive), seed);
        let mut encoder = EncoderModel::new(2.0, seed);
        let end = sim.now + Duration::from_secs(40);
        let mut next = sim.now;
        let mut index = 0u64;
        let mut lowest = f64::MAX;
        while sim.now < end {
            let admission = sim.host.admission();
            if sim.now >= next && admission.admit {
                let len = if index == 0 { 750_000 } else { encoder.frame_len(sim.now, admission.encoder_ceiling_bps) };
                for tile in 0..16u8 {
                    sim.send(frame(tile, &payload(index * 16 + u64::from(tile), (len / 16).max(60))));
                }
                index += 1;
                next = (next + INTERVAL).max(sim.now);
            }
            lowest = lowest.min(admission.estimate_bps);
            sim.run_until(sim.now + MS);
        }
        assert!(lowest >= 500e3, "seed {seed}: the estimate fell to {:.2} Mbit/s", lowest / 1e6);
    }
}

fn tiled_typing_estimates(conditions: NetworkConditions, seed: u64) -> (f64, f64) {
    let mut sim = Sim::new(conditions, config(FecMode::Adaptive), seed);
    let end = sim.now + Duration::from_secs(20);
    let mut next = sim.now;
    let mut index = 0u64;
    let (mut lowest, mut highest) = (f64::MAX, 0.0f64);
    while sim.now < end {
        if sim.now >= next && sim.host.admission().admit {
            if index == 0 {
                for tile in 0..16u8 {
                    sim.send(frame(tile, &payload(u64::from(tile), 275)));
                }
            } else {
                sim.send(frame((index % 16) as u8, &payload(100 + index, 400)));
            }
            index += 1;
            next = (next + 4 * INTERVAL).max(sim.now);
        }
        if sim.now >= sim.epoch + Duration::from_secs(2) {
            let estimate = sim.host.admission().estimate_bps;
            (lowest, highest) = (lowest.min(estimate), highest.max(estimate));
        }
        sim.run_until(sim.now + MS);
    }
    (lowest, highest)
}

#[test]
fn tiled_typing_measures_the_link_from_its_first_tiles() {
    for seed in 1..=3 {
        let (_, n5) = tiled_typing_estimates(NetworkConditions::N5, seed);
        assert!(n5 < 45e6, "N5, seed {seed}: {:.1} Mbit/s on a 30 Mbit/s link", n5 / 1e6);
        let (_, n7) = tiled_typing_estimates(NetworkConditions::N7, seed);
        assert!(n7 < 3e6, "N7, seed {seed}: {:.1} Mbit/s on a 1 Mbit/s link", n7 / 1e6);
        let (n0, _) = tiled_typing_estimates(NetworkConditions::N0, seed);
        assert!(n0 >= 60e6, "N0, seed {seed}: {:.1} Mbit/s", n0 / 1e6);
    }
}
