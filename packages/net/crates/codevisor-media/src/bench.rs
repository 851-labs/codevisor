//! The M1 transport bench: synthetic frames through a [`MediaSession`], over iroh QUIC datagrams and over plain UDP
//! with the same framing, optionally through one of the benchmark's emulated networks. Run it as the
//! `media_transport_bench` example on one machine, or on two Macs through `CodevisorBench media-transport`, which
//! calls [`run`] inside the signed bench app so macOS lets it reach the LAN.
//!
//! ```text
//! viewer   --bind ADDR --udp-bind ADDR --secret HEX [--network N3] [--seconds 10] [--idle-exit-s S]
//! host     --peer-id ID | --peer-secret HEX, --peer ADDR --udp-peer ADDR [--network N3] [--rows all] [--seconds 10]
//!          [--json PATH] [--network-label "N3 (dummynet)"]
//! loopback [--network N3] [--rows all] [--seconds 10] [--json PATH]
//! send-cost [--frames 300]
//! ```
//!
//! `send-cost` times [`MediaSession::send_frame`] itself over a loopback connection: the Rust side of a frame's
//! hand-off, to set against what `CodevisorBench media-transport --role ffi-cost` measures from Swift.
//!
//! For each row and transport the host reports the frame round trip (`send_frame` to the ack: pacing, both network
//! legs, assembly and the feedback) and its p50/p95 difference from plain UDP, the recovery delay of frames that
//! lost packets (completion after the last packet that arrived the first time), and the counters.

