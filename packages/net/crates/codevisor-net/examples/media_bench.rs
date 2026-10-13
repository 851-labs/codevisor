//! A two-machine probe of the tunnel's media path (docs/plans/codevisor-tunnel.md,
//! Phase 4): the loopback UDP → QUIC datagram → loopback UDP route screen
//! sharing uses, measured side by side with plain UDP over the same network.
//!
//! ```text
//! host$   media_bench serve --bind 0.0.0.0:47100 --udp-echo 0.0.0.0:47101
//! viewer$ media_bench run --peer <endpoint id> --addr <host ip>:47100 --udp <host ip>:47101
//! ```
//!
//! The host echoes every packet, through its end of the tunnel flow and on the
//! plain UDP port, so each row is a round trip that crosses both directions.
//! After each tunnel row, both ends report their tunnel counters.

use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Result, anyhow, bail};
use codevisor_net::{
    ALPN_MEDIA, MediaFlow, MessageKind, MessageStream, NetAddr, NetConfig, NetConnection, NetEndpoint, PathPolicy,
    generate_secret_key,
};
use tokio::net::UdpSocket;

const FLOW: u32 = 1;
/// `[test id: u32][sequence: u32][send time: u64 ns]`, then padding.
const HEADER: usize = 16;
/// How long a row waits for its last echoes.
const DRAIN: Duration = Duration::from_millis(1500);
const SWEEP_SIZES: [usize; 15] = [1000, 1100, 1150, 1160, 1170, 1180, 1190, 1200, 1210, 1220, 1240, 1260, 1300, 1400, 1472];

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(flag(&args, "--bind")?, flag(&args, "--udp-echo")?).await,
        Some("run") => run(flag(&args, "--peer")?, flag(&args, "--addr")?, flag(&args, "--udp")?).await,
        _ => bail!("usage: media_bench serve --bind ADDR --udp-echo ADDR | run --peer ID --addr ADDR --udp ADDR"),
    }
}

fn flag(args: &[String], name: &str) -> Result<String> {
    args.iter()
        .position(|arg| arg == name)
        .and_then(|index| args.get(index + 1))
        .cloned()
        .ok_or_else(|| anyhow!("missing {name}"))
}

fn endpoint_config(bind: String) -> NetConfig {
    NetConfig {
        secret_key: generate_secret_key(),
        relays: vec![],
        trust_anchors_pem: vec![],
        bind_addrs: vec![bind],
        path_policy: PathPolicy::DirectOnly,
        alpns: vec![ALPN_MEDIA.to_vec()],
    }
}

/// Answers every packet with itself.
async fn spawn_echo(bind: &str) -> Result<SocketAddr> {
    let socket = UdpSocket::bind(bind).await?;
    let addr = socket.local_addr()?;
    tokio::spawn(async move {
        let mut buffer = vec![0u8; 65_536];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            let _ = socket.send_to(&buffer[..len], from).await;
        }
    });
    Ok(addr)
}

async fn serve(bind: String, udp_echo: String) -> Result<()> {
    let endpoint = NetEndpoint::bind(endpoint_config(bind)).await?;
    let flow_echo = spawn_echo("127.0.0.1:0").await?;
    let udp = spawn_echo(&udp_echo).await?;
    println!("endpoint {} on {:?}, udp echo on {udp}", endpoint.endpoint_id(), endpoint.bound_sockets());
    loop {
        let connection = match endpoint.accept().await {
            Ok(Some(connection)) => connection,
            Ok(None) => return Ok(()),
            Err(error) => {
                eprintln!("accept: {error:#}");
                continue;
            }
        };
        println!("connection from {}", connection.remote_id());
        tokio::spawn(async move {
            if let Err(error) = host_connection(connection, flow_echo).await {
                eprintln!("connection: {error:#}");
            }
        });
    }
}

/// Forwards the flow to the echo, then answers each report request with this
/// end's counters (its sends carry the echoes back to the viewer).
async fn host_connection(connection: NetConnection, echo: SocketAddr) -> Result<()> {
    let _flow = MediaFlow::forward(connection.media(), FLOW, echo).await?;
    let control = connection.accept_message_stream().await?;
    while control.recv().await?.is_some() {
        control.send(MessageKind::Text, report(&connection).as_bytes()).await?;
    }
    Ok(())
}

