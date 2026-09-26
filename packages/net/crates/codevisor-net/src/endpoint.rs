//! The tunnel endpoint: one per device, addressed by its Ed25519 key.
//!
//! Built on iroh's `Minimal` preset so nothing depends on n0 infrastructure:
//! no n0 relays, no DNS/pkarr address lookup. Relays come from our relay map
//! and peer addresses from our hub (`NetAddr`), never from n0.

use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::{Context, Result, anyhow};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey,
    Watcher,
    endpoint::{Connection, presets},
    tls::CaTlsConfig,
};
use tokio::{sync::{Mutex, watch}, task::JoinHandle};

use crate::{
    config::{NetConfig, PathPolicy},
    media::DatagramRouter,
    message_stream::MessageStream,
};

/// How a device can be reached: what the hub distributes in presence.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NetAddr {
    /// Hex Ed25519 public key.
    pub endpoint_id: String,
    pub relay_url: Option<String>,
    /// `ip:port` candidates (LAN, public via QAD, tailnet).
    pub direct_addrs: Vec<String>,
}

/// One currently-open path of a connection.
#[derive(Debug, Clone, PartialEq)]
pub struct PathInfo {
    pub is_relay: bool,
    /// `ip:port` for direct paths, the relay URL for relay paths.
    pub remote: String,
    pub selected: bool,
    pub rtt_ms: f64,
}

/// Generates a fresh endpoint secret key (32 bytes).
pub fn generate_secret_key() -> [u8; 32] {
    SecretKey::generate().to_bytes()
}

/// The hex endpoint id belonging to a secret key.
pub fn endpoint_id_for(secret_key: &[u8; 32]) -> String {
    SecretKey::from_bytes(secret_key).public().to_string()
}

pub struct NetEndpoint {
    endpoint: Endpoint,
    addr_updates: Mutex<(watch::Receiver<NetAddr>, bool)>,
    addr_task: JoinHandle<()>,
}

impl NetEndpoint {
    pub async fn bind(config: NetConfig) -> Result<Self> {
        let mut builder = Endpoint::builder(presets::Minimal)
            .secret_key(SecretKey::from_bytes(&config.secret_key))
            .alpns(config.alpns.clone());

        let relays = config
            .relays
            .iter()
            .map(|relay| {
                let url: RelayUrl = relay.url.parse().with_context(|| format!("bad relay URL {}", relay.url))?;
                let quic = relay.quic_port.map(iroh_relay_quic_config);
                Ok(RelayConfig::new(url, quic))
            })
            .collect::<Result<Vec<_>>>()?;
        builder = builder.relay_mode(if relays.is_empty() {
            RelayMode::Disabled
        } else {
            RelayMode::Custom(RelayMap::from_iter(relays))
        });

        let anchors = config.trust_anchors()?;
        if !anchors.is_empty() {
            builder = builder.ca_tls_config(CaTlsConfig::embedded().with_extra_roots(anchors));
        }

        match config.path_policy {
            PathPolicy::Auto => {}
            PathPolicy::RelayOnly => builder = builder.clear_ip_transports(),
            PathPolicy::DirectOnly => builder = builder.clear_relay_transports(),
        }
        if config.path_policy != PathPolicy::RelayOnly && !config.bind_addrs.is_empty() {
            builder = builder.clear_ip_transports();
            for addr in &config.bind_addrs {
                builder = builder
                    .bind_addr(addr.as_str())
                    .map_err(|error| anyhow!("invalid bind address {addr}: {error}"))?;
            }
        }

        let endpoint = builder.bind().await.context("failed to bind tunnel endpoint")?;
        let mut watcher = endpoint.watch_addr();
        let (sender, receiver) = watch::channel(net_addr(&watcher.get()));
        let addr_task = tokio::spawn(async move {
            while let Ok(addr) = watcher.updated().await {
                if sender.send(net_addr(&addr)).is_err() {
                    return;
                }
            }
        });
        Ok(Self { endpoint, addr_updates: Mutex::new((receiver, false)), addr_task })
    }

    pub fn endpoint_id(&self) -> String {
        self.endpoint.id().to_string()
    }

    pub fn addr(&self) -> NetAddr {
        net_addr(&self.endpoint.addr())
    }

    /// Waits until this endpoint's address differs from the last one returned
    /// by this method (the first call returns the current address at once).
    /// Callers loop on it and republish to the hub.
    pub async fn next_addr(&self) -> Result<NetAddr> {
        let mut guard = self.addr_updates.lock().await;
        let (receiver, started) = &mut *guard;
        if *started {
            receiver.changed().await.map_err(|_| anyhow!("endpoint closed"))?;
        }
        *started = true;
        Ok(receiver.borrow_and_update().clone())
    }

