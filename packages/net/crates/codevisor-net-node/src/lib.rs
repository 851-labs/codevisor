//! Node (napi-rs) binding for the tunnel. Loaded by `@codevisor/net`; the
//! TypeScript server owns one endpoint per machine.

use std::{net::SocketAddr, sync::Arc, time::Duration};

use codevisor_net as net;
use napi::bindgen_prelude::{Buffer, Result};
use napi_derive::napi;

fn to_napi(error: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{error:#}"))
}

#[napi(object)]
pub struct RelayOptions {
    pub url: String,
    pub quic_port: Option<u32>,
}

#[napi(object)]
pub struct EndpointOptions {
    pub secret_key_hex: String,
    pub relays: Vec<RelayOptions>,
    pub trust_anchors_pem: Option<Vec<String>>,
    pub bind_addrs: Option<Vec<String>>,
    /// "auto" | "relay-only" | "direct-only"
    pub path_policy: Option<String>,
    pub alpns: Vec<String>,
}

#[napi(object)]
#[derive(Clone)]
pub struct TunnelAddr {
    pub endpoint_id: String,
    pub relay_url: Option<String>,
    pub direct_addrs: Vec<String>,
}

impl From<net::NetAddr> for TunnelAddr {
    fn from(addr: net::NetAddr) -> Self {
        Self { endpoint_id: addr.endpoint_id, relay_url: addr.relay_url, direct_addrs: addr.direct_addrs }
    }
}

impl From<TunnelAddr> for net::NetAddr {
    fn from(addr: TunnelAddr) -> Self {
        Self { endpoint_id: addr.endpoint_id, relay_url: addr.relay_url, direct_addrs: addr.direct_addrs }
    }
}

#[napi(object)]
pub struct TunnelPath {
    pub is_relay: bool,
    pub remote: String,
    pub selected: bool,
    pub rtt_ms: f64,
}

#[napi(object)]
pub struct TunnelMessage {
    /// 0 = text, 1 = binary.
    pub kind: u32,
    pub payload: Buffer,
}

#[napi]
pub fn generate_secret_key_hex() -> String {
    net::config::secret_key_hex(&net::generate_secret_key())
}

#[napi]
pub fn endpoint_id_for_secret_key(secret_key_hex: String) -> Result<String> {
    let key = net::secret_key_from_hex(&secret_key_hex).map_err(to_napi)?;
    Ok(net::endpoint_id_for(&key))
}

#[napi]
pub struct TunnelEndpoint {
    inner: Arc<net::NetEndpoint>,
}

#[napi]
impl TunnelEndpoint {
    #[napi(factory)]
    pub async fn bind(options: EndpointOptions) -> Result<TunnelEndpoint> {
        let config = net::NetConfig {
            secret_key: net::secret_key_from_hex(&options.secret_key_hex).map_err(to_napi)?,
            relays: options
                .relays
                .into_iter()
                .map(|relay| net::RelaySpec { url: relay.url, quic_port: relay.quic_port.map(|port| port as u16) })
                .collect(),
            trust_anchors_pem: options.trust_anchors_pem.unwrap_or_default(),
            bind_addrs: options.bind_addrs.unwrap_or_default(),
            path_policy: options.path_policy.as_deref().unwrap_or("auto").parse().map_err(to_napi)?,
            alpns: options.alpns.into_iter().map(String::into_bytes).collect(),
        };
        let inner = net::NetEndpoint::bind(config).await.map_err(to_napi)?;
        Ok(TunnelEndpoint { inner: Arc::new(inner) })
    }

    #[napi]
    pub fn endpoint_id(&self) -> String {
        self.inner.endpoint_id()
    }

    #[napi]
    pub fn addr(&self) -> TunnelAddr {
        self.inner.addr().into()
    }

    #[napi]
    pub fn bound_sockets(&self) -> Vec<String> {
        self.inner.bound_sockets()
    }

    /// First call: the current address. Later calls: the next change.
    #[napi]
    pub async fn next_addr(&self) -> Result<TunnelAddr> {
        let inner = self.inner.clone();
        inner.next_addr().await.map(Into::into).map_err(to_napi)
    }

    #[napi]
    pub async fn online(&self, timeout_ms: u32) -> Result<()> {
        let inner = self.inner.clone();
        inner.online(Duration::from_millis(timeout_ms.into())).await.map_err(to_napi)
    }

    #[napi]
    pub async fn connect(&self, addr: TunnelAddr, alpn: String) -> Result<TunnelConnection> {
        let inner = self.inner.clone();
        let connection = inner.connect(&addr.into(), alpn.as_bytes()).await.map_err(to_napi)?;
        Ok(TunnelConnection { inner: connection })
    }

    /// The next incoming connection; `null` once the endpoint is closed.
    /// A failed handshake rejects this call only — keep accepting.
    #[napi]
    pub async fn accept(&self) -> Result<Option<TunnelConnection>> {
        let inner = self.inner.clone();
        let connection = inner.accept().await.map_err(to_napi)?;
        Ok(connection.map(|inner| TunnelConnection { inner }))
    }

    #[napi]
    pub async fn close(&self) -> Result<()> {
        let inner = self.inner.clone();
        inner.close().await;
        Ok(())
    }
}

#[napi]
pub struct TunnelConnection {
    inner: net::NetConnection,
}

#[napi]
impl TunnelConnection {
    #[napi]
    pub fn remote_id(&self) -> String {
        self.inner.remote_id()
    }

    #[napi]
    pub fn alpn(&self) -> String {
        String::from_utf8_lossy(&self.inner.alpn()).into_owned()
    }

    #[napi]
    pub async fn open_message_stream(&self) -> Result<TunnelMessageStream> {
        let inner = self.inner.clone();
        let stream = inner.open_message_stream().await.map_err(to_napi)?;
        Ok(TunnelMessageStream { inner: Arc::new(stream) })
    }

    #[napi]
    pub async fn accept_message_stream(&self) -> Result<TunnelMessageStream> {
        let inner = self.inner.clone();
        let stream = inner.accept_message_stream().await.map_err(to_napi)?;
        Ok(TunnelMessageStream { inner: Arc::new(stream) })
    }

    #[napi]
    pub fn paths(&self) -> Vec<TunnelPath> {
        self.inner
            .paths()
            .into_iter()
            .map(|path| TunnelPath { is_relay: path.is_relay, remote: path.remote, selected: path.selected, rtt_ms: path.rtt_ms })
            .collect()
    }

    /// Largest UDP payload a media flow can carry, or `null`.
    #[napi]
    pub fn max_media_payload(&self) -> Option<u32> {
        self.inner.media().max_payload().map(|size| size as u32)
    }

    /// Host side: forward media flow `flowId` to a local UDP socket
    /// (`ip:port`, the host WebRTC's own candidate).
    #[napi]
    pub async fn forward_media(&self, flow_id: u32, target_addr: String) -> Result<TunnelMediaFlow> {
        let router = self.inner.media();
        let target: SocketAddr = target_addr
            .parse()
            .map_err(|_| napi::Error::from_reason(format!("invalid media target {target_addr}")))?;
        let flow = net::MediaFlow::forward(router, flow_id, target).await.map_err(to_napi)?;
        Ok(TunnelMediaFlow { inner: std::sync::Mutex::new(Some(flow)) })
    }

    /// Viewer side: a local UDP port (all interfaces) bridged to flow `flowId`.
    #[napi]
    pub async fn bind_media(&self, flow_id: u32) -> Result<TunnelMediaFlow> {
        let router = self.inner.media();
        let flow = net::MediaFlow::bind(router, flow_id).await.map_err(to_napi)?;
        Ok(TunnelMediaFlow { inner: std::sync::Mutex::new(Some(flow)) })
    }

    #[napi]
    pub fn close(&self, code: u32, reason: String) {
        self.inner.close(code, &reason);
    }

    #[napi]
    pub async fn closed(&self) -> String {
        let inner = self.inner.clone();
        inner.closed().await
    }
}

#[napi]
pub struct TunnelMessageStream {
    inner: Arc<net::MessageStream>,
}

#[napi]
impl TunnelMessageStream {
    #[napi]
    pub async fn send(&self, kind: u32, payload: Buffer) -> Result<()> {
        let inner = self.inner.clone();
        let kind = if kind == 0 { net::MessageKind::Text } else { net::MessageKind::Binary };
        inner.send(kind, &payload).await.map_err(to_napi)
    }

    /// The next message, or `null` when the peer finished the stream.
    #[napi]
    pub async fn recv(&self) -> Result<Option<TunnelMessage>> {
        let inner = self.inner.clone();
        let message = inner.recv().await.map_err(to_napi)?;
        Ok(message.map(|message| TunnelMessage { kind: message.kind as u32, payload: message.payload.into() }))
    }

    #[napi]
    pub async fn finish(&self) -> Result<()> {
        let inner = self.inner.clone();
        inner.finish().await.map_err(to_napi)
    }
}

#[napi]
pub struct TunnelMediaFlow {
    inner: std::sync::Mutex<Option<net::MediaFlow>>,
}

#[napi]
impl TunnelMediaFlow {
    #[napi]
    pub fn local_port(&self) -> u32 {
        self.inner.lock().unwrap().as_ref().map_or(0, |flow| flow.local_port().into())
    }

    #[napi]
    pub fn close(&self) {
        self.inner.lock().unwrap().take();
    }
}