fn report(connection: &NetConnection) -> String {
    let media = connection.media();
    let stats = media.stats();
    let paths: Vec<String> = connection
        .paths()
        .iter()
        .filter(|path| path.selected)
        .map(|path| {
            format!(
                "{}{} mtu {} cwnd {} rtt {:.1} ms, lost {} congestion events {} black holes {}, datagrams on wire {}",
                if path.is_relay { "relay " } else { "" },
                path.remote,
                path.current_mtu,
                path.cwnd,
                path.rtt_ms,
                path.lost_packets,
                path.congestion_events,
                path.black_holes_detected,
                path.datagrams_sent,
            )
        })
        .collect();
    format!(
        "max payload {:?}, send buffer free {} | sent {} too large {} (largest {}) failed {} | received {} queue full {} unknown flow {} | {}",
        media.max_payload(),
        connection.datagram_send_buffer_space(),
        stats.sent,
        stats.too_large,
        stats.largest_too_large,
        stats.send_failed,
        stats.received,
        stats.queue_full,
        stats.unknown_flow,
        paths.join("; "),
    )
}

struct Probe {
    name: &'static str,
    socket: Arc<UdpSocket>,
    target: SocketAddr,
}

impl Probe {
    async fn new(name: &'static str, target: SocketAddr) -> Result<Self> {
        let bind: SocketAddr = if target.ip().is_loopback() {
            (Ipv4Addr::LOCALHOST, 0).into()
        } else {
            (Ipv4Addr::UNSPECIFIED, 0).into()
        };
        Ok(Self { name, socket: Arc::new(UdpSocket::bind(bind).await?), target })
    }

    /// Sends `schedule` (offset from the start, packet size) and returns each
    /// packet's round trip in ms, or `None` if its echo never came back.
    async fn measure(&self, test: u32, schedule: &[(Duration, usize)]) -> Vec<Option<f64>> {
        let start = Instant::now();
        let results = Arc::new(Mutex::new(vec![None; schedule.len()]));
        let receiver = {
            let (socket, results) = (self.socket.clone(), results.clone());
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 65_536];
                while let Ok((len, _)) = socket.recv_from(&mut buffer).await {
                    if len < HEADER || u32::from_be_bytes(buffer[0..4].try_into().unwrap()) != test {
                        continue;
                    }
                    let sequence = u32::from_be_bytes(buffer[4..8].try_into().unwrap()) as usize;
                    let sent = u64::from_be_bytes(buffer[8..16].try_into().unwrap());
                    let rtt = (start.elapsed().as_nanos() as u64).saturating_sub(sent) as f64 / 1e6;
                    if let Some(slot) = results.lock().unwrap().get_mut(sequence) {
                        slot.get_or_insert(rtt);
                    }
                }
            })
        };
        let mut packet = vec![0u8; 65_536];
        for (sequence, (offset, size)) in schedule.iter().enumerate() {
            let due = start + *offset;
            if due > Instant::now() {
                tokio::time::sleep_until(due.into()).await;
            }
            packet[0..4].copy_from_slice(&test.to_be_bytes());
            packet[4..8].copy_from_slice(&(sequence as u32).to_be_bytes());
            packet[8..16].copy_from_slice(&(start.elapsed().as_nanos() as u64).to_be_bytes());
            let _ = self.socket.send_to(&packet[..*size], self.target).await;
        }
        tokio::time::sleep(DRAIN).await;
        receiver.abort();
        results.lock().unwrap().clone()
    }
}

/// Packets of `size` at `mbps` for `seconds`.
fn constant(size: usize, mbps: f64, seconds: f64) -> Vec<(Duration, usize)> {
    let interval = size as f64 * 8.0 / (mbps * 1e6);
    let count = (seconds / interval) as usize;
    (0..count).map(|index| (Duration::from_secs_f64(index as f64 * interval), size)).collect()
}

/// A screen-sharing shape: a steady `background_mbps` plus, every `period`, a
/// `burst_bytes` keyframe paced at `burst_mbps` (the product paces at 10× its
/// target bitrate).
fn keyframes(background_mbps: f64, burst_bytes: usize, burst_mbps: f64, period: f64, seconds: f64) -> Vec<(Duration, usize)> {
    const SIZE: usize = 1100;
    let mut schedule = constant(SIZE, background_mbps, seconds);
    let interval = SIZE as f64 * 8.0 / (burst_mbps * 1e6);
    let mut burst_start = 0.5;
    while burst_start < seconds {
        for index in 0..burst_bytes / SIZE {
            schedule.push((Duration::from_secs_f64(burst_start + index as f64 * interval), SIZE));
        }
        burst_start += period;
    }
    schedule.sort_by_key(|(offset, _)| *offset);
    schedule
}

