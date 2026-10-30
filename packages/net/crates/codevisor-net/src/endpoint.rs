use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::{Context, Result, anyhow};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey,
    Watcher,
    endpoint::{Connection, Incoming, presets},
    tls::CaTlsConfig,
};
use tokio::{
    sync::{Mutex, mpsc, watch},
    task::{JoinHandle, JoinSet},
};

use crate::{
    config::{NetConfig, PathPolicy},
    media::DatagramRouter,
    message_stream::MessageStream,
};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NetAddr {
    pub endpoint_id: String,
    pub relay_url: Option<String>,
    pub direct_addrs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PathInfo {
    pub is_relay: bool,
    pub remote: String,
    pub selected: bool,
    pub rtt_ms: f64,
    pub current_mtu: u16,
    pub cwnd: u64,
    pub lost_packets: u64,
    pub congestion_events: u64,
    pub black_holes_detected: u64,
    pub datagrams_sent: u64,
}

pub fn generate_secret_key() -> [u8; 32] {
    SecretKey::generate().to_bytes()
}

pub fn endpoint_id_for(secret_key: &[u8; 32]) -> String {
    SecretKey::from_bytes(secret_key).public().to_string()
}

const MAX_PENDING_HANDSHAKES: usize = 64;

#[derive(Debug)]
pub struct CancelToken(watch::Sender<bool>);

impl Default for CancelToken {
    fn default() -> Self {
        Self(watch::channel(false).0)
    }
}

impl CancelToken {
    pub fn cancel(&self) {
        self.0.send_replace(true);
    }

    pub fn is_cancelled(&self) -> bool {
        *self.0.borrow()
    }

    pub async fn cancelled(&self) {
        let mut receiver = self.0.subscribe();
        let _ = receiver.wait_for(|cancelled| *cancelled).await;
    }
}

pub struct NetEndpoint {
    endpoint: Endpoint,
    addr_updates: Mutex<(watch::Receiver<NetAddr>, bool)>,
    addr_task: JoinHandle<()>,
    accepted: Mutex<Option<mpsc::UnboundedReceiver<Result<NetConnection>>>>,
    accept_task: std::sync::Mutex<Option<JoinHandle<()>>>,
}

impl NetEndpoint {
    pub async fn bind(config: NetConfig) -> Result<Self> {
        let mut builder = Endpoint::builder(presets::Minimal)
            .secret_key(SecretKey::from_bytes(&config.secret_key))
            .alpns(config.alpns.clone());
        if let Ok(tuning) = std::env::var("CODEVISOR_NET_MEDIA_TUNING") {
            builder = builder.transport_config(media_lab_tuning(&tuning)?);
        }

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
        Ok(Self {
            endpoint,
            addr_updates: Mutex::new((receiver, false)),
            addr_task,
            accepted: Mutex::new(None),
            accept_task: std::sync::Mutex::new(None),
        })
    }

    pub fn endpoint_id(&self) -> String {
        self.endpoint.id().to_string()
    }

    pub fn addr(&self) -> NetAddr {
        net_addr(&self.endpoint.addr())
    }

    pub async fn next_addr(&self) -> Result<NetAddr> {
        let mut guard = self.addr_updates.lock().await;
        let (receiver, started) = &mut *guard;
        if *started {
            receiver.changed().await.map_err(|_| anyhow!("endpoint closed"))?;
        }
        *started = true;
        Ok(receiver.borrow_and_update().clone())
    }

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

    pub async fn connect_cancellable(&self, addr: &NetAddr, alpn: &[u8], cancel: &CancelToken) -> Result<NetConnection> {
        tokio::select! {
            biased;
            () = cancel.cancelled() => Err(anyhow!("connecting to {} cancelled", addr.endpoint_id)),
            result = self.connect(addr, alpn) => result,
        }
    }

    pub async fn network_change(&self) {
        self.endpoint.network_change().await;
    }

    pub async fn accept(&self) -> Result<Option<NetConnection>> {
        let mut accepted = self.accepted.lock().await;
        let receiver = accepted.get_or_insert_with(|| {
            let (sender, receiver) = mpsc::unbounded_channel();
            let task = tokio::spawn(drive_accepts(self.endpoint.clone(), sender));
            *self.accept_task.lock().expect("accept task lock") = Some(task);
            receiver
        });
        match receiver.recv().await {
            Some(result) => result.map(Some),
            None => Ok(None),
        }
    }

    pub fn bound_sockets(&self) -> Vec<String> {
        self.endpoint.bound_sockets().iter().map(ToString::to_string).collect()
    }

    pub async fn close(&self) {
        self.addr_task.abort();
        self.endpoint.close().await;
        self.stop_accepting();
    }

    fn stop_accepting(&self) {
        if let Some(task) = self.accept_task.lock().expect("accept task lock").take() {
            task.abort();
        }
    }
}

impl Drop for NetEndpoint {
    fn drop(&mut self) {
        self.addr_task.abort();
        self.stop_accepting();
    }
}

async fn drive_accepts(endpoint: Endpoint, sender: mpsc::UnboundedSender<Result<NetConnection>>) {
    let mut handshakes = JoinSet::new();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break };
                if handshakes.len() >= MAX_PENDING_HANDSHAKES {
                    incoming.refuse();
                    let refused = anyhow!("refused incoming connection: {MAX_PENDING_HANDSHAKES} handshakes pending");
                    if sender.send(Err(refused)).is_err() {
                        return;
                    }
                    continue;
                }
                handshakes.spawn(handshake(incoming));
            }
            Some(done) = handshakes.join_next(), if !handshakes.is_empty() => {
                if let Ok(result) = done && sender.send(result).is_err() {
                    return;
                }
            }
        }
    }
    while let Some(done) = handshakes.join_next().await {
        if let Ok(result) = done && sender.send(result).is_err() {
            return;
        }
    }
}

