//! Manual connectivity check for screen sharing connections (`codevisor/screen/1`): one machine listens, another
//! dials it over a chosen path, and both print the path they got and the transport the connection runs on.
//!
//! ```text
//! screen_connect listen [--bind ADDR] [--policy auto|direct-only|relay-only] [--relay URL [--relay-quic PORT]]
//! screen_connect dial --peer ID [--addr IP:PORT] [--relay URL] [--policy …] [--seconds 5]
//! ```
//!
//! Relays default to none. The production relays only admit registered devices, so a check of the relay path needs a
//! relay of its own, such as `iroh-relay --dev` (plain HTTP on port 3340). The dialer sends a
//! ping per 100 ms for `--seconds` over a stream and reports the selected path, its RTT, MTU and congestion window
//! (above `u32::MAX` means the screen transport's deferring controller is in charge).

use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, bail};
use codevisor_net::{
    ALPN_SCREEN, MessageKind, NetAddr, NetConfig, NetConnection, NetEndpoint, PathPolicy, RelaySpec,
    generate_secret_key,
};

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("listen") => listen(&args).await,
        Some("dial") => dial(&args).await,
        _ => bail!("usage: screen_connect listen [--bind ADDR] [--policy P] [--relay URL] | dial --peer ID …"),
    }
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|arg| arg == name).and_then(|index| args.get(index + 1)).map(String::as_str)
}

async fn bind(args: &[String]) -> Result<NetEndpoint> {
    let policy: PathPolicy = flag(args, "--policy").unwrap_or("auto").parse()?;
    let quic_port = flag(args, "--relay-quic").map(str::parse).transpose()?;
    let relays = flag(args, "--relay").map(|url| RelaySpec { url: url.into(), quic_port });
    let endpoint = NetEndpoint::bind(NetConfig {
        secret_key: generate_secret_key(),
        relays: relays.into_iter().collect(),
        trust_anchors_pem: vec![],
        bind_addrs: flag(args, "--bind").map(String::from).into_iter().collect(),
        path_policy: policy,
        alpns: vec![ALPN_SCREEN.to_vec()],
    })
    .await?;
    if flag(args, "--relay").is_some() && policy != PathPolicy::DirectOnly {
        endpoint.online(Duration::from_secs(20)).await?;
    }
    Ok(endpoint)
}

fn describe(connection: &NetConnection) -> String {
    let paths: Vec<String> = connection
        .paths()
        .iter()
        .map(|path| {
            format!(
                "{}{} {}: rtt {:.1} ms, mtu {}, cwnd {}",
                if path.selected { "* " } else { "  " },
                if path.is_relay { "relay" } else { "direct" },
                path.remote,
                path.rtt_ms,
                path.current_mtu,
                path.cwnd,
            )
        })
        .collect();
    format!(
        "max datagram {:?}, datagram send buffer {} B\n{}",
        connection.max_datagram_size(),
        connection.datagram_send_buffer_space(),
        paths.join("\n")
    )
}

async fn listen(args: &[String]) -> Result<()> {
    let endpoint = bind(args).await?;
    let addr = endpoint.addr();
    println!("listening as {}", endpoint.endpoint_id());
    println!("relay {:?}, direct {:?}", addr.relay_url, addr.direct_addrs);
    while let Some(connection) = endpoint.accept().await? {
        println!("\nconnection from {}", connection.remote_id());
        tokio::spawn(async move {
            let Ok(stream) = connection.accept_message_stream().await else { return };
            while let Ok(Some(message)) = stream.recv().await {
                if stream.send(message.kind, &message.payload).await.is_err() {
                    return;
                }
            }
            println!("{}", describe(&connection));
        });
    }
    Ok(())
}

async fn dial(args: &[String]) -> Result<()> {
    let endpoint = bind(args).await?;
    let peer = NetAddr {
        endpoint_id: flag(args, "--peer").ok_or_else(|| anyhow!("missing --peer"))?.into(),
        relay_url: flag(args, "--relay").map(String::from),
        direct_addrs: flag(args, "--addr").map(String::from).into_iter().collect(),
    };
    let started = Instant::now();
    let connection = endpoint.connect(&peer, ALPN_SCREEN).await?;
    println!("connected in {:.0} ms", started.elapsed().as_secs_f64() * 1000.0);
    let stream = connection.open_message_stream().await?;
    let seconds: f64 = flag(args, "--seconds").unwrap_or("5").parse()?;
    let mut pings = Vec::new();
    while started.elapsed().as_secs_f64() < seconds {
        let sent = Instant::now();
        stream.send(MessageKind::Binary, b"ping").await?;
        stream.recv().await?.ok_or_else(|| anyhow!("listener closed the stream"))?;
        pings.push(sent.elapsed().as_secs_f64() * 1000.0);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    pings.sort_by(f64::total_cmp);
    let median = pings.get(pings.len() / 2).copied().unwrap_or(f64::NAN);
    println!("{} pings, median round trip {median:.1} ms", pings.len());
    println!("{}", describe(&connection));
    stream.finish().await?;
    connection.close(0, "done");
    endpoint.close().await;
    Ok(())
}
