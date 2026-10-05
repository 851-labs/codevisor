//! Swift (uniffi) binding for the tunnel, used by the macOS and iOS apps
//! (packages/swift/CodevisorNet). Mirrors the Node binding's surface.

use std::{sync::Arc, time::Duration};

use codevisor_net as net;

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum NetError {
    Failure(String),
}

impl std::fmt::Display for NetError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NetError::Failure(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for NetError {}

fn failure(error: anyhow::Error) -> NetError {
    NetError::Failure(format!("{error:#}"))
}

#[derive(uniffi::Record)]
pub struct NetRelay {
    pub url: String,
    pub quic_port: Option<u16>,
}

#[derive(uniffi::Record)]
pub struct NetEndpointConfig {
    pub secret_key_hex: String,
    pub relays: Vec<NetRelay>,
    pub trust_anchors_pem: Vec<String>,
    /// "auto" | "relay-only" | "direct-only"
    pub path_policy: String,
    pub alpns: Vec<String>,
}

#[derive(uniffi::Record, Clone)]
pub struct NetTunnelAddr {
    pub endpoint_id: String,
    pub relay_url: Option<String>,
    pub direct_addrs: Vec<String>,
}

impl From<net::NetAddr> for NetTunnelAddr {
    fn from(addr: net::NetAddr) -> Self {
        Self { endpoint_id: addr.endpoint_id, relay_url: addr.relay_url, direct_addrs: addr.direct_addrs }
    }
}

impl From<NetTunnelAddr> for net::NetAddr {
    fn from(addr: NetTunnelAddr) -> Self {
        Self { endpoint_id: addr.endpoint_id, relay_url: addr.relay_url, direct_addrs: addr.direct_addrs }
    }
}

#[derive(uniffi::Record)]
pub struct NetPath {
    pub is_relay: bool,
    pub remote: String,
    pub selected: bool,
    pub rtt_ms: f64,
}

#[derive(uniffi::Record)]
pub struct NetMessage {
    /// 0 = text, 1 = binary.
    pub kind: u8,
    pub payload: Vec<u8>,
}

#[uniffi::export]
pub fn net_generate_secret_key_hex() -> String {
    net::config::secret_key_hex(&net::generate_secret_key())
}

#[uniffi::export]
pub fn net_endpoint_id_for_secret_key(secret_key_hex: String) -> Result<String, NetError> {
    let key = net::secret_key_from_hex(&secret_key_hex).map_err(failure)?;
    Ok(net::endpoint_id_for(&key))
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn net_bind_endpoint(config: NetEndpointConfig) -> Result<Arc<NetEndpointHandle>, NetError> {
    let config = net::NetConfig {
        secret_key: net::secret_key_from_hex(&config.secret_key_hex).map_err(failure)?,
        relays: config
            .relays
            .into_iter()
            .map(|relay| net::RelaySpec { url: relay.url, quic_port: relay.quic_port })
            .collect(),
        trust_anchors_pem: config.trust_anchors_pem,
        bind_addrs: vec![],
        path_policy: config.path_policy.parse().map_err(failure)?,
        alpns: config.alpns.into_iter().map(String::into_bytes).collect(),
    };
    let endpoint = net::NetEndpoint::bind(config).await.map_err(failure)?;
    Ok(Arc::new(NetEndpointHandle { inner: Arc::new(endpoint) }))
}

#[derive(uniffi::Object)]
pub struct NetEndpointHandle {
    inner: Arc<net::NetEndpoint>,
}

#[uniffi::export(async_runtime = "tokio")]
impl NetEndpointHandle {
    pub fn endpoint_id(&self) -> String {
        self.inner.endpoint_id()
    }

    pub fn addr(&self) -> NetTunnelAddr {
        self.inner.addr().into()
    }

    pub async fn online(&self, timeout_ms: u32) -> Result<(), NetError> {
        self.inner.online(Duration::from_millis(timeout_ms.into())).await.map_err(failure)
    }

    /// Dials `addr`. Swift's async glue never cancels the Rust future, so a
    /// caller that may abandon the dial passes `cancel` and fires it; the
    /// handshake then stops at once instead of running to its timeout.
    pub async fn connect(
        &self,
        addr: NetTunnelAddr,
        alpn: String,
        cancel: Option<Arc<NetCancelToken>>,
    ) -> Result<Arc<NetConnectionHandle>, NetError> {
        let addr = addr.into();
        let connection = match cancel {
            Some(cancel) => self.inner.connect_cancellable(&addr, alpn.as_bytes(), &cancel.inner).await,
            None => self.inner.connect(&addr, alpn.as_bytes()).await,
        }
        .map_err(failure)?;
        Ok(Arc::new(NetConnectionHandle { inner: connection }))
    }

    /// Hints that the network may have changed (foreground, path change).
    pub async fn network_change(&self) {
        self.inner.network_change().await;
    }

    pub async fn close(&self) {
        self.inner.close().await;
    }
}

/// Cancels a `connect` from Swift (see `NetEndpointHandle::connect`).
#[derive(uniffi::Object, Default)]
pub struct NetCancelToken {
    inner: net::CancelToken,
}

#[uniffi::export]
impl NetCancelToken {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn cancel(&self) {
        self.inner.cancel();
    }
}

#[derive(uniffi::Object)]
pub struct NetConnectionHandle {
    inner: net::NetConnection,
}

#[uniffi::export(async_runtime = "tokio")]
impl NetConnectionHandle {
    pub fn remote_id(&self) -> String {
        self.inner.remote_id()
    }

    pub async fn open_message_stream(&self) -> Result<Arc<NetMessageStreamHandle>, NetError> {
        let stream = self.inner.open_message_stream().await.map_err(failure)?;
        Ok(Arc::new(NetMessageStreamHandle { inner: Arc::new(stream) }))
    }

    pub fn paths(&self) -> Vec<NetPath> {
        self.inner
            .paths()
            .into_iter()
            .map(|path| NetPath { is_relay: path.is_relay, remote: path.remote, selected: path.selected, rtt_ms: path.rtt_ms })
            .collect()
    }

    /// Largest UDP payload a media flow can carry, or `None`.
    pub fn max_media_payload(&self) -> Option<u32> {
        self.inner.media().max_payload().map(|size| size as u32)
    }

    /// Viewer side: a local UDP port (all interfaces) bridged to flow `flow_id`.
    pub async fn bind_media(&self, flow_id: u32) -> Result<Arc<NetMediaFlowHandle>, NetError> {
        let flow = net::MediaFlow::bind(self.inner.media(), flow_id).await.map_err(failure)?;
        Ok(Arc::new(NetMediaFlowHandle { inner: std::sync::Mutex::new(Some(flow)) }))
    }

    pub fn close(&self, code: u32, reason: String) {
        self.inner.close(code, &reason);
    }
}

#[derive(uniffi::Object)]
pub struct NetMessageStreamHandle {
    inner: Arc<net::MessageStream>,
}

#[uniffi::export(async_runtime = "tokio")]
impl NetMessageStreamHandle {
    pub async fn send(&self, kind: u8, payload: Vec<u8>) -> Result<(), NetError> {
        let kind = if kind == 0 { net::MessageKind::Text } else { net::MessageKind::Binary };
        self.inner.send(kind, &payload).await.map_err(failure)
    }

    /// The next message, or `None` once the peer finished the stream.
    pub async fn recv(&self) -> Result<Option<NetMessage>, NetError> {
        let message = self.inner.recv().await.map_err(failure)?;
        Ok(message.map(|message| NetMessage { kind: message.kind as u8, payload: message.payload }))
    }

    pub async fn finish(&self) -> Result<(), NetError> {
        self.inner.finish().await.map_err(failure)
    }
}

#[derive(uniffi::Object)]
pub struct NetMediaFlowHandle {
    inner: std::sync::Mutex<Option<net::MediaFlow>>,
}

#[uniffi::export]
impl NetMediaFlowHandle {
    pub fn local_port(&self) -> u16 {
        self.inner.lock().unwrap().as_ref().map_or(0, net::MediaFlow::local_port)
    }

    pub fn close(&self) {
        self.inner.lock().unwrap().take();
    }
}
