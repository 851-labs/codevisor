use codevisor_net::{
    ALPN_CHANNELS, ALPN_SCREEN, NetConfig, NetConnection, NetEndpoint, PathPolicy, generate_secret_key,
    screen_transport::DATAGRAM_SEND_BUFFER,
};

fn config() -> NetConfig {
    NetConfig {
        secret_key: generate_secret_key(),
        relays: vec![],
        trust_anchors_pem: vec![],
        bind_addrs: vec!["127.0.0.1:0".into()],
        path_policy: PathPolicy::DirectOnly,
        alpns: vec![ALPN_CHANNELS.to_vec(), ALPN_SCREEN.to_vec()],
    }
}

fn congestion_window(connection: &NetConnection) -> u64 {
    connection.paths().iter().find(|path| path.selected).expect("a selected path").cwnd
}

async fn dial(viewer: &NetEndpoint, host: &NetEndpoint, alpn: &[u8]) -> (NetConnection, NetConnection) {
    let addr = host.addr();
    let (dialed, accepted) = tokio::join!(viewer.connect(&addr, alpn), host.accept());
    (dialed.unwrap(), accepted.unwrap().unwrap())
}

#[tokio::test]
async fn screen_connections_are_tuned_on_both_ends_and_other_alpns_keep_the_defaults() {
    let host = NetEndpoint::bind(config()).await.unwrap();
    let viewer = NetEndpoint::bind(config()).await.unwrap();

    let (dialed_screen, accepted_screen) = dial(&viewer, &host, ALPN_SCREEN).await;
    let (dialed_channels, accepted_channels) = dial(&viewer, &host, ALPN_CHANNELS).await;
    assert_eq!(accepted_screen.alpn(), ALPN_SCREEN);
    assert_eq!(accepted_channels.alpn(), ALPN_CHANNELS);

    for screen in [&dialed_screen, &accepted_screen] {
        assert!(congestion_window(screen) > u64::from(u32::MAX), "no window and no QUIC pacing");
        assert_eq!(screen.datagram_send_buffer_space(), DATAGRAM_SEND_BUFFER);
    }
    for channels in [&dialed_channels, &accepted_channels] {
        assert!(congestion_window(channels) < u64::from(u32::MAX));
        assert_eq!(channels.datagram_send_buffer_space(), 1024 * 1024);
    }
}
