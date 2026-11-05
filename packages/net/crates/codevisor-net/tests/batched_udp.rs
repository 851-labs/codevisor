#![cfg(target_vendor = "apple")]

use std::{future::poll_fn, io::IoSliceMut, time::Duration};

use codevisor_net::screen_transport::set_batched_udp;
use netwatch::UdpSocket;
use noq_udp::{RecvMeta, Transmit};

const SEGMENT: usize = 1_200;
const SEGMENTS: usize = 32;

#[tokio::test]
async fn sockets_bound_after_batching_is_on_send_and_receive_a_whole_batch_per_call() {
    let unbatched = UdpSocket::bind_local_v4(0).unwrap();
    set_batched_udp(true);
    let sender = UdpSocket::bind_local_v4(0).unwrap();
    assert_eq!(unbatched.max_gso_segments().get(), 1, "a socket bound before keeps one datagram per call");
    let receiver = UdpSocket::bind_local_v4(0).unwrap();
    assert_eq!(sender.max_gso_segments().get(), SEGMENTS, "batching is on");

    let contents: Vec<u8> = (0..SEGMENTS).flat_map(|index| [index as u8; SEGMENT]).collect();
    let transmit = Transmit {
        destination: receiver.local_addr().unwrap(),
        ecn: None,
        contents: &contents,
        segment_size: Some(SEGMENT),
        src_ip: None,
    };
    poll_fn(|cx| sender.poll_send_noq(cx, &transmit)).await.unwrap();

    let mut received = Vec::new();
    let mut buffers = vec![[0u8; 2_048]; SEGMENTS];
    while received.len() < SEGMENTS {
        let mut slices: Vec<IoSliceMut<'_>> = buffers.iter_mut().map(|buffer| IoSliceMut::new(buffer)).collect();
        let mut metas = [RecvMeta::default(); SEGMENTS];
        let count = tokio::time::timeout(Duration::from_secs(5), poll_fn(|cx| receiver.poll_recv_noq(cx, &mut slices, &mut metas)))
            .await
            .expect("every datagram arrives")
            .unwrap();
        for (slice, meta) in slices.iter().zip(&metas).take(count) {
            assert_eq!(meta.len, SEGMENT);
            received.push(slice[0]);
            assert!(slice[..SEGMENT].iter().all(|byte| *byte == slice[0]), "datagram {} arrived whole", slice[0]);
        }
    }
    assert_eq!(received, (0..SEGMENTS as u8).collect::<Vec<_>>(), "each datagram once, in order");
}
