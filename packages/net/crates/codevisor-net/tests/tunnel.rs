//! End-to-end tunnel behavior against real iroh endpoints on loopback and an
//! in-process relay (trusted through `trust_anchors_pem`, the same mechanism
//! local development uses for its dev CA).

use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use base64::Engine;
use codevisor_net::{
    ALPN_CHANNELS, ALPN_MEDIA, CancelToken, MediaFlow, MessageKind, NetAddr, NetConfig, NetEndpoint, PathPolicy,
    RelaySpec, endpoint_id_for, generate_secret_key,
};
use iroh_relay::server::{AllowAll, CertConfig, QuicConfig, RelayConfig, Server, ServerConfig, TlsConfig};
use tokio::{net::UdpSocket, sync::oneshot};

const ONLINE: Duration = Duration::from_secs(20);

fn config(policy: PathPolicy, relays: Vec<RelaySpec>, anchors: Vec<String>) -> NetConfig {
    NetConfig {
        secret_key: generate_secret_key(),
        relays,
        trust_anchors_pem: anchors,
        bind_addrs: if policy == PathPolicy::RelayOnly { vec![] } else { vec!["127.0.0.1:0".into()] },
        path_policy: policy,
        alpns: vec![ALPN_CHANNELS.to_vec(), ALPN_MEDIA.to_vec()],
    }
}

struct TestRelay {
    _server: Server,
    spec: RelaySpec,
    anchor_pem: String,
}

async fn spawn_relay() -> TestRelay {
    let (certs, server_config) = iroh_relay::server::testing::self_signed_tls_certs_and_config();
    let mut relay = RelayConfig::new((Ipv4Addr::LOCALHOST, 0));
    relay.tls = Some(TlsConfig::new((Ipv4Addr::LOCALHOST, 0), CertConfig::Manual { server_config }));
    relay.access = Arc::new(AllowAll);
    let mut config = ServerConfig::default();
    config.relay = Some(relay);
    config.quic = Some(QuicConfig::new((Ipv4Addr::LOCALHOST, 0)));
    let server = Server::spawn(config).await.expect("relay spawns");
    let url = format!("https://localhost:{}", server.https_addr().unwrap().port());
    let quic_port = server.quic_addr().map(|addr| addr.port());
    let body = base64::engine::general_purpose::STANDARD.encode(certs[0].as_ref());
    let anchor_pem = format!("-----BEGIN CERTIFICATE-----\n{body}\n-----END CERTIFICATE-----\n");
    TestRelay { _server: server, spec: RelaySpec { url, quic_port }, anchor_pem }
}

/// Server side of the channels service: echo every message back.
fn spawn_echo(endpoint: Arc<NetEndpoint>) {
    tokio::spawn(async move {
        while let Ok(Some(connection)) = endpoint.accept().await {
            tokio::spawn(async move {
                let stream = connection.accept_message_stream().await.expect("stream");
                while let Ok(Some(message)) = stream.recv().await {
                    stream.send(message.kind, &message.payload).await.expect("echo");
                }
            });
        }
    });
}

