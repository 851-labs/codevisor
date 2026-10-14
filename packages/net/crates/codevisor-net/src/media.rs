use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering::Relaxed},
    },
};

use anyhow::{Context, Result, bail};
use bytes::{BufMut, Bytes, BytesMut};
use iroh::endpoint::{Connection, SendDatagramError};
use tokio::{
    net::UdpSocket,
    sync::mpsc::{self, error::TrySendError},
    task::JoinHandle,
};

pub const FLOW_HEADER_BYTES: usize = 4;
const FLOW_QUEUE: usize = 256;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MediaStats {
    pub sent: u64,
    pub sent_bytes: u64,
    pub too_large: u64,
    pub largest_too_large: u64,
    pub send_failed: u64,
    pub received: u64,
    pub received_bytes: u64,
    pub unknown_flow: u64,
    pub queue_full: u64,
}

#[derive(Default)]
struct MediaCounters {
    sent: AtomicU64,
    sent_bytes: AtomicU64,
    too_large: AtomicU64,
    largest_too_large: AtomicU64,
    send_failed: AtomicU64,
    received: AtomicU64,
    received_bytes: AtomicU64,
    unknown_flow: AtomicU64,
    queue_full: AtomicU64,
}

pub struct DatagramRouter {
    connection: Connection,
    flows: Mutex<HashMap<u32, mpsc::Sender<Bytes>>>,
    reader: Mutex<Option<JoinHandle<()>>>,
    counters: MediaCounters,
}

impl DatagramRouter {
    pub(crate) fn start(connection: Connection) -> Arc<Self> {
        let router = Arc::new(Self {
            connection: connection.clone(),
            flows: Mutex::new(HashMap::new()),
            reader: Mutex::new(None),
            counters: MediaCounters::default(),
        });
        let weak = Arc::downgrade(&router);
        let task = tokio::spawn(async move {
            while let Ok(datagram) = connection.read_datagram().await {
                let Some(router) = weak.upgrade() else { return };
                let counters = &router.counters;
                counters.received.fetch_add(1, Relaxed);
                counters.received_bytes.fetch_add(datagram.len() as u64, Relaxed);
                let Some((flow_id, payload)) = split_datagram(datagram) else { continue };
                let sender = router.flows.lock().unwrap().get(&flow_id).cloned();
                match sender.map(|sender| sender.try_send(payload)) {
                    None | Some(Err(TrySendError::Closed(_))) => {
                        counters.unknown_flow.fetch_add(1, Relaxed);
                    }
                    Some(Err(TrySendError::Full(_))) => {
                        counters.queue_full.fetch_add(1, Relaxed);
                    }
                    Some(Ok(())) => {}
                }
            }
        });
        *router.reader.lock().unwrap() = Some(task);
        router
    }

    fn register(&self, flow_id: u32) -> Result<mpsc::Receiver<Bytes>> {
        let mut flows = self.flows.lock().unwrap();
        if flows.contains_key(&flow_id) {
            bail!("media flow {flow_id} is already open on this connection");
        }
        let (sender, receiver) = mpsc::channel(FLOW_QUEUE);
        flows.insert(flow_id, sender);
        Ok(receiver)
    }

    fn unregister(&self, flow_id: u32) {
        self.flows.lock().unwrap().remove(&flow_id);
    }

    pub fn max_payload(&self) -> Option<usize> {
        self.connection
            .max_datagram_size()
            .map(|size| size.saturating_sub(FLOW_HEADER_BYTES))
    }

    pub fn stats(&self) -> MediaStats {
        let counters = &self.counters;
        MediaStats {
            sent: counters.sent.load(Relaxed),
            sent_bytes: counters.sent_bytes.load(Relaxed),
            too_large: counters.too_large.load(Relaxed),
            largest_too_large: counters.largest_too_large.load(Relaxed),
            send_failed: counters.send_failed.load(Relaxed),
            received: counters.received.load(Relaxed),
            received_bytes: counters.received_bytes.load(Relaxed),
            unknown_flow: counters.unknown_flow.load(Relaxed),
            queue_full: counters.queue_full.load(Relaxed),
        }
    }

