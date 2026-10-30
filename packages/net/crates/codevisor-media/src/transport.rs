use std::{future::Future, net::SocketAddr, sync::Mutex, time::Duration};

use bytes::Bytes;
use codevisor_net::{DatagramSendError, NetConnection};
use tokio::{net::UdpSocket, sync::mpsc, time::Instant};

use crate::netsim::{Fate, NetworkConditions, NetworkModel};

#[derive(Debug, PartialEq, Eq)]
pub enum SendOutcome {
    Sent,
    /// The transport has no room right now; offer this datagram again shortly.
    Full(Bytes),
    /// Too large for the path, or the connection is gone.
    Rejected,
}

/// Where a [`crate::MediaSession`]'s datagrams go: QUIC datagrams on an iroh connection in the product, plain UDP
/// as the raw-UDP baseline (and the design's fallback), or either through an emulated network in the bench.
pub trait DatagramTransport: Send + Sync + 'static {
    fn max_datagram_size(&self) -> Option<usize>;
    /// Sends without waiting. A full send buffer hands the datagram back instead of dropping an older one.
    fn send(&self, datagram: Bytes) -> SendOutcome;
    /// The next received datagram; `None` once the transport is closed. Must be cancel safe.
    fn recv(&self) -> impl Future<Output = Option<Bytes>> + Send;
    fn rtt(&self) -> Option<Duration>;
}

/// QUIC datagrams on a `codevisor/screen/1` connection.
pub struct QuicTransport(pub NetConnection);

impl DatagramTransport for QuicTransport {
    fn max_datagram_size(&self) -> Option<usize> {
        self.0.max_datagram_size()
    }

    fn send(&self, datagram: Bytes) -> SendOutcome {
        // QUIC drops the oldest queued datagram to make room; hand this one back instead, so the pacer's backlog
        // (and with it the encoder's admission) sees the congestion.
        if self.0.datagram_send_buffer_space() < datagram.len() {
            return SendOutcome::Full(datagram);
        }
        match self.0.send_datagram(datagram) {
            Ok(()) => SendOutcome::Sent,
            Err(DatagramSendError::TooLarge | DatagramSendError::Unsupported | DatagramSendError::ConnectionLost) => {
                SendOutcome::Rejected
            }
        }
    }

    async fn recv(&self) -> Option<Bytes> {
        self.0.read_datagram().await.ok()
    }

    fn rtt(&self) -> Option<Duration> {
        self.0.rtt()
    }
}

/// Plain UDP to one peer: the bench's raw-UDP baseline. It has no round-trip estimate of its own, so it reports the
/// one it's given. The peer is fixed, or (for the listening side) the source of the first datagram.
pub struct UdpTransport {
    socket: UdpSocket,
    peer: Mutex<Option<SocketAddr>>,
    max_datagram: usize,
    rtt: Duration,
}

impl UdpTransport {
    pub fn new(socket: UdpSocket, peer: Option<SocketAddr>, max_datagram: usize, rtt: Duration) -> Self {
        Self { socket, peer: Mutex::new(peer), max_datagram, rtt }
    }
}

impl DatagramTransport for UdpTransport {
    fn max_datagram_size(&self) -> Option<usize> {
        Some(self.max_datagram)
    }

    fn send(&self, datagram: Bytes) -> SendOutcome {
        let Some(peer) = *self.peer.lock().unwrap() else {
            return SendOutcome::Rejected;
        };
        match self.socket.try_send_to(&datagram, peer) {
            Ok(_) => SendOutcome::Sent,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => SendOutcome::Full(datagram),
            // macOS answers a full socket buffer with ENOBUFS rather than blocking.
            Err(error) if error.raw_os_error() == Some(55) => SendOutcome::Full(datagram),
            Err(_) => SendOutcome::Rejected,
        }
    }

    async fn recv(&self) -> Option<Bytes> {
        loop {
            self.socket.readable().await.ok()?;
            // Datagrams on a path never exceed its MTU; anything longer is truncated and fails its header checks.
            let mut buffer = vec![0u8; self.max_datagram.max(1500) + 64];
            let (len, from) = match self.socket.try_recv_from(&mut buffer) {
                Ok(received) => received,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => return None,
            };
            let mut peer = self.peer.lock().unwrap();
            match *peer {
                Some(expected) if expected != from => continue,
                _ => *peer = Some(from),
            }
            buffer.truncate(len);
            return Some(Bytes::from(buffer));
        }
    }

    fn rtt(&self) -> Option<Duration> {
        Some(self.rtt)
    }
}

/// Sends through a seeded [`NetworkModel`] before the inner transport: the loss, delay and link rate of one of the
/// benchmark's network conditions, applied to this end's outgoing datagrams (wrap both ends for both directions).
/// The reported round trip adds the emulated delay both ways.
pub struct ImpairedTransport<T> {
    inner: std::sync::Arc<T>,
    model: Mutex<(NetworkModel, Instant)>,
    /// Datagrams waiting in the delay queue; while there are any, new ones queue behind them to keep the order.
    queued: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    delayed: mpsc::UnboundedSender<(Instant, Bytes)>,
    forwarder: tokio::task::JoinHandle<()>,
}

impl<T: DatagramTransport> ImpairedTransport<T> {
    pub fn new(inner: T, conditions: NetworkConditions, seed: u64) -> Self {
        let inner = std::sync::Arc::new(inner);
        let (delayed, mut queue) = mpsc::unbounded_channel::<(Instant, Bytes)>();
        let queued = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let forwarder = {
            let (inner, queued) = (inner.clone(), queued.clone());
            tokio::spawn(async move {
                while let Some((due, datagram)) = queue.recv().await {
                    tokio::time::sleep_until(due).await;
                    let mut datagram = datagram;
                    while let SendOutcome::Full(back) = inner.send(datagram) {
                        tokio::time::sleep(Duration::from_micros(200)).await;
                        datagram = back;
                    }
                    queued.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                }
            })
        };
        let model = Mutex::new((NetworkModel::new(conditions, seed), Instant::now()));
        Self { inner, model, queued, delayed, forwarder }
    }
}

impl<T> Drop for ImpairedTransport<T> {
    fn drop(&mut self) {
        self.forwarder.abort();
    }
}

impl<T: DatagramTransport> DatagramTransport for ImpairedTransport<T> {
    fn max_datagram_size(&self) -> Option<usize> {
        self.inner.max_datagram_size()
    }

    fn send(&self, datagram: Bytes) -> SendOutcome {
        let now = Instant::now();
        let mut model = self.model.lock().unwrap();
        let (model, epoch) = &mut *model;
        let Fate::Delivered(at) = model.send(datagram.len(), now - *epoch) else {
            return SendOutcome::Sent;
        };
        let due = *epoch + at;
        // Due now with nothing ahead of it (N0, or an idle link): send at once rather than through a 1 ms timer.
        if due <= now && self.queued.load(std::sync::atomic::Ordering::SeqCst) == 0 {
            return self.inner.send(datagram);
        }
        self.queued.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let _ = self.delayed.send((due, datagram));
        SendOutcome::Sent
    }

    async fn recv(&self) -> Option<Bytes> {
        self.inner.recv().await
    }

    fn rtt(&self) -> Option<Duration> {
        let delay = Duration::from_secs_f64(self.model.lock().unwrap().0.conditions.delay_ms / 1000.0);
        Some(self.inner.rtt().unwrap_or_default() + delay * 2)
    }
}
