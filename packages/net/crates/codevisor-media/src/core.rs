use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

use anyhow::{Result, bail};
use bytes::Bytes;

use crate::{
    receiver::Receiver,
    sender::Sender,
    types::{Admission, Event, MediaConfig, OutgoingFrame, Stats},
    wire::{self, Feedback, Kind, Nack, PacketHeader},
};

/// The whole transport as a state machine with no I/O and no clock of its own (the shape of `quinn-proto`): feed it
/// datagrams and the time, and take datagrams, wake-up times and events out. One `Core` is one end of a session and
/// can both send and receive streams; [`crate::MediaSession`] drives it over a real connection, and the tests drive
/// two of them over a simulated link.
#[derive(Debug)]
pub struct Core {
    sender: Sender,
    receiver: Receiver,
    events: VecDeque<Event>,
    stats: Stats,
    max_datagram: Option<usize>,
    rtt: Duration,
}

impl Core {
    pub fn new(config: MediaConfig, now: Instant) -> Self {
        Self {
            sender: Sender::new(config, now),
            receiver: Receiver::new(config.frame_interval, now),
            events: VecDeque::new(),
            stats: Stats::default(),
            max_datagram: None,
            rtt: Duration::ZERO,
        }
    }

    /// The path's round trip, from the connection's estimate. It times NACK retries, give-up and ack probes.
    pub fn set_rtt(&mut self, rtt: Duration) {
        self.rtt = rtt;
        self.sender.set_rtt(rtt);
        self.receiver.set_rtt(rtt);
    }

    /// The largest datagram the path takes now. Frames are packetized at the size current when they're sent.
    pub fn set_max_datagram_size(&mut self, size: Option<usize>) {
        self.max_datagram = size;
    }

    /// Packetizes and queues one frame; returns its number within its stream.
    pub fn send_frame(&mut self, now: Instant, frame: OutgoingFrame<'_>) -> Result<u32> {
        let Some(max_datagram) = self.max_datagram else { bail!("the connection doesn't carry datagrams") };
        self.sender.send_frame(now, frame, max_datagram, &mut self.events, &mut self.stats)
    }

    /// Viewer: the decoder finished the frame that carried `token`.
    pub fn ack_ltr(&mut self, stream: u8, token: u64) {
        self.receiver.ack_ltr(stream, token);
    }

    pub fn handle_datagram(&mut self, now: Instant, datagram: Bytes) {
        match wire::kind_of(&datagram) {
            Some(Kind::Data | Kind::Parity) => match PacketHeader::decode(datagram) {
                Some((header, shard)) => {
                    self.receiver.on_packet(now, header, shard, &mut self.events, &mut self.stats);
                }
                None => self.stats.invalid_datagrams += 1,
            },
            Some(Kind::Feedback) => match Feedback::decode(&datagram) {
                Some(feedback) => self.sender.on_feedback(now, &feedback, &mut self.events, &mut self.stats),
                None => self.stats.invalid_datagrams += 1,
            },
            Some(Kind::Nack) => match Nack::decode(&datagram) {
                Some(nack) => self.sender.on_nack(now, &nack, &mut self.stats),
                None => self.stats.invalid_datagrams += 1,
            },
            None => self.stats.invalid_datagrams += 1,
        }
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.receiver.handle_timeout(now, &mut self.events, &mut self.stats);
        self.sender.handle_timeout(now, &mut self.events, &mut self.stats);
    }

    /// The next datagram to send at `now`: feedback first (it's tiny and time-critical), then media as pacing allows.
    pub fn poll_transmit(&mut self, now: Instant) -> Option<Bytes> {
        self.receiver.poll_transmit().or_else(|| self.sender.poll_transmit(now, &mut self.stats))
    }

    /// When to call [`handle_timeout`](Self::handle_timeout) and [`poll_transmit`](Self::poll_transmit) next.
    pub fn poll_timeout(&self, now: Instant) -> Option<Instant> {
        [self.receiver.poll_timeout(), self.sender.poll_timeout(now)].into_iter().flatten().min()
    }

    pub fn poll_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }

    pub fn admission(&self) -> Admission {
        self.sender.admission()
    }

    pub fn stats(&mut self, now: Instant) -> Stats {
        self.sender.fill_stats(now, &mut self.stats);
        self.stats.rtt = self.rtt;
        self.stats
    }

    /// Counts a datagram the transport refused (too large for the path, or the connection is gone).
    pub fn note_transport_rejected(&mut self) {
        self.stats.transport_rejected += 1;
    }
}
