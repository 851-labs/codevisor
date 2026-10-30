use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::Result;
use bytes::Bytes;
use tokio::{
    sync::{Mutex as AsyncMutex, Notify, mpsc},
    task::JoinHandle,
};

use crate::{
    core::Core,
    transport::{DatagramTransport, QuicTransport, SendOutcome},
    types::{Admission, Event, MediaConfig, OutgoingFrame, Stats},
};

/// How often the connection's round-trip estimate is copied into the core.
const RTT_REFRESH: Duration = Duration::from_millis(50);
/// How soon a datagram the transport had no room for is offered again.
const FULL_RETRY: Duration = Duration::from_micros(500);

/// One end of a media session, driving a [`Core`] over a transport on the tokio runtime. Every method is cheap and
/// non-blocking except [`next_event`](Self::next_event); the frame calls send what pacing allows right away, on the
/// caller's thread, and a background task handles arrivals and timers.
pub struct MediaSession<T: DatagramTransport = QuicTransport> {
    shared: Arc<Shared<T>>,
    events: AsyncMutex<mpsc::UnboundedReceiver<Event>>,
    task: JoinHandle<()>,
}

struct Shared<T> {
    state: Mutex<State>,
    transport: T,
    wake: Notify,
}

struct State {
    core: Core,
    /// A datagram the transport had no room for; it goes before anything new.
    held: Option<Bytes>,
    rtt_at: Option<Instant>,
    /// Dropped when the transport closes, which ends [`MediaSession::next_event`].
    events: Option<mpsc::UnboundedSender<Event>>,
}

fn now() -> Instant {
    tokio::time::Instant::now().into_std()
}

impl<T: DatagramTransport> MediaSession<T> {
    /// Starts a session. It owns the transport's incoming datagrams from now on. Must run inside a tokio runtime.
    pub fn new(transport: T, config: MediaConfig) -> Self {
        let mut core = Core::new(config, now());
        core.set_max_datagram_size(transport.max_datagram_size());
        let (events, receiver) = mpsc::unbounded_channel();
        let shared = Arc::new(Shared {
            state: Mutex::new(State { core, held: None, rtt_at: None, events: Some(events) }),
            transport,
            wake: Notify::new(),
        });
        let task = tokio::spawn(drive(shared.clone()));
        Self { shared, events: AsyncMutex::new(receiver), task }
    }

    /// Host: packetizes one encoded tile and starts sending it. Returns the frame's number within its stream.
    pub fn send_frame(&self, frame: OutgoingFrame) -> Result<u32> {
        let now = now();
        let mut state = self.shared.state.lock().unwrap();
        state.core.set_max_datagram_size(self.shared.transport.max_datagram_size());
        let number = state.core.send_frame(now, frame)?;
        self.shared.pump(&mut state, now);
        drop(state);
        self.shared.wake.notify_one();
        Ok(number)
    }

    /// Viewer: the decoder finished the frame that carried `token`.
    pub fn ack_ltr(&self, stream: u8, token: u64) {
        let mut state = self.shared.state.lock().unwrap();
        state.core.ack_ltr(stream, token);
        self.shared.pump(&mut state, now());
    }

    /// Host: whether to encode the next capture.
    pub fn admission(&self) -> Admission {
        self.shared.state.lock().unwrap().core.admission()
    }

    pub fn stats(&self) -> Stats {
        self.shared.state.lock().unwrap().core.stats(now())
    }

    /// The next event; `None` once the session's transport closed. Frames and acks wait here until taken, so take
    /// them promptly: nothing is dropped.
    pub async fn next_event(&self) -> Option<Event> {
        self.events.lock().await.recv().await
    }

    /// The next event if one is waiting.
    pub fn try_next_event(&self) -> Option<Event> {
        self.events.try_lock().ok()?.try_recv().ok()
    }

    pub fn transport(&self) -> &T {
        &self.shared.transport
    }

    /// Stops the session's task. The connection stays open; close it separately.
    pub fn close(&self) {
        self.task.abort();
    }
}

impl<T: DatagramTransport> Drop for MediaSession<T> {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl<T: DatagramTransport> Shared<T> {
    /// Sends what the core has ready and hands its events over.
    fn pump(&self, state: &mut State, now: Instant) {
        loop {
            let Some(datagram) = state.held.take().or_else(|| state.core.poll_transmit(now)) else {
                break;
            };
            match self.transport.send(datagram) {
                SendOutcome::Sent => {}
                SendOutcome::Full(datagram) => {
                    state.held = Some(datagram);
                    break;
                }
                SendOutcome::Rejected => state.core.note_transport_rejected(),
            }
        }
        while let Some(event) = state.core.poll_event() {
            if let Some(events) = &state.events {
                let _ = events.send(event);
            }
        }
    }

    /// Pumps, then says when the core next needs attention.
    fn settle(&self, state: &mut State) -> Option<Instant> {
        let now = now();
        if state.rtt_at.is_none_or(|at| now.saturating_duration_since(at) >= RTT_REFRESH) {
            if let Some(rtt) = self.transport.rtt() {
                state.core.set_rtt(rtt);
            }
            state.rtt_at = Some(now);
        }
        self.pump(state, now);
        let next = state.core.poll_timeout(now);
        if state.held.is_some() {
            // The pacer would say "now" while the transport has no room; wait for room instead of spinning.
            return Some(next.map_or(now + FULL_RETRY, |next| next.max(now + FULL_RETRY)));
        }
        next
    }
}

async fn drive<T: DatagramTransport>(shared: Arc<Shared<T>>) {
    loop {
        let deadline = shared.settle(&mut shared.state.lock().unwrap());
        let sleep = async {
            match deadline {
                Some(deadline) => tokio::time::sleep_until(deadline.into()).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            datagram = shared.transport.recv() => {
                let Some(datagram) = datagram else { break };
                let mut state = shared.state.lock().unwrap();
                state.core.handle_datagram(now(), datagram);
            }
            () = sleep => {
                shared.state.lock().unwrap().core.handle_timeout(now());
            }
            () = shared.wake.notified() => {}
        }
    }
    let mut state = shared.state.lock().unwrap();
    shared.settle(&mut state);
    state.events = None;
}