    /// Resolves once a home relay is connected, or errors after `timeout`.
    pub async fn online(&self, timeout: Duration) -> Result<()> {
        tokio::time::timeout(timeout, self.endpoint.online())
            .await
            .map_err(|_| anyhow!("no home relay after {timeout:?}"))
    }

    pub async fn connect(&self, addr: &NetAddr, alpn: &[u8]) -> Result<NetConnection> {
        let connection = self
            .endpoint
            .connect(endpoint_addr(addr)?, alpn)
            .await
            .with_context(|| format!("connecting to {}", addr.endpoint_id))?;
        Ok(NetConnection::new(connection))
    }

    /// Accepts the next incoming connection, completing its handshake.
    /// `Ok(None)` once the endpoint is closed. A failed handshake is an
    /// `Err` for that attempt only; keep accepting.
    pub async fn accept(&self) -> Result<Option<NetConnection>> {
        let Some(incoming) = self.endpoint.accept().await else {
            return Ok(None);
        };
        let connection = incoming.accept().context("refused incoming connection")?.await?;
        Ok(Some(NetConnection::new(connection)))
    }

    pub fn bound_sockets(&self) -> Vec<String> {
        self.endpoint.bound_sockets().iter().map(ToString::to_string).collect()
    }

    pub async fn close(&self) {
        self.addr_task.abort();
        self.endpoint.close().await;
    }
}

impl Drop for NetEndpoint {
    fn drop(&mut self) {
        self.addr_task.abort();
    }
}

fn iroh_relay_quic_config(port: u16) -> iroh_relay::RelayQuicConfig {
    iroh_relay::RelayQuicConfig::new(port)
}

#[derive(Clone)]
pub struct NetConnection {
    connection: Connection,
    media: Arc<std::sync::OnceLock<Arc<DatagramRouter>>>,
}

impl NetConnection {
    fn new(connection: Connection) -> Self {
        Self { connection, media: Arc::default() }
    }

    pub fn remote_id(&self) -> String {
        self.connection.remote_id().to_string()
    }

    pub fn alpn(&self) -> Vec<u8> {
        self.connection.alpn().to_vec()
    }

    /// Opens a message stream. The peer's `accept_message_stream` resolves
    /// when the first message arrives (QUIC announces streams lazily).
    pub async fn open_message_stream(&self) -> Result<MessageStream> {
        let (send, recv) = self.connection.open_bi().await?;
        Ok(MessageStream::new(send, recv))
    }

    pub async fn accept_message_stream(&self) -> Result<MessageStream> {
        let (send, recv) = self.connection.accept_bi().await?;
        Ok(MessageStream::new(send, recv))
    }

    pub fn paths(&self) -> Vec<PathInfo> {
        self.connection
            .paths()
            .iter()
            .map(|path| PathInfo {
                is_relay: path.is_relay(),
                remote: transport_addr_string(path.remote_addr()),
                selected: path.is_selected(),
                rtt_ms: path.rtt().as_secs_f64() * 1000.0,
            })
            .collect()
    }

    pub fn max_datagram_size(&self) -> Option<usize> {
        self.connection.max_datagram_size()
    }

    /// The per-connection datagram demultiplexer used by media flows.
    pub fn media(&self) -> Arc<DatagramRouter> {
        self.media
            .get_or_init(|| DatagramRouter::start(self.connection.clone()))
            .clone()
    }

    pub fn close(&self, code: u32, reason: &str) {
        self.connection.close(code.into(), reason.as_bytes());
    }

    /// Resolves when the connection closes, with a human-readable reason.
    pub async fn closed(&self) -> String {
        self.connection.closed().await.to_string()
    }
}

fn net_addr(addr: &EndpointAddr) -> NetAddr {
    NetAddr {
        endpoint_id: addr.id.to_string(),
        relay_url: addr.relay_urls().next().map(ToString::to_string),
        direct_addrs: addr.ip_addrs().map(ToString::to_string).collect(),
    }
}

fn endpoint_addr(addr: &NetAddr) -> Result<EndpointAddr> {
    let id: EndpointId = addr.endpoint_id.parse().context("invalid endpoint id")?;
    let mut endpoint_addr = EndpointAddr::new(id);
    if let Some(url) = &addr.relay_url {
        endpoint_addr = endpoint_addr.with_relay_url(url.parse().context("invalid relay URL")?);
    }
    for direct in &addr.direct_addrs {
        let socket: SocketAddr = direct.parse().with_context(|| format!("invalid address {direct}"))?;
        endpoint_addr = endpoint_addr.with_ip_addr(socket);
    }
    Ok(endpoint_addr)
}

fn transport_addr_string(addr: &iroh::TransportAddr) -> String {
    match addr {
        iroh::TransportAddr::Ip(socket) => socket.to_string(),
        iroh::TransportAddr::Relay(url) => url.to_string(),
        other => format!("{other:?}"),
    }
}
