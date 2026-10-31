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

    pub async fn accept(&self) -> Result<Option<Arc<NetConnectionHandle>>, NetError> {
        let connection = self.inner.accept().await.map_err(failure)?;
        Ok(connection.map(|inner| Arc::new(NetConnectionHandle { inner })))
    }

    pub async fn network_change(&self) {
        self.inner.network_change().await;
    }

    pub async fn close(&self) {
        self.inner.close().await;
    }
}

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

    pub fn max_media_payload(&self) -> Option<u32> {
        self.inner.media().max_payload().map(|size| size as u32)
    }

    pub async fn open_media_session(&self, config: MediaSessionConfig) -> Arc<MediaSessionHandle> {
        let session = media::MediaSession::new(media::QuicTransport::new(self.inner.clone()), config.into());
        Arc::new(MediaSessionHandle { inner: session })
    }

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

use codevisor_media as media;

#[uniffi::export(async_runtime = "tokio")]
pub async fn media_bench_run(args: Vec<String>) -> Result<String, NetError> {
    media::bench::run(args).await.map_err(failure)
}

#[uniffi::export]
pub fn media_alpn() -> String {
    String::from_utf8_lossy(media::ALPN_SCREEN).into_owned()
}

#[derive(uniffi::Record)]
pub struct MediaSessionConfig {
    pub frame_interval_us: u32,
    pub fec_percent: Option<u8>,
    pub initial_rate_kbps: u32,
}

impl From<MediaSessionConfig> for media::MediaConfig {
    fn from(config: MediaSessionConfig) -> Self {
        Self {
            frame_interval: Duration::from_micros(config.frame_interval_us.max(1).into()),
            fec: match config.fec_percent {
                None => media::FecMode::Adaptive,
                Some(0) => media::FecMode::Off,
                Some(percent) => media::FecMode::Fixed(f64::from(percent) / 100.0),
            },
            initial_rate_bps: f64::from(config.initial_rate_kbps) * 1000.0,
            ..media::MediaConfig::default()
        }
    }
}