    fn send(&self, flow_id: u32, payload: &[u8]) {
        let counters = &self.counters;
        match self.connection.send_datagram(join_datagram(flow_id, payload)) {
            Ok(()) => {
                counters.sent.fetch_add(1, Relaxed);
                counters.sent_bytes.fetch_add(payload.len() as u64, Relaxed);
            }
            Err(SendDatagramError::TooLarge) => {
                counters.too_large.fetch_add(1, Relaxed);
                counters.largest_too_large.fetch_max(payload.len() as u64, Relaxed);
            }
            Err(_) => {
                counters.send_failed.fetch_add(1, Relaxed);
            }
        }
    }
}

impl Drop for DatagramRouter {
    fn drop(&mut self) {
        if let Some(task) = self.reader.lock().unwrap().take() {
            task.abort();
        }
    }
}

pub fn join_datagram(flow_id: u32, payload: &[u8]) -> Bytes {
    let mut datagram = BytesMut::with_capacity(FLOW_HEADER_BYTES + payload.len());
    datagram.put_u32(flow_id);
    datagram.put_slice(payload);
    datagram.freeze()
}

pub fn split_datagram(mut datagram: Bytes) -> Option<(u32, Bytes)> {
    if datagram.len() < FLOW_HEADER_BYTES {
        return None;
    }
    let header = datagram.split_to(FLOW_HEADER_BYTES);
    Some((u32::from_be_bytes([header[0], header[1], header[2], header[3]]), datagram))
}

pub struct MediaFlow {
    router: Arc<DatagramRouter>,
    flow_id: u32,
    local_port: u16,
    tasks: Vec<JoinHandle<()>>,
}

impl MediaFlow {
    pub async fn forward(router: Arc<DatagramRouter>, flow_id: u32, target: SocketAddr) -> Result<Self> {
        let bind: IpAddr = if target.ip().is_loopback() { Ipv4Addr::LOCALHOST.into() } else { Ipv4Addr::UNSPECIFIED.into() };
        let socket = UdpSocket::bind((bind, 0)).await?;
        Self::run(router, flow_id, socket, Some(target))
    }

    pub async fn bind(router: Arc<DatagramRouter>, flow_id: u32) -> Result<Self> {
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
        Self::run(router, flow_id, socket, None)
    }

    fn run(router: Arc<DatagramRouter>, flow_id: u32, socket: UdpSocket, target: Option<SocketAddr>) -> Result<Self> {
        let local_port = socket.local_addr().context("flow socket has no address")?.port();
        let mut from_tunnel = router.register(flow_id)?;
        let socket = Arc::new(socket);
        let peer = Arc::new(Mutex::new(target));

        let outbound = {
            let (socket, peer, router) = (socket.clone(), peer.clone(), router.clone());
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 65_536];
                while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
                    let mut known = peer.lock().unwrap();
                    match *known {
                        Some(expected) if target.is_some() && expected != from => continue,
                        _ => *known = Some(from),
                    }
                    drop(known);
                    router.send(flow_id, &buffer[..len]);
                }
            })
        };
        let inbound = tokio::spawn(async move {
            while let Some(payload) = from_tunnel.recv().await {
                let destination = *peer.lock().unwrap();
                if let Some(destination) = destination {
                    let _ = socket.send_to(&payload, destination).await;
                }
            }
        });
        Ok(Self { router, flow_id, local_port, tasks: vec![outbound, inbound] })
    }

    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    pub fn close(&mut self) {
        for task in self.tasks.drain(..) {
            task.abort();
        }
        self.router.unregister(self.flow_id);
    }
}

impl Drop for MediaFlow {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datagrams_use_a_big_endian_flow_id_before_the_payload() {
        assert_eq!(
            &join_datagram(0xDEAD_BEEF, b"rtp")[..],
            b"\xDE\xAD\xBE\xEFrtp"
        );
        let (flow, payload) = split_datagram(Bytes::from_static(b"\xDE\xAD\xBE\xEFrtp")).unwrap();
        assert_eq!(flow, 0xDEAD_BEEF);
        assert_eq!(&payload[..], b"rtp");
    }

    #[test]
    fn short_datagrams_are_ignored() {
        assert!(split_datagram(Bytes::from_static(b"abc")).is_none());
    }
}