use std::{
    collections::HashMap,
    fmt::Write as _,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use bytes::Bytes;
use codevisor_net::{
    NetAddr, NetConfig, NetEndpoint, PathPolicy, endpoint_id_for, generate_secret_key, secret_key_from_hex,
};
use tokio::net::UdpSocket;

use crate::{
    ALPN_SCREEN, DatagramTransport, Event, FecMode, ImpairedTransport, MediaConfig, MediaSession, OutgoingFrame,
    QuicTransport, UdpTransport,
    netsim::{NetworkConditions, SplitMix64},
};

const INTERVAL: Duration = Duration::from_micros(16_667);
const DRAIN: Duration = Duration::from_millis(700);
/// The raw-UDP baseline's datagram size: what iroh reaches on a 1500-byte LAN path after path MTU discovery.
const UDP_DATAGRAM: usize = 1400;
/// How long a viewer waits for the host's first frame (the other machine may still be building).
const FIRST_FRAME_PATIENCE: Duration = Duration::from_secs(1200);
const HOST_SEED: u64 = 0x5EED_0001;
const VIEWER_SEED: u64 = 0x5EED_0002;

#[derive(Debug, Clone, Copy)]
struct Row {
    name: &'static str,
    /// Frame bytes per stream per interval.
    frame_bytes: usize,
    streams: u8,
    /// Every this many frames, one stream's frame is this big instead.
    keyframe: Option<(u32, usize)>,
}

const ROWS: [Row; 6] = [
    Row { name: "8 Mbit/s", frame_bytes: 16_667, streams: 1, keyframe: None },
    Row { name: "45 Mbit/s", frame_bytes: 93_750, streams: 1, keyframe: None },
    Row { name: "150 Mbit/s", frame_bytes: 312_500, streams: 1, keyframe: None },
    Row { name: "300 Mbit/s", frame_bytes: 625_000, streams: 1, keyframe: None },
    Row { name: "150 Mbit/s in 4 tiles", frame_bytes: 78_125, streams: 4, keyframe: None },
    Row { name: "8 Mbit/s + 1 MiB keyframe/s", frame_bytes: 16_667, streams: 1, keyframe: Some((60, 1 << 20)) },
];

/// Runs the bench with command-line style arguments and returns its report (markdown, then a JSON line).
pub async fn run(args: Vec<String>) -> Result<String> {
    let options = Options::parse(&args)?;
    match args.first().map(String::as_str) {
        Some("viewer") => viewer(&options).await,
        Some("host") => host(&options).await,
        Some("loopback") => loopback(&options).await,
        Some("send-cost") => send_cost(&options).await,
        _ => bail!("usage: viewer | host | loopback | send-cost [--option value …] (see codevisor_media::bench)"),
    }
}

struct Options(HashMap<String, String>);

impl Options {
    fn parse(args: &[String]) -> Result<Self> {
        let mut values = HashMap::new();
        let mut rest = args.iter().skip(1);
        while let Some(name) = rest.next() {
            let name = name.strip_prefix("--").ok_or_else(|| anyhow!("expected an --option, got {name}"))?;
            let value = rest.next().ok_or_else(|| anyhow!("--{name} needs a value"))?;
            values.insert(name.to_string(), value.clone());
        }
        Ok(Self(values))
    }

    fn get(&self, name: &str) -> Result<&str> {
        self.0.get(name).map(String::as_str).ok_or_else(|| anyhow!("missing --{name}"))
    }

    fn or<'a>(&'a self, name: &str, default: &'a str) -> &'a str {
        self.0.get(name).map_or(default, String::as_str)
    }

    fn network(&self) -> Result<NetworkConditions> {
        let id = self.or("network", "N0");
        NetworkConditions::by_id(id).ok_or_else(|| anyhow!("unknown network {id}"))
    }

    fn rows(&self) -> Result<Vec<(usize, Row)>> {
        let spec = self.or("rows", "all");
        if spec == "all" {
            return Ok(ROWS.into_iter().enumerate().collect());
        }
        spec.split(',')
            .map(|index| {
                let index: usize = index.trim().parse().context("--rows takes row numbers, e.g. 0,3")?;
                Ok((index, *ROWS.get(index).ok_or_else(|| anyhow!("no row {index}"))?))
            })
            .collect()
    }

    fn seconds(&self) -> Result<f64> {
        Ok(self.or("seconds", "10").parse()?)
    }
}

fn media_config() -> MediaConfig {
    MediaConfig { frame_interval: INTERVAL, fec: FecMode::Adaptive, ..MediaConfig::default() }
}

fn endpoint_config(secret_key: [u8; 32], bind: &str) -> NetConfig {
    NetConfig {
        secret_key,
        relays: vec![],
        trust_anchors_pem: vec![],
        bind_addrs: vec![bind.to_string()],
        path_policy: PathPolicy::DirectOnly,
        alpns: vec![ALPN_SCREEN.to_vec()],
    }
}

/// A frame's content is seeded noise; its metadata is the frame's index and a checksum the viewer verifies.
fn frame_data(cache: &mut HashMap<usize, Bytes>, len: usize) -> Bytes {
    cache
        .entry(len)
        .or_insert_with(|| {
            let mut random = SplitMix64::new(len as u64);
            Bytes::from((0..len).map(|_| random.next_u64() as u8).collect::<Vec<u8>>())
        })
        .clone()
}

fn checksum(data: &[u8]) -> u64 {
    data.iter().fold(0xCBF2_9CE4_8422_2325, |hash, byte| (hash ^ u64::from(*byte)).wrapping_mul(0x100_0000_01B3))
}

#[derive(Default)]
struct ViewerTally {
    frames: u64,
    corrupt: u64,
    skipped: u64,
}

/// Drains a viewer session until its transport closes or, once frames started, nothing arrives for `idle`.
async fn serve_viewer<T: DatagramTransport>(session: MediaSession<T>, idle: Duration) -> (ViewerTally, crate::Stats) {
    let mut tally = ViewerTally::default();
    let mut wait = FIRST_FRAME_PATIENCE;
    while let Ok(Some(event)) = tokio::time::timeout(wait, session.next_event()).await {
        wait = idle;
        match event {
            Event::Frame(frame) => {
                tally.frames += 1;
                let expected = frame.meta.get(..8).map(|bytes| u64::from_be_bytes(bytes.try_into().unwrap()));
                if expected != Some(checksum(&frame.data)) {
                    tally.corrupt += 1;
                }
            }
            Event::FrameSkipped { .. } => tally.skipped += 1,
            _ => {}
        }
    }
    let stats = session.stats();
    (tally, stats)
}

fn viewer_line(label: &str, tally: &ViewerTally, stats: &crate::Stats) -> String {
    format!(
        "viewer {label}: {} frames ({} failed the checksum), {} skipped; {} packets, {} NACKs, {} FEC repairs",
        tally.frames, tally.corrupt, tally.skipped, stats.packets_received, stats.nacks_sent, stats.fec_recoveries
    )
}

async fn viewer(options: &Options) -> Result<String> {
    let secret = secret_key_from_hex(options.get("secret")?)?;
    let network = options.network()?;
    // Each transport's session sits idle while the host runs the other transport's row.
    let row_idle = Duration::from_secs_f64(options.seconds()? * 2.0) + DRAIN * 2 + Duration::from_secs(5);
    let idle = Duration::from_secs_f64(options.or("idle-exit-s", "0").parse()?).max(row_idle);
    let endpoint = NetEndpoint::bind(endpoint_config(secret, options.get("bind")?)).await?;
    let udp = UdpSocket::bind(options.get("udp-bind")?).await?;
    eprintln!("viewer {} on {:?}, udp {}", endpoint.endpoint_id(), endpoint.bound_sockets(), udp.local_addr()?);
    let udp = UdpTransport::new(udp, None, UDP_DATAGRAM, Duration::from_micros(500));
    let udp_task = tokio::spawn(serve_viewer(
        MediaSession::new(ImpairedTransport::new(udp, network, VIEWER_SEED), media_config()),
        idle,
    ));
    let connection = endpoint.accept().await?.ok_or_else(|| anyhow!("endpoint closed"))?;
    let session =
        MediaSession::new(ImpairedTransport::new(QuicTransport(connection), network, VIEWER_SEED), media_config());
    let (quic_tally, quic_stats) = serve_viewer(session, idle).await;
    let (udp_tally, udp_stats) = udp_task.await?;
    endpoint.close().await;
    Ok(format!("{}\n{}\n", viewer_line("iroh", &quic_tally, &quic_stats), viewer_line("udp", &udp_tally, &udp_stats)))
}

async fn connect_quic(
    endpoint: &NetEndpoint,
    peer: &NetAddr,
    patience: Duration,
) -> Result<codevisor_net::NetConnection> {
    let deadline = Instant::now() + patience;
    loop {
        match tokio::time::timeout(Duration::from_secs(10), endpoint.connect(peer, ALPN_SCREEN)).await {
            Ok(Ok(connection)) => return Ok(connection),
            result if Instant::now() > deadline => {
                return Err(match result {
                    Ok(Err(error)) => error,
                    _ => anyhow!("connect timed out"),
                });
            }
            _ => tokio::time::sleep(Duration::from_secs(2)).await,
        }
    }
}

async fn host(options: &Options) -> Result<String> {
    let network = options.network()?;
    let endpoint_id = match options.0.get("peer-secret") {
        Some(secret) => endpoint_id_for(&secret_key_from_hex(secret)?),
        None => options.get("peer-id")?.to_string(),
    };
    let peer = NetAddr { endpoint_id, relay_url: None, direct_addrs: vec![options.get("peer")?.to_string()] };
    let udp_peer: SocketAddr = options.get("udp-peer")?.parse()?;
    let patience = Duration::from_secs_f64(options.or("connect-patience-s", "600").parse()?);
    let endpoint = NetEndpoint::bind(endpoint_config(generate_secret_key(), options.or("bind", "0.0.0.0:0"))).await?;
    let connection = connect_quic(&endpoint, &peer, patience).await?;
    let report = measure(options, network, connection, udp_peer).await?;
    endpoint.close().await;
    Ok(report)
}

async fn loopback(options: &Options) -> Result<String> {
    let network = options.network()?;
    // Each transport's viewer sits idle while the other transport runs its row.
    let idle = Duration::from_secs_f64(options.seconds()? * 2.0) + DRAIN * 2 + Duration::from_secs(5);
    let secret = generate_secret_key();
    let viewer_endpoint = NetEndpoint::bind(endpoint_config(secret, "127.0.0.1:0")).await?;
    let viewer_udp = UdpSocket::bind("127.0.0.1:0").await?;
    let udp_peer = viewer_udp.local_addr()?;
    let viewer_addr = NetAddr {
        endpoint_id: endpoint_id_for(&secret),
        relay_url: None,
        direct_addrs: viewer_endpoint.bound_sockets(),
    };
    let viewer_udp = UdpTransport::new(viewer_udp, None, UDP_DATAGRAM, Duration::from_micros(100));
    let udp_viewer = tokio::spawn(serve_viewer(
        MediaSession::new(ImpairedTransport::new(viewer_udp, network, VIEWER_SEED), media_config()),
        idle,
    ));
    let viewer_endpoint = Arc::new(viewer_endpoint);
    let quic_viewer = {
        let endpoint = viewer_endpoint.clone();
        tokio::spawn(async move {
            let connection = endpoint.accept().await?.ok_or_else(|| anyhow!("endpoint closed"))?;
            let session = MediaSession::new(
                ImpairedTransport::new(QuicTransport(connection), network, VIEWER_SEED),
                media_config(),
            );
            anyhow::Ok(serve_viewer(session, idle).await)
        })
    };
    let host_endpoint = NetEndpoint::bind(endpoint_config(generate_secret_key(), "127.0.0.1:0")).await?;
    let connection = connect_quic(&host_endpoint, &viewer_addr, Duration::from_secs(10)).await?;
    let mut report = measure(options, network, connection.clone(), udp_peer).await?;
    connection.close(0, "done");
    let (quic_tally, quic_stats) = quic_viewer.await??;
    let (udp_tally, udp_stats) = udp_viewer.await?;
    report.push_str(&viewer_line("iroh", &quic_tally, &quic_stats));
    report.push('\n');
    report.push_str(&viewer_line("udp", &udp_tally, &udp_stats));
    report.push('\n');
    Ok(report)
}

/// Sizes the frame hand-off is timed at: an HP-like tile, a large tile, a keyframe.
pub const HAND_OFF_SIZES: [usize; 3] = [64 << 10, 256 << 10, 1 << 20];

async fn send_cost(options: &Options) -> Result<String> {
    let frames: usize = options.or("frames", "300").parse()?;
    let secret = generate_secret_key();
    let viewer_endpoint = NetEndpoint::bind(endpoint_config(secret, "127.0.0.1:0")).await?;
    let viewer_addr = NetAddr {
        endpoint_id: endpoint_id_for(&secret),
        relay_url: None,
        direct_addrs: viewer_endpoint.bound_sockets(),
    };
    let host_endpoint = NetEndpoint::bind(endpoint_config(generate_secret_key(), "127.0.0.1:0")).await?;
    let (host, viewer) =
        tokio::join!(connect_quic(&host_endpoint, &viewer_addr, Duration::from_secs(10)), viewer_endpoint.accept());
    let host = MediaSession::new(QuicTransport(host?), media_config());
    let viewer = MediaSession::new(QuicTransport(viewer?.ok_or_else(|| anyhow!("endpoint closed"))?), media_config());
    let drain = tokio::spawn(async move { while viewer.next_event().await.is_some() {} });
    let mut report = String::from("| Frame | send_frame p50 / p95 ms (Rust) |\n| -- | -- |\n");
    let mut cache = HashMap::new();
    let mut ticker = tokio::time::interval(INTERVAL);
    for size in HAND_OFF_SIZES {
        let mut durations = Vec::with_capacity(frames);
        for _ in 0..frames {
            ticker.tick().await;
            let data = frame_data(&mut cache, size);
            let started = Instant::now();
            host.send_frame(OutgoingFrame { data, ..Default::default() })?;
            durations.push(started.elapsed().as_secs_f64() * 1000.0);
            while host.try_next_event().is_some() {}
        }
        writeln!(
            report,
            "| {} KiB | {:.3} / {:.3} |",
            size >> 10,
            percentile(&durations, 0.5),
            percentile(&durations, 0.95)
        )?;
    }
    drain.abort();
    Ok(report)
}

#[derive(Default)]
struct Measured {
    round_trips_ms: Vec<f64>,
    sending_ms: Vec<f64>,
    /// Recovery delay of frames that lost packets, and whether it was within the round trip + 2 ms.
    recoveries_ms: Vec<f64>,
    within: u64,
    timed: u64,
    acked: u64,
    lost: u64,
    sent: u64,
    stats: crate::Stats,
}

async fn measure(
    options: &Options,
    network: NetworkConditions,
    connection: codevisor_net::NetConnection,
    udp_peer: SocketAddr,
) -> Result<String> {
    let rows = options.rows()?;
    let seconds = options.seconds()?;
    let quic = MediaSession::new(
        ImpairedTransport::new(QuicTransport(connection.clone()), network, HOST_SEED),
        media_config(),
    );
    // Let path MTU discovery and the RTT estimate settle before measuring.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let path_rtt = connection.rtt().unwrap_or(Duration::from_micros(500));
    let udp_socket = UdpSocket::bind(if udp_peer.ip().is_loopback() { "127.0.0.1:0" } else { "0.0.0.0:0" }).await?;
    let udp = MediaSession::new(
        ImpairedTransport::new(
            UdpTransport::new(udp_socket, Some(udp_peer), UDP_DATAGRAM, path_rtt),
            network,
            HOST_SEED,
        ),
        media_config(),
    );
    let mut table = String::new();
    let mut json = Vec::new();
    writeln!(
        table,
        "Network {} · {} s per row · iroh path {} (max datagram {:?}, RTT {:.2} ms)\n",
        options.or("network-label", network.id),
        seconds,
        connection.paths().iter().find(|path| path.selected).map_or("?".into(), |path| path.remote.clone()),
        connection.max_datagram_size(),
        path_rtt.as_secs_f64() * 1000.0,
    )?;
    table.push_str(
        "| Row | Transport | Frames acked / lost | Round trip p50 / p95 / p99 ms | Added vs UDP p50 / p95 ms | Pacing p50 ms \
         | Frames within RTT+2 ms (lossy ones) | Recovery p50 / p95 ms | Retransmits / FEC parity / probes |\n\
         | -- | -- | -- | -- | -- | -- | -- | -- | -- |\n",
    );
    for (index, row) in rows {
        let stream_base = (index as u8) * 4;
        let udp_result = run_row(&udp, row, stream_base, seconds).await;
        let quic_result = run_row(&quic, row, stream_base, seconds).await;
        for (label, result) in [("iroh", &quic_result), ("udp", &udp_result)] {
            let added = if label == "iroh" {
                format!(
                    "{:+.2} / {:+.2}",
                    percentile(&quic_result.round_trips_ms, 0.5) - percentile(&udp_result.round_trips_ms, 0.5),
                    percentile(&quic_result.round_trips_ms, 0.95) - percentile(&udp_result.round_trips_ms, 0.95)
                )
            } else {
                "–".into()
            };
            writeln!(
                table,
                "| {} | {label} | {} / {} | {:.2} / {:.2} / {:.2} | {added} | {:.2} | {} | {:.2} / {:.2} | {} / {} / {} |",
                row.name,
                result.acked,
                result.lost,
                percentile(&result.round_trips_ms, 0.5),
                percentile(&result.round_trips_ms, 0.95),
                percentile(&result.round_trips_ms, 0.99),
                percentile(&result.sending_ms, 0.5),
                {
                    let late = result.timed - result.within;
                    let on_time = result.sent.saturating_sub(late);
                    format!(
                        "{:.2}% ({} of {})",
                        on_time as f64 * 100.0 / result.sent.max(1) as f64,
                        result.within,
                        result.timed
                    )
                },
                percentile(&result.recoveries_ms, 0.5),
                percentile(&result.recoveries_ms, 0.95),
                result.stats.packets_retransmitted,
                result.stats.parity_packets_sent,
                result.stats.probes_sent,
            )?;
            json.push(format!(
                "{{\"row\":\"{}\",\"transport\":\"{label}\",\"network\":\"{}\",\"sent\":{},\"acked\":{},\"lost\":{},\
                 \"rtt_p50_ms\":{:.3},\"rtt_p95_ms\":{:.3},\"rtt_p99_ms\":{:.3},\"pacing_p50_ms\":{:.3},\
                 \"lossy_frames\":{},\"lossy_within_rtt_2ms\":{},\"recovery_p95_ms\":{:.3},\"retransmits\":{},\
                 \"parity\":{},\"probes\":{},\"estimate_mbps\":{:.1}}}",
                row.name,
                network.id,
                result.sent,
                result.acked,
                result.lost,
                percentile(&result.round_trips_ms, 0.5),
                percentile(&result.round_trips_ms, 0.95),
                percentile(&result.round_trips_ms, 0.99),
                percentile(&result.sending_ms, 0.5),
                result.timed,
                result.within,
                percentile(&result.recoveries_ms, 0.95),
                result.stats.packets_retransmitted,
                result.stats.parity_packets_sent,
                result.stats.probes_sent,
                result.stats.estimate_bps / 1e6,
            ));
        }
    }
    let json = format!("[{}]", json.join(","));
    if let Some(path) = options.0.get("json") {
        std::fs::write(path, &json).with_context(|| format!("writing {path}"))?;
    }
    Ok(format!("{table}\n{json}\n"))
}

/// Sends one row's frames at 60 Hz on `stream_base..stream_base + row.streams` and collects their acks.
async fn run_row<T: DatagramTransport>(session: &MediaSession<T>, row: Row, stream_base: u8, seconds: f64) -> Measured {
    let before = session.stats();
    let frames = (seconds / INTERVAL.as_secs_f64()) as u32;
    let mut cache = HashMap::new();
    let mut submitted: HashMap<(u8, u32), Instant> = HashMap::new();
    let mut measured = Measured::default();
    let mut ticker = tokio::time::interval(INTERVAL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let collect =
        |measured: &mut Measured, submitted: &mut HashMap<(u8, u32), Instant>, event: Event, rtt: Duration| match event
        {
            Event::FrameAcked(ack) => {
                let Some(sent) = submitted.remove(&(ack.stream, ack.frame)) else {
                    return;
                };
                measured.acked += 1;
                measured.round_trips_ms.push(sent.elapsed().as_secs_f64() * 1000.0);
                measured.sending_ms.push(ack.sending.as_secs_f64() * 1000.0);
                if let Some(receipt) = ack.receipt
                    && receipt.recovery != crate::Recovery::None
                {
                    let recovery = receipt.assembling.saturating_sub(receipt.arriving);
                    measured.timed += 1;
                    measured.within += u64::from(recovery <= rtt + Duration::from_millis(2));
                    measured.recoveries_ms.push(recovery.as_secs_f64() * 1000.0);
                }
            }
            Event::FrameLost { stream, frame } if submitted.remove(&(stream, frame)).is_some() => {
                measured.lost += 1;
                measured.timed += 1;
            }
            _ => {}
        };
    let mut index = 0;
    while index < frames {
        // Take events as they arrive, so an ack is timed when it lands rather than at the next tick.
        tokio::select! {
            biased;
            event = session.next_event() => {
                let Some(event) = event else { break };
                let rtt = session.stats().rtt;
                collect(&mut measured, &mut submitted, event, rtt);
                continue;
            }
            _ = ticker.tick() => {}
        }
        for stream in 0..row.streams {
            let len = match row.keyframe {
                Some((every, len)) if index % every == every - 1 && stream == 0 => len,
                _ => row.frame_bytes,
            };
            let data = frame_data(&mut cache, len);
            let meta = checksum(&data).to_be_bytes().to_vec();
            let sent = Instant::now();
            if let Ok(number) =
                session.send_frame(OutgoingFrame { stream: stream_base + stream, meta, data, ..Default::default() })
            {
                submitted.insert((stream_base + stream, number), sent);
                measured.sent += 1;
            }
        }
        index += 1;
    }
    let deadline = tokio::time::Instant::now() + DRAIN;
    while let Ok(Some(event)) = tokio::time::timeout_at(deadline, session.next_event()).await {
        let rtt = session.stats().rtt;
        collect(&mut measured, &mut submitted, event, rtt);
    }
    let after = session.stats();
    measured.stats = crate::Stats {
        packets_retransmitted: after.packets_retransmitted - before.packets_retransmitted,
        parity_packets_sent: after.parity_packets_sent - before.parity_packets_sent,
        probes_sent: after.probes_sent - before.probes_sent,
        ..after
    };
    measured
}

fn percentile(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return f64::NAN;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}