#[derive(uniffi::Object)]
pub struct MediaBytes {
    bytes: bytes::Bytes,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaRecovery {
    None,
    Fec,
    Nack,
}

impl From<media::Recovery> for MediaRecovery {
    fn from(recovery: media::Recovery) -> Self {
        match recovery {
            media::Recovery::None => Self::None,
            media::Recovery::Fec => Self::Fec,
            media::Recovery::Nack => Self::Nack,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum MediaEvent {
    Frame {
        stream: u8,
        frame: u32,
        keyframe: bool,
        ltr_token: Option<u64>,
        meta: Vec<u8>,
        data: Arc<MediaBytes>,
        assembling_us: u64,
        recovery: MediaRecovery,
    },
    FrameSkipped { stream: u8, frame: u32 },
    FrameAcked {
        stream: u8,
        frame: u32,
        queued_us: u64,
        sending_us: u64,
        acked_after_us: u64,
        assembling_us: Option<u64>,
    },
    FrameLost { stream: u8, frame: u32 },
    LtrAcked { stream: u8, token: u64 },
}

fn micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

impl From<media::Event> for MediaEvent {
    fn from(event: media::Event) -> Self {
        match event {
            media::Event::Frame(frame) => Self::Frame {
                stream: frame.stream,
                frame: frame.frame,
                keyframe: frame.keyframe,
                ltr_token: frame.ltr_token,
                meta: frame.meta,
                data: Arc::new(MediaBytes { bytes: frame.data }),
                assembling_us: micros(frame.completed_at - frame.first_packet_at),
                recovery: frame.recovery.into(),
            },
            media::Event::FrameSkipped { stream, frame } => Self::FrameSkipped { stream, frame },
            media::Event::FrameAcked(ack) => Self::FrameAcked {
                stream: ack.stream,
                frame: ack.frame,
                queued_us: micros(ack.queued),
                sending_us: micros(ack.sending),
                acked_after_us: micros(ack.acked_after),
                assembling_us: ack.receipt.map(|receipt| micros(receipt.assembling)),
            },
            media::Event::FrameLost { stream, frame } => Self::FrameLost { stream, frame },
            media::Event::LtrAcked { stream, token } => Self::LtrAcked { stream, token },
        }
    }
}

#[derive(uniffi::Record)]
pub struct MediaAdmission {
    pub admit: bool,
    pub backlog_bytes: u64,
    pub budget_bytes: u64,
    pub estimate_kbps: u64,
    pub encoder_ceiling_kbps: u64,
}

#[derive(uniffi::Record)]
pub struct MediaSessionStats {
    pub frames_sent: u64,
    pub frames_acked: u64,
    pub frames_lost: u64,
    pub packets_sent: u64,
    pub bytes_sent: u64,
    pub parity_packets_sent: u64,
    pub packets_retransmitted: u64,
    pub probes_sent: u64,
    pub frames_received: u64,
    pub frames_skipped: u64,
    pub packets_received: u64,
    pub bytes_received: u64,
    pub fec_recoveries: u64,
    pub nacks_sent: u64,
    pub rtt_us: u64,
    pub estimate_kbps: u64,
    pub queue_delay_us: i64,
    pub fec_percent: f64,
    pub loss_percent: f64,
}

#[derive(uniffi::Object)]
pub struct MediaSessionHandle {
    inner: media::MediaSession,
}

#[uniffi::export(async_runtime = "tokio")]
impl MediaSessionHandle {
    pub fn ack_ltr(&self, stream: u8, token: u64) {
        self.inner.ack_ltr(stream, token);
    }

    pub fn admission(&self) -> MediaAdmission {
        let admission = self.inner.admission();
        MediaAdmission {
            admit: admission.admit,
            backlog_bytes: admission.backlog_bytes as u64,
            budget_bytes: admission.budget_bytes as u64,
            estimate_kbps: (admission.estimate_bps / 1000.0) as u64,
            encoder_ceiling_kbps: (admission.encoder_ceiling_bps / 1000.0) as u64,
        }
    }

    pub fn stats(&self) -> MediaSessionStats {
        let stats = self.inner.stats();
        MediaSessionStats {
            frames_sent: stats.frames_sent,
            frames_acked: stats.frames_acked,
            frames_lost: stats.frames_lost,
            packets_sent: stats.packets_sent,
            bytes_sent: stats.bytes_sent,
            parity_packets_sent: stats.parity_packets_sent,
            packets_retransmitted: stats.packets_retransmitted,
            probes_sent: stats.probes_sent,
            frames_received: stats.frames_received,
            frames_skipped: stats.frames_skipped,
            packets_received: stats.packets_received,
            bytes_received: stats.bytes_received,
            fec_recoveries: stats.fec_recoveries,
            nacks_sent: stats.nacks_sent,
            rtt_us: micros(stats.rtt),
            estimate_kbps: (stats.estimate_bps / 1000.0) as u64,
            queue_delay_us: stats.queue_delay_us,
            fec_percent: stats.fec_ratio * 100.0,
            loss_percent: stats.loss_rate * 100.0,
        }
    }

    pub async fn next_event(&self) -> Option<MediaEvent> {
        self.inner.next_event().await.map(Into::into)
    }

    pub fn close(&self) {
        self.inner.close();
    }
}

fn borrowed<'a>(pointer: *const std::ffi::c_void, len: usize) -> &'a [u8] {
    if len == 0 || pointer.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(pointer.cast(), len) }
    }
}

const SEND_PANICKED: i64 = -5;

#[unsafe(no_mangle)]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn codevisor_media_send_frame(
    session: u64,
    stream: u8,
    keyframe: bool,
    has_ltr_token: bool,
    ltr_token: u64,
    meta: *const std::ffi::c_void,
    meta_len: usize,
    data: *const std::ffi::c_void,
    data_len: usize,
) -> i64 {
    let session = unsafe { Arc::from_raw(session as *const MediaSessionHandle) };
    let frame = media::OutgoingFrame {
        stream,
        keyframe,
        ltr_token: has_ltr_token.then_some(ltr_token),
        meta: borrowed(meta, meta_len),
        data: borrowed(data, data_len),
    };
    let sent = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| session.inner.send_frame(frame)));
    match sent {
        Ok(Ok(number)) => i64::from(number),
        Ok(Err(media::SendError::NoDatagrams)) => -1,
        Ok(Err(media::SendError::PathTooSmall)) => -2,
        Ok(Err(media::SendError::MetaTooLarge)) => -3,
        Ok(Err(media::SendError::FrameTooLarge)) => -4,
        Err(_) => SEND_PANICKED,
    }
}

#[unsafe(no_mangle)]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn codevisor_media_bytes(bytes: u64, len: *mut usize) -> *const std::ffi::c_void {
    let bytes = unsafe { Arc::from_raw(bytes as *const MediaBytes) };
    unsafe { *len = bytes.bytes.len() };
    bytes.bytes.as_ptr().cast()
}
