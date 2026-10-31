use std::{
    collections::VecDeque,
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
/// Datagrams taken from the core per lock, so frame hand-offs interleave with a burst going out.
const SEND_BATCH: usize = 16;
/// Datagrams handled per wake-up before the session settles (sends, timers, events).
const RECV_BATCH: usize = 64;
/// Rounds of already-due timers a settle runs before it yields (the pacer can stay due while it drains a burst).
const DUE_ROUNDS: usize = 8;

/// One end of a media session, driving a [`Core`] over a transport on the tokio runtime. Every method is cheap and
/// non-blocking except [`next_event`](Self::next_event): [`send_frame`](Self::send_frame) only packetizes and queues
/// (so the encoder's thread never waits on the network), and a background task sends, receives and runs the timers.
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
    /// Datagrams the transport had no room for; they go before anything new.
    held: VecDeque<Bytes>,
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
            state: Mutex::new(State { core, held: VecDeque::new(), rtt_at: None, events: Some(events) }),
            transport,
            wake: Notify::new(),
        });
        let task = tokio::spawn(drive(shared.clone()));
        Self { shared, events: AsyncMutex::new(receiver), task }
    }

    /// Host: packetizes one encoded tile and queues it for the session's task to send. Returns the frame's number
    /// within its stream.
    pub fn send_frame(&self, frame: OutgoingFrame<'_>) -> Result<u32> {
        let now = now();
        let mut state = self.shared.state.lock().unwrap();
        state.core.set_max_datagram_size(self.shared.transport.max_datagram_size());
        let number = state.core.send_frame(now, frame)?;
        drop(state);
        self.shared.wake.notify_one();
        Ok(number)
    }

    /// Viewer: the decoder finished the frame that carried `token`.
    pub fn ack_ltr(&self, stream: u8, token: u64) {
        self.shared.state.lock().unwrap().core.ack_ltr(stream, token);
        self.shared.wake.notify_one();
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

    /// Stops the session's task and ends [`next_event`](Self::next_event) once the waiting events are taken. The
    /// connection stays open; close it separately.
    pub fn close(&self) {
        self.task.abort();
        self.shared.state.lock().unwrap().events = None;
    }
}

impl<T: DatagramTransport> Drop for MediaSession<T> {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl<T: DatagramTransport> Shared<T> {
    /// Sends what the core has ready, a batch at a time with the lock released while the transport works, so
    /// [`MediaSession::send_frame`] never waits behind a burst. Then hands the core's events over.
    fn pump(&self, now: Instant) {
        loop {
            let mut batch = {
                let mut state = self.state.lock().unwrap();
                let mut batch = std::mem::take(&mut state.held);
                while batch.len() < SEND_BATCH {
                    let Some(datagram) = state.core.poll_transmit(now) else { break };
                    batch.push_back(datagram);
                }
                batch
            };
            if batch.is_empty() {
                break;
            }
            let mut rejected = 0;
            while let Some(datagram) = batch.pop_front() {
                match self.transport.send(datagram) {
                    SendOutcome::Sent => {}
                    SendOutcome::Full(datagram) => {
                        batch.push_front(datagram);
                        break;
                    }
                    SendOutcome::Rejected => rejected += 1,
                }
            }
            let mut state = self.state.lock().unwrap();
            for _ in 0..rejected {
                state.core.note_transport_rejected();
            }
            if !batch.is_empty() {
                state.held = batch;
                break;
            }
        }
        let mut state = self.state.lock().unwrap();
        while let Some(event) = state.core.poll_event() {
            if let Some(events) = &state.events {
                let _ = events.send(event);
            }
        }
    }

    /// Pumps, then says when the core next needs attention.
    fn settle(&self) -> Option<Instant> {
        let now = now();
        {
            let mut state = self.state.lock().unwrap();
            if state.rtt_at.is_none_or(|at| now.saturating_duration_since(at) >= RTT_REFRESH) {
                if let Some(rtt) = self.transport.rtt() {
                    state.core.set_rtt(rtt);
                }
                state.rtt_at = Some(now);
            }
        }
        self.pump(now);
        // Timers already due run now rather than on tokio's next 1 ms tick (a NACK waits on this).
        let mut state = self.state.lock().unwrap();
        for _ in 0..DUE_ROUNDS {
            if !state.core.poll_timeout(now).is_some_and(|next| next <= now) || !state.held.is_empty() {
                break;
            }
            state.core.handle_timeout(now);
            drop(state);
            self.pump(now);
            state = self.state.lock().unwrap();
        }
        let next = state.core.poll_timeout(now);
        if !state.held.is_empty() {
            // The pacer would say "now" while the transport has no room; wait for room instead of spinning.
            return Some(next.map_or(now + FULL_RETRY, |next| next.max(now + FULL_RETRY)));
        }
        next
    }
}

async fn drive<T: DatagramTransport>(shared: Arc<Shared<T>>) {
    loop {
        let deadline = shared.settle();
        let sleep = async {
            match deadline {
                Some(deadline) => tokio::time::sleep_until(deadline.into()).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            datagram = shared.transport.recv() => {
                let Some(datagram) = datagram else { break };
                let now = now();
                let mut state = shared.state.lock().unwrap();
                state.core.handle_datagram(now, datagram);
                // Take whatever else already arrived under the same lock, before the next settle's timer scan.
                let mut closed = false;
                for _ in 0..RECV_BATCH {
                    match ready_now(shared.transport.recv()) {
                        Some(Some(datagram)) => state.core.handle_datagram(now, datagram),
                        Some(None) => {
                            closed = true;
                            break;
                        }
                        None => break,
                    }
                }
                if closed {
                    break;
                }
            }
            () = sleep => {
                shared.state.lock().unwrap().core.handle_timeout(now());
            }
            () = shared.wake.notified() => {}
        }
    }
    shared.settle();
    shared.state.lock().unwrap().events = None;
}

/// Polls `future` once: its output if it's ready now, without waiting.
fn ready_now<F: std::future::Future>(future: F) -> Option<F::Output> {
    let mut future = std::pin::pin!(future);
    let mut context = std::task::Context::from_waker(std::task::Waker::noop());
    match future.as_mut().poll(&mut context) {
        std::task::Poll::Ready(output) => Some(output),
        std::task::Poll::Pending => None,
    }
}
