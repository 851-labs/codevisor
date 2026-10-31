use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use bytes::Bytes;
use tokio::{
    sync::{Mutex as AsyncMutex, Notify, mpsc},
    task::JoinHandle,
};

use crate::{
    core::Core,
    transport::{DatagramTransport, QuicTransport, SendOutcome},
    types::{Admission, Event, MediaConfig, OutgoingFrame, SendError, Stats},
};

const RTT_REFRESH: Duration = Duration::from_millis(50);
const FULL_RETRY: Duration = Duration::from_micros(500);
const SEND_BATCH: usize = 16;
const RECV_BATCH: usize = 64;
const DUE_ROUNDS: usize = 8;

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
    held: VecDeque<Bytes>,
    rtt_at: Option<Instant>,
    events: Option<mpsc::UnboundedSender<Event>>,
}

fn now() -> Instant {
    tokio::time::Instant::now().into_std()
}

impl<T: DatagramTransport> MediaSession<T> {
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

    pub fn send_frame(&self, frame: OutgoingFrame<'_>) -> Result<u32, SendError> {
        let now = now();
        let mut state = self.shared.state.lock().unwrap();
        state.core.set_max_datagram_size(self.shared.transport.max_datagram_size());
        let number = state.core.send_frame(now, frame)?;
        drop(state);
        self.shared.wake.notify_one();
        Ok(number)
    }

    pub fn ack_ltr(&self, stream: u8, token: u64) {
        self.shared.state.lock().unwrap().core.ack_ltr(stream, token);
        self.shared.wake.notify_one();
    }

    pub fn admission(&self) -> Admission {
        self.shared.state.lock().unwrap().core.admission()
    }

    pub fn stats(&self) -> Stats {
        self.shared.state.lock().unwrap().core.stats(now())
    }

    pub async fn next_event(&self) -> Option<Event> {
        self.events.lock().await.recv().await
    }

    pub fn try_next_event(&self) -> Option<Event> {
        self.events.try_lock().ok()?.try_recv().ok()
    }

    pub fn transport(&self) -> &T {
        &self.shared.transport
    }

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
        let mut state = self.state.lock().unwrap();
        let mut now = now;
        for _ in 0..DUE_ROUNDS {
            if !state.core.poll_timeout(now).is_some_and(|next| next <= now) || !state.held.is_empty() {
                break;
            }
            state.core.handle_timeout(now);
            drop(state);
            self.pump(now);
            state = self.state.lock().unwrap();
            now = self::now();
        }
        let next = state.core.poll_timeout(now);
        if !state.held.is_empty() {
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

fn ready_now<F: std::future::Future>(future: F) -> Option<F::Output> {
    let mut future = std::pin::pin!(future);
    let mut context = std::task::Context::from_waker(std::task::Waker::noop());
    match future.as_mut().poll(&mut context) {
        std::task::Poll::Ready(output) => Some(output),
        std::task::Poll::Pending => None,
    }
}
