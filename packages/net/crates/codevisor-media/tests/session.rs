use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use bytes::Bytes;
use codevisor_media::{
    ALPN_SCREEN, DatagramTransport, Event, FecMode, MediaConfig, MediaSession, OutgoingFrame, QuicTransport, Recovery,
    SendOutcome, netsim::SplitMix64, wire::PacketHeader,
};
use codevisor_net::{NetConfig, NetEndpoint, PathPolicy, generate_secret_key};
use tokio::sync::mpsc;

type Rule = Box<dyn FnMut(&Bytes) -> bool + Send>;

/// One end of an in-memory link. `drop` decides per outgoing datagram; `room` limits how many datagrams it takes
/// before reporting itself full.
struct MemoryTransport {
    out: Mutex<Option<mpsc::UnboundedSender<Bytes>>>,
    incoming: tokio::sync::Mutex<mpsc::UnboundedReceiver<Bytes>>,
    drop: Mutex<Rule>,
    room: Arc<AtomicUsize>,
}

impl MemoryTransport {
    fn pair() -> (Self, Self) {
        let (to_b, from_a) = mpsc::unbounded_channel();
        let (to_a, from_b) = mpsc::unbounded_channel();
        let end = |out, incoming| Self {
            out: Mutex::new(Some(out)),
            incoming: tokio::sync::Mutex::new(incoming),
            drop: Mutex::new(Box::new(|_: &Bytes| false)),
            room: Arc::new(AtomicUsize::new(usize::MAX)),
        };
        (end(to_b, from_b), end(to_a, from_a))
    }
}

impl DatagramTransport for MemoryTransport {
    fn max_datagram_size(&self) -> Option<usize> {
        Some(1200)
    }

    fn send(&self, datagram: Bytes) -> SendOutcome {
        if self.room.load(Ordering::SeqCst) == 0 {
            return SendOutcome::Full(datagram);
        }
        self.room.fetch_sub(1, Ordering::SeqCst);
        if !(self.drop.lock().unwrap())(&datagram)
            && let Some(out) = &*self.out.lock().unwrap()
        {
            let _ = out.send(datagram);
        }
        SendOutcome::Sent
    }

    async fn recv(&self) -> Option<Bytes> {
        self.incoming.lock().await.recv().await
    }

    fn rtt(&self) -> Option<Duration> {
        Some(Duration::from_millis(1))
    }
}

fn config() -> MediaConfig {
    MediaConfig { fec: FecMode::Off, ..MediaConfig::default() }
}

fn payload(seed: u64, len: usize) -> Bytes {
    let mut random = SplitMix64::new(seed);
    Bytes::from((0..len).map(|_| random.next_u64() as u8).collect::<Vec<u8>>())
}

async fn next_frame(session: &MediaSession<impl DatagramTransport>) -> codevisor_media::ReceivedFrame {
    loop {
        match session.next_event().await.expect("session open") {
            Event::Frame(frame) => return frame,
            _ => continue,
        }
    }
}

#[tokio::test(start_paused = true)]
async fn the_session_timers_repair_a_lost_tail_with_no_more_traffic() {
    let (host_end, viewer_end) = MemoryTransport::pair();
    let mut first = true;
    *host_end.drop.lock().unwrap() = Box::new(move |datagram| {
        // The frame's last data packet (index 4 of 5), the first time only.
        let last = PacketHeader::decode(datagram.clone()).is_some_and(|(header, _)| header.index == 4);
        let drop = last && first;
        first &= !drop;
        drop
    });
    let host = MediaSession::new(host_end, config());
    let viewer = MediaSession::new(viewer_end, config());
    let data = payload(1, 5000);
    host.send_frame(OutgoingFrame { data: &data, ..OutgoingFrame::default() }).unwrap();

    let frame = next_frame(&viewer).await;
    assert_eq!(frame.data, data);
    assert_eq!(frame.recovery, Recovery::Nack);
    match host.next_event().await {
        Some(Event::FrameAcked(ack)) => assert_eq!(ack.frame, 0),
        other => panic!("{other:?}"),
    }
}

