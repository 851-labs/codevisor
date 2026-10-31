//! The QUIC transport of screen sharing connections ([`ALPN_SCREEN`](crate::ALPN_SCREEN), engine v2).
//!
//! `codevisor-media` paces each frame itself and turns its own delivery-rate estimate into the encoder's admission,
//! so QUIC's congestion window and pacer would only queue its datagrams a second time. A screen connection gets
//! [`transport_config`] instead of iroh's defaults: [`DeferringController`] (no window or pacing while the path
//! delivers), a datagram send buffer of a few frames' packets rather than 1 MiB, and a 100 ms initial RTT. The
//! endpoint applies it to every connection on that ALPN, dialed and accepted alike.

use std::{
    any::Any,
    sync::Arc,
    time::{Duration, Instant},
};

use iroh::endpoint::{Controller, ControllerFactory, QuicTransportConfig, RttEstimator};

/// What QUIC may hold for `codevisor-media` before handing datagrams back to its pacer as full: about 180 packets,
/// several bursts of the pacer's, so a frame never waits on it, but not the 1 MiB default that queued for 100 ms
/// and more on a slow link (the design's §3.3).
pub const DATAGRAM_SEND_BUFFER: usize = 256 * 1024;
/// Received datagrams QUIC holds until `codevisor-media` reads them: two 1 MiB keyframes, so a reader running late
/// behind a keyframe burst loses nothing.
pub const DATAGRAM_RECEIVE_BUFFER: usize = 2 * 1024 * 1024;
/// The round trip assumed before the first sample (RFC 9002 says 333 ms). A lost first handshake packet is resent
/// after 3 × this, 300 ms instead of a second on the LAN; a slower relay path costs at most one spare resend.
pub const INITIAL_RTT: Duration = Duration::from_millis(100);

pub fn transport_config() -> QuicTransportConfig {
    QuicTransportConfig::builder()
        .congestion_controller_factory(Arc::new(DeferringControllerFactory))
        .datagram_send_buffer_size(DATAGRAM_SEND_BUFFER)
        .datagram_receive_buffer_size(Some(DATAGRAM_RECEIVE_BUFFER))
        .initial_rtt(INITIAL_RTT)
        .build()
}

/// A window this large switches noq's pacer off as well (it stops pacing above `u32::MAX`).
const UNLIMITED: u64 = 1 << 40;
/// Once recovery's slow start reaches this window (about 330 Mbit/s at a 100 ms round trip) the path is treated as
/// healthy again and the window lifted.
const RECOVERED: u64 = 4 * 1024 * 1024;

/// A congestion controller that defers to `codevisor-media`'s rate control: no window and no pacing while the path
/// delivers, so its datagrams leave as soon as its pacer releases them, and ordinary loss changes nothing here (the
/// media rate control and FEC react to it).
///
/// It's still a circuit breaker. After persistent congestion (every packet lost over several probe timeouts: the
/// path went dead or changed), it drops to two packets and slow-starts, doubling each round trip, until the window
/// reaches [`RECOVERED`]; then it steps aside again.
#[derive(Debug, Clone)]
pub struct DeferringController {
    mtu: u64,
    /// `None` while deferring; the slow-start window after persistent congestion.
    recovering: Option<u64>,
}

impl DeferringController {
    fn new(mtu: u16) -> Self {
        Self { mtu: mtu.into(), recovering: None }
    }

    fn minimum_window(&self) -> u64 {
        2 * self.mtu
    }

    fn acked(&mut self, bytes: u64) {
        if let Some(window) = self.recovering {
            let window = window + bytes;
            self.recovering = (window < RECOVERED).then_some(window);
        }
    }

    fn congested(&mut self, persistent: bool) {
        if persistent {
            self.recovering = Some(self.minimum_window());
        }
    }
}

impl Controller for DeferringController {
    fn on_ack(&mut self, _now: Instant, _sent: Instant, bytes: u64, _pn: u64, _app_limited: bool, _rtt: &RttEstimator) {
        self.acked(bytes);
    }

    fn on_congestion_event(
        &mut self,
        _now: Instant,
        _sent: Instant,
        is_persistent_congestion: bool,
        _is_ecn: bool,
        _lost_bytes: u64,
        _largest_lost_pn: u64,
    ) {
        self.congested(is_persistent_congestion);
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu.into();
        let minimum = self.minimum_window();
        if let Some(window) = &mut self.recovering {
            *window = (*window).max(minimum);
        }
    }

    fn window(&self) -> u64 {
        self.recovering.unwrap_or(UNLIMITED)
    }

    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }

    fn initial_window(&self) -> u64 {
        UNLIMITED
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}

#[derive(Debug)]
pub struct DeferringControllerFactory;

impl ControllerFactory for DeferringControllerFactory {
    fn build(self: Arc<Self>, _now: Instant, current_mtu: u16) -> Box<dyn Controller> {
        Box::new(DeferringController::new(current_mtu))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaves_the_window_and_the_pacer_open_through_ordinary_loss() {
        let mut controller = DeferringController::new(1200);
        assert!(controller.window() > u64::from(u32::MAX), "noq paces any window up to u32::MAX");
        controller.congested(false);
        assert_eq!(controller.window(), UNLIMITED);
    }

    #[test]
    fn slow_starts_from_two_packets_after_persistent_congestion_then_steps_aside() {
        let mut controller = DeferringController::new(1200);
        controller.congested(true);
        assert_eq!(controller.window(), 2_400);

        controller.acked(2_400);
        assert_eq!(controller.window(), 4_800);

        controller.acked(RECOVERED);
        assert_eq!(controller.window(), UNLIMITED);
    }

    #[test]
    fn a_larger_path_mtu_raises_the_recovery_floor() {
        let mut controller = DeferringController::new(1200);
        controller.congested(true);
        controller.on_mtu_update(1452);
        assert_eq!(controller.window(), 2_904);
    }
}