/// Each size, 40 packets at 400 a second.
fn sweep() -> Vec<(Duration, usize)> {
    SWEEP_SIZES
        .iter()
        .flat_map(|size| std::iter::repeat_n(*size, 40))
        .enumerate()
        .map(|(index, size)| (Duration::from_micros(2500 * index as u64), size))
        .collect()
}

fn summary(results: &[Option<f64>]) -> String {
    let mut rtts: Vec<f64> = results.iter().flatten().copied().collect();
    rtts.sort_by(f64::total_cmp);
    let lost = results.len() - rtts.len();
    let percentile = |p: f64| rtts.get(((rtts.len() as f64 - 1.0) * p).round() as usize).copied().unwrap_or(f64::NAN);
    format!(
        "{:>6} sent, {:>5.1}% lost | rtt p50 {:>6.1}  p95 {:>6.1}  p99 {:>6.1}  max {:>7.1} ms",
        results.len(),
        lost as f64 * 100.0 / results.len().max(1) as f64,
        percentile(0.5),
        percentile(0.95),
        percentile(0.99),
        rtts.last().copied().unwrap_or(f64::NAN),
    )
}

async fn print_reports(connection: &NetConnection, control: &MessageStream) -> Result<()> {
    control.send(MessageKind::Text, b"report").await?;
    let host = control.recv().await?.ok_or_else(|| anyhow!("host closed the control stream"))?;
    println!("    viewer tunnel: {}", report(connection));
    println!("    host tunnel:   {}", String::from_utf8_lossy(&host.payload));
    Ok(())
}

async fn run(peer: String, addr: String, udp: String) -> Result<()> {
    let endpoint = NetEndpoint::bind(endpoint_config("0.0.0.0:0".into())).await?;
    let host = NetAddr { endpoint_id: peer, relay_url: None, direct_addrs: vec![addr] };
    let dialed = Instant::now();
    let connection = endpoint.connect(&host, ALPN_MEDIA).await?;
    let flow = MediaFlow::bind(connection.media(), FLOW).await?;
    let control = connection.open_message_stream().await?;
    println!("connected in {:.0} ms", dialed.elapsed().as_secs_f64() * 1000.0);
    // The host opens its end of the flow before answering, so after this
    // report no echo can arrive for a flow it hasn't registered yet.
    print_reports(&connection, &control).await?;

    let probes = [
        Probe::new("tunnel", (Ipv4Addr::LOCALHOST, flow.local_port()).into()).await?,
        Probe::new("udp", udp.parse()?).await?,
    ];
    let mut test = 0;

    for (label, wait_until) in [("fresh connection", Duration::ZERO), ("after path MTU discovery", Duration::from_secs(20))] {
        if let Some(wait) = wait_until.checked_sub(dialed.elapsed()) {
            tokio::time::sleep(wait).await;
        }
        println!("\nsize sweep, {label} (packets echoed of 40, by UDP payload bytes)");
        println!("  {:<8}{}", "", SWEEP_SIZES.map(|size| format!("{size:>6}")).join(""));
        for probe in &probes {
            test += 1;
            let results = probe.measure(test, &sweep()).await;
            let row: String = results.chunks(40).map(|chunk| format!("{:>6}", chunk.iter().flatten().count())).collect();
            println!("  {:<8}{row}", probe.name);
            if probe.name == "tunnel" {
                print_reports(&connection, &control).await?;
            }
        }
    }

    let rows: [(String, Vec<(Duration, usize)>); 4] = [
        ("1100 B at 5 Mbps".into(), constant(1100, 5.0, 6.0)),
        ("1100 B at 20 Mbps".into(), constant(1100, 20.0, 6.0)),
        ("1100 B at 40 Mbps".into(), constant(1100, 40.0, 6.0)),
        ("4 Mbps + 1 MiB keyframe at 60 Mbps every 2 s".into(), keyframes(4.0, 1 << 20, 60.0, 2.0, 8.0)),
    ];
    for (label, schedule) in &rows {
        println!("\n{label}");
        for probe in &probes {
            test += 1;
            let results = probe.measure(test, schedule).await;
            println!("  {:<8}{}", probe.name, summary(&results));
            if probe.name == "tunnel" {
                print_reports(&connection, &control).await?;
            }
        }
    }
    connection.close(0, "done");
    Ok(())
}
