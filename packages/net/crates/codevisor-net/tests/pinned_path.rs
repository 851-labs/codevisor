use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use codevisor_net::{
    ALPN_CHANNELS, MessageKind, NetAddr, NetConfig, NetConnection, NetEndpoint, PathPolicy, generate_secret_key,
};
use tokio::{net::UdpSocket, sync::Mutex};

const HOP_DELAY: Duration = Duration::from_millis(30);
const ECHOES: usize = 5;

fn config(policy: PathPolicy) -> NetConfig {
    NetConfig {
        secret_key: generate_secret_key(),
        relays: vec![],
        trust_anchors_pem: vec![],
        bind_addrs: vec!["127.0.0.1:0".into()],
        path_policy: policy,
        alpns: vec![ALPN_CHANNELS.to_vec()],
    }
}

async fn spawn_delaying_hop(target: SocketAddr) -> SocketAddr {
    let hop = Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap());
    let addr = hop.local_addr().unwrap();
    let client = Arc::new(Mutex::new(None::<SocketAddr>));
    tokio::spawn(async move {
        let mut buffer = vec![0u8; 65_536];
        while let Ok((len, from)) = hop.recv_from(&mut buffer).await {
            let destination = if from == target {
                *client.lock().await
            } else {
                *client.lock().await = Some(from);
                Some(target)
            };
            let Some(destination) = destination else { continue };
            let datagram = buffer[..len].to_vec();
            let hop = hop.clone();
            tokio::spawn(async move {
                tokio::time::sleep(HOP_DELAY).await;
                hop.send_to(&datagram, destination).await.ok();
            });
        }
    });
    addr
}

fn spawn_echo(host: Arc<NetEndpoint>) {
    tokio::spawn(async move {
        let connection = host.accept().await.unwrap().unwrap();
        let stream = connection.accept_message_stream().await.unwrap();
        while let Ok(Some(message)) = stream.recv().await {
            stream.send(message.kind, &message.payload).await.unwrap();
        }
    });
}

async fn echo(connection: &NetConnection, times: usize) {
    let stream = connection.open_message_stream().await.unwrap();
    for _ in 0..times {
        stream.send(MessageKind::Text, b"ping").await.unwrap();
        assert_eq!(stream.recv().await.unwrap().expect("echo").payload, b"ping");
    }
}

#[tokio::test]
async fn a_pinned_connection_stays_on_the_slow_path_it_dialed() {
    let host = Arc::new(NetEndpoint::bind(config(PathPolicy::DirectPinned)).await.unwrap());
    let viewer = NetEndpoint::bind(config(PathPolicy::DirectPinned)).await.unwrap();
    let hop = spawn_delaying_hop(host.addr().direct_addrs[0].parse().unwrap()).await;
    spawn_echo(host.clone());

    let target = NetAddr { endpoint_id: host.endpoint_id(), relay_url: None, direct_addrs: vec![hop.to_string()] };
    let connection = viewer.connect(&target, ALPN_CHANNELS).await.unwrap();
    echo(&connection, ECHOES).await;

    let selected: Vec<_> =
        connection.paths().into_iter().filter(|path| path.selected).map(|path| path.remote).collect();
    assert_eq!(selected, vec![hop.to_string()]);
}