async fn round_trip(client: &NetEndpoint, server_addr: &NetAddr) -> codevisor_net::NetConnection {
    let connection = client.connect(server_addr, ALPN_CHANNELS).await.expect("connects");
    let stream = connection.open_message_stream().await.expect("opens");
    stream.send(MessageKind::Text, br#"{"t":"hello"}"#).await.unwrap();
    let big = vec![7u8; 1_500_000];
    stream.send(MessageKind::Binary, &big).await.unwrap();
    let text = stream.recv().await.unwrap().expect("text echo");
    assert_eq!(text.kind, MessageKind::Text);
    assert_eq!(text.payload, br#"{"t":"hello"}"#);
    let binary = stream.recv().await.unwrap().expect("binary echo");
    assert_eq!(binary.kind, MessageKind::Binary);
    assert_eq!(binary.payload, big);
    connection
}

#[tokio::test]
async fn messages_cross_a_direct_path() {
    let server = Arc::new(NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap());
    let client = NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap();
    spawn_echo(server.clone());
    let addr = server.addr();
    assert!(!addr.direct_addrs.is_empty(), "loopback-bound endpoint advertises its address");
    let connection = round_trip(&client, &addr).await;
    assert_eq!(connection.remote_id(), server.endpoint_id());
    assert!(connection.paths().iter().all(|path| !path.is_relay));
}

#[tokio::test]
async fn messages_cross_a_relay_trusted_by_extra_anchor() {
    let relay = spawn_relay().await;
    let relays = vec![relay.spec.clone()];
    let anchors = vec![relay.anchor_pem.clone()];
    let server = Arc::new(
        NetEndpoint::bind(config(PathPolicy::RelayOnly, relays.clone(), anchors.clone())).await.unwrap(),
    );
    let client = NetEndpoint::bind(config(PathPolicy::RelayOnly, relays, anchors)).await.unwrap();
    server.online(ONLINE).await.expect("server homes on the relay");
    client.online(ONLINE).await.expect("client homes on the relay");
    spawn_echo(server.clone());
    let addr = NetAddr {
        endpoint_id: server.endpoint_id(),
        relay_url: server.addr().relay_url,
        direct_addrs: vec![],
    };
    assert!(addr.relay_url.is_some(), "server advertises its home relay");
    let connection = round_trip(&client, &addr).await;
    let paths = connection.paths();
    assert!(!paths.is_empty() && paths.iter().all(|path| path.is_relay));
}

#[tokio::test]
async fn media_flow_bridges_loopback_udp_both_ways() {
    let host = Arc::new(NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap());
    let viewer = NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap();

    // The "native WebRTC host": a UDP socket that answers every packet.
    let target = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let target_addr = target.local_addr().unwrap();
    tokio::spawn(async move {
        let mut buffer = [0u8; 2048];
        while let Ok((len, from)) = target.recv_from(&mut buffer).await {
            let mut reply = b"ack:".to_vec();
            reply.extend_from_slice(&buffer[..len]);
            target.send_to(&reply, from).await.unwrap();
        }
    });

    let (flow_tx, flow_rx) = tokio::sync::oneshot::channel();
    let host_side = host.clone();
    tokio::spawn(async move {
        let connection = host_side.accept().await.unwrap().unwrap();
        let flow = MediaFlow::forward(connection.media(), 7, target_addr).await.unwrap();
        flow_tx.send((connection, flow)).ok();
    });
    let connection = viewer.connect(&host.addr(), ALPN_MEDIA).await.unwrap();
    let viewer_flow = MediaFlow::bind(connection.media(), 7).await.unwrap();
    let _host_side = flow_rx.await.unwrap();
    assert!(connection.media().max_payload().unwrap() >= 1100);

    // The "WebRTC viewer" only ever talks to its loopback port.
    let app = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let mut buffer = [0u8; 2048];
    // Both flows are registered before the first packet (the host side is
    // awaited above), so on loopback nothing is dropped.
    app.send_to(b"rtp-1", (Ipv4Addr::LOCALHOST, viewer_flow.local_port())).await.unwrap();
    let (len, _) = app.recv_from(&mut buffer).await.unwrap();
    assert_eq!(&buffer[..len], b"ack:rtp-1");
}

/// A UDP hop that forwards whatever a dialer sends to `target` and drops
/// every reply, so `target` sees a dial whose handshake never completes.
/// Resolves `forwarded` once the first datagram has been passed on.
async fn spawn_reply_dropping_hop(target: SocketAddr) -> (SocketAddr, oneshot::Receiver<()>) {
    let hop = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let addr = hop.local_addr().unwrap();
    let (forwarded_tx, forwarded_rx) = oneshot::channel();
    tokio::spawn(async move {
        let mut forwarded = Some(forwarded_tx);
        let mut buffer = vec![0u8; 65_536];
        while let Ok((len, from)) = hop.recv_from(&mut buffer).await {
            if from == target {
                continue;
            }
            hop.send_to(&buffer[..len], target).await.unwrap();
            if let Some(forwarded) = forwarded.take() {
                forwarded.send(()).ok();
            }
        }
    });
    (addr, forwarded_rx)
}

#[tokio::test]
async fn a_stalled_handshake_does_not_hold_up_later_dials() {
    let server = Arc::new(NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap());
    let stalled_client = NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap();
    let client = NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap();
    let target: SocketAddr = server.addr().direct_addrs[0].parse().unwrap();
    let (hop, forwarded) = spawn_reply_dropping_hop(target).await;

    // The machine is accepting before anyone dials.
    let accepting = tokio::spawn({
        let server = server.clone();
        async move { server.accept().await }
    });
    // First in line: a dialer that never hears back (an app suspended
    // mid-dial). Its handshake can only end by timing out.
    let stalled_addr = NetAddr { endpoint_id: server.endpoint_id(), relay_url: None, direct_addrs: vec![hop.to_string()] };
    let stalled = tokio::spawn(async move { stalled_client.connect(&stalled_addr, ALPN_CHANNELS).await.is_ok() });
    forwarded.await.unwrap();

    // A dialer behind it still gets in, and is the first connection out.
    client.connect(&server.addr(), ALPN_CHANNELS).await.expect("dials past the stalled handshake");
    let accepted = accepting.await.unwrap().expect("handshake succeeds").expect("endpoint open");
    assert_eq!(accepted.remote_id(), client.endpoint_id());
    stalled.abort();
}

#[tokio::test]
async fn cancelling_a_dial_ends_it() {
    let client = NetEndpoint::bind(config(PathPolicy::DirectOnly, vec![], vec![])).await.unwrap();
    // A peer address where nothing ever answers.
    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let addr = NetAddr {
        endpoint_id: endpoint_id_for(&generate_secret_key()),
        relay_url: None,
        direct_addrs: vec![silent.local_addr().unwrap().to_string()],
    };
    let cancel = Arc::new(CancelToken::default());
    let dial = tokio::spawn({
        let cancel = cancel.clone();
        async move { client.connect_cancellable(&addr, ALPN_CHANNELS, &cancel).await.map(|_| ()) }
    });
    // The dial is under way once its first packet arrives.
    let mut buffer = [0u8; 2048];
    silent.recv_from(&mut buffer).await.unwrap();

    cancel.cancel();
    let error = dial.await.unwrap().expect_err("a cancelled dial fails");
    assert!(error.to_string().contains("cancelled"), "{error:#}");
}