#[tokio::test(start_paused = true)]
async fn a_full_transport_holds_datagrams_until_it_has_room() {
    let (host_end, viewer_end) = MemoryTransport::pair();
    let room = host_end.room.clone();
    room.store(2, Ordering::SeqCst);
    let host = MediaSession::new(host_end, config());
    let viewer = MediaSession::new(viewer_end, config());
    let data = payload(2, 5000);
    host.send_frame(OutgoingFrame { data: &data, ..OutgoingFrame::default() }).unwrap();
    assert!(host.admission().backlog_bytes > 0, "three packets wait in the pacer behind the held one");
    tokio::time::sleep(Duration::from_millis(5)).await;
    assert!(viewer.try_next_event().is_none());

    room.store(usize::MAX, Ordering::SeqCst);
    assert_eq!(next_frame(&viewer).await.data, data);
    assert_eq!(host.stats().transport_rejected, 0);
}

#[tokio::test(start_paused = true)]
async fn events_end_when_the_transport_closes() {
    let (host_end, viewer_end) = MemoryTransport::pair();
    let viewer = MediaSession::new(viewer_end, config());
    host_end.out.lock().unwrap().take();
    drop(host_end);
    assert_eq!(viewer.next_event().await, None);
}

#[tokio::test(start_paused = true)]
async fn events_end_when_the_session_is_closed() {
    let (host_end, _viewer_end) = MemoryTransport::pair();
    let host = Arc::new(MediaSession::new(host_end, config()));
    let waiting = tokio::spawn({
        let host = host.clone();
        async move { host.next_event().await }
    });
    host.close();
    assert_eq!(waiting.await.unwrap(), None);
}

#[tokio::test]
async fn frames_cross_a_real_iroh_connection_unchanged_and_ltr_acks_come_back() {
    let endpoint = |alpns: Vec<Vec<u8>>| NetConfig {
        secret_key: generate_secret_key(),
        relays: vec![],
        trust_anchors_pem: vec![],
        bind_addrs: vec!["127.0.0.1:0".into()],
        path_policy: PathPolicy::DirectOnly,
        alpns,
    };
    let viewer_endpoint = NetEndpoint::bind(endpoint(vec![ALPN_SCREEN.to_vec()])).await.unwrap();
    let host_endpoint = NetEndpoint::bind(endpoint(vec![])).await.unwrap();
    let viewer_addr = viewer_endpoint.addr();
    let (host_connection, viewer_connection) =
        tokio::join!(host_endpoint.connect(&viewer_addr, ALPN_SCREEN), viewer_endpoint.accept());
    let host = MediaSession::new(QuicTransport(host_connection.unwrap()), MediaConfig::default());
    let viewer = MediaSession::new(QuicTransport(viewer_connection.unwrap().unwrap()), MediaConfig::default());

    // One frame at a time, each after the previous ack: this checks the real connection's wiring, not its loss
    // handling under a debug build's slow receive path (the simulated-network tests own that).
    // (stream, keyframe, LTR token, metadata, access unit)
    type Sent = (u8, bool, Option<u64>, Vec<u8>, Bytes);
    let sent: Vec<Sent> = [1, 1200, 64_000, 200_000, 300]
        .into_iter()
        .enumerate()
        .map(|(index, len)| {
            (
                (index % 2) as u8,
                index == 0,
                (index == 3).then_some(7),
                vec![index as u8; 12],
                payload(index as u64, len),
            )
        })
        .collect();
    let exchange = async {
        let mut received: Vec<Sent> = Vec::new();
        let mut ltr = None;
        for (stream, keyframe, ltr_token, meta, data) in &sent {
            let frame = OutgoingFrame { stream: *stream, keyframe: *keyframe, ltr_token: *ltr_token, meta, data };
            host.send_frame(frame).unwrap();
            let frame = next_frame(&viewer).await;
            if let Some(token) = frame.ltr_token {
                viewer.ack_ltr(frame.stream, token);
            }
            received.push((frame.stream, frame.keyframe, frame.ltr_token, frame.meta, frame.data));
            loop {
                match host.next_event().await.expect("session open") {
                    Event::FrameAcked(_) => break,
                    Event::LtrAcked { stream, token } => ltr = Some((stream, token)),
                    other => panic!("{other:?}"),
                }
            }
        }
        while ltr.is_none() {
            if let Some(Event::LtrAcked { stream, token }) = host.next_event().await {
                ltr = Some((stream, token));
            }
        }
        (received, ltr)
    };
    // A deadlock guard only; the exchange takes milliseconds.
    let (received, ltr) = tokio::time::timeout(Duration::from_secs(60), exchange).await.expect("exchange finishes");
    assert_eq!(received, sent);
    assert_eq!(ltr, Some((1, 7)));
}
