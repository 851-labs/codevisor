//! UDP media flows over QUIC datagrams (`codevisor/media/1`).
//!
//! Screen-sharing WebRTC keeps its own ICE/RTP stack and sees the tunnel as a
//! LAN: each side talks to a loopback UDP socket, and these flows carry the
//! packets as unreliable QUIC datagrams, entirely in Rust (never through JS
//! or Swift). Datagram layout:
//!
//! ```text
//! [flow id: u32 BE] [UDP payload]
//! ```

use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
};

use anyhow::{Context, Result, bail};
use bytes::{BufMut, Bytes, BytesMut};
use iroh::endpoint::Connection;
use tokio::{net::UdpSocket, sync::mpsc, task::JoinHandle};

pub const FLOW_HEADER_BYTES: usize = 4;
/// Per-flow queue of datagrams waiting for the local socket. Media is
/// real-time: when the consumer falls behind, new packets are dropped rather
/// than queued (the RTP stack recovers; stale packets would only add delay).
const FLOW_QUEUE: usize = 256;

pub struct DatagramRouter {
    connection: Connection,
    flows: Mutex<HashMap<u32, mpsc::Sender<Bytes>>>,
    reader: Mutex<Option<JoinHandle<()>>>,
}

impl DatagramRouter {
    pub(crate) fn start(connection: Connection) -> Arc<Self> {
        let router = Arc::new(Self {
            connection: connection.clone(),
            flows: Mutex::new(HashMap::new()),
            reader: Mutex::new(None),
        });
        let weak = Arc::downgrade(&router);
        let task = tokio::spawn(async move {
            while let Ok(datagram) = connection.read_datagram().await {
                let Some(router) = weak.upgrade() else { return };
                let Some((flow_id, payload)) = split_datagram(datagram) else { continue };
                let sender = router.flows.lock().unwrap().get(&flow_id).cloned();
                if let Some(sender) = sender {
                    let _ = sender.try_send(payload);
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

    /// Largest UDP payload a flow can carry right now (`None` when the peer
    /// doesn't accept datagrams). Callers cap their RTP packet size by it.
    pub fn max_payload(&self) -> Option<usize> {
        self.connection
            .max_datagram_size()
            .map(|size| size.saturating_sub(FLOW_HEADER_BYTES))
    }

    fn send(&self, flow_id: u32, payload: &[u8]) {
        // Oversized or congested datagrams are dropped, exactly like UDP.
        let _ = self.connection.send_datagram(join_datagram(flow_id, payload));
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

/// A running flow; dropping or closing it stops forwarding and frees the
/// flow id.
pub struct MediaFlow {
    router: Arc<DatagramRouter>,
    flow_id: u32,
    local_port: u16,
    tasks: Vec<JoinHandle<()>>,
}

impl MediaFlow {
    /// Host side: forward the flow to a fixed local UDP target (the host
    /// WebRTC's own candidate). A non-loopback target is reached from a socket
    /// on all interfaces, so its packets carry the host's LAN address and
    /// WebRTC sees an ordinary LAN peer (libwebrtc ignores loopback networks).
    pub async fn forward(router: Arc<DatagramRouter>, flow_id: u32, target: SocketAddr) -> Result<Self> {
        let bind: IpAddr = if target.ip().is_loopback() { Ipv4Addr::LOCALHOST.into() } else { Ipv4Addr::UNSPECIFIED.into() };
        let socket = UdpSocket::bind((bind, 0)).await?;
        Self::run(router, flow_id, socket, Some(target))
    }

    /// Viewer side: a local UDP port on all interfaces for the local WebRTC
    /// stack to send to (the viewer names it with its own LAN address).
    /// Replies go to whichever local address last sent to it.
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
                        // Host side: only the configured target may inject.
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