async fn handshake(incoming: Incoming) -> Result<NetConnection> {
    let connection = incoming.accept().context("refused incoming connection")?.await?;
    Ok(NetConnection::new(connection))
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
            .map(|path| {
                let stats = path.stats();
                PathInfo {
                    is_relay: path.is_relay(),
                    remote: transport_addr_string(path.remote_addr()),
                    selected: path.is_selected(),
                    rtt_ms: path.rtt().as_secs_f64() * 1000.0,
                    current_mtu: stats.current_mtu,
                    cwnd: stats.cwnd,
                    lost_packets: stats.lost_packets,
                    congestion_events: stats.congestion_events,
                    black_holes_detected: stats.black_holes_detected,
                    datagrams_sent: stats.frame_tx.datagram,
                }
            })
            .collect()
    }

    pub fn max_datagram_size(&self) -> Option<usize> {
        self.connection.max_datagram_size()
    }

    pub fn datagram_send_buffer_space(&self) -> usize {
        self.connection.datagram_send_buffer_space()
    }

    pub fn media(&self) -> Arc<DatagramRouter> {
        self.media
            .get_or_init(|| DatagramRouter::start(self.connection.clone()))
            .clone()
    }

    pub fn close(&self, code: u32, reason: &str) {
        self.connection.close(code.into(), reason.as_bytes());
    }

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

// Throwaway (851-3768 transport lab): media datagram tuning, picked by the
// CODEVISOR_NET_MEDIA_TUNING environment variable: `<cc>-<send buffer KiB>`.
fn media_lab_tuning(tuning: &str) -> Result<iroh::endpoint::QuicTransportConfig> {
    use noq_proto::congestion::{Bbr3Config, CubicConfig, NewRenoConfig};
    let (cc, buffer) = tuning.split_once('-').ok_or_else(|| anyhow!("bad tuning {tuning}"))?;
    let buffer: usize = buffer.parse::<usize>()? * 1024;
    let factory: Arc<dyn iroh::endpoint::ControllerFactory + Send + Sync> = match cc {
        "cubic" => Arc::new(CubicConfig::default()),
        "bbr3" => Arc::new(Bbr3Config::default()),
        "newreno" => Arc::new(NewRenoConfig::default()),
        other => return Err(anyhow!("unknown congestion controller {other}")),
    };
    Ok(iroh::endpoint::QuicTransportConfig::builder()
        .datagram_send_buffer_size(buffer)
        .congestion_controller_factory(factory)
        .build())
}
