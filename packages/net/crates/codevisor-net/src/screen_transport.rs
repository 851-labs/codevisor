use std::{
    any::Any,
    sync::Arc,
    time::{Duration, Instant},
};

use iroh::endpoint::{AckFrequencyConfig, Controller, ControllerFactory, QuicTransportConfig, RttEstimator};

pub const DATAGRAM_SEND_BUFFER: usize = 256 * 1024;
pub const DATAGRAM_RECEIVE_BUFFER: usize = 2 * 1024 * 1024;
pub const INITIAL_RTT: Duration = Duration::from_millis(100);
pub const ACK_ELICITING_THRESHOLD: u32 = 32;
pub const MAX_ACK_DELAY: Duration = Duration::from_millis(2);

pub fn transport_config() -> QuicTransportConfig {
    QuicTransportConfig::builder()
        .congestion_controller_factory(Arc::new(DeferringControllerFactory))
        .datagram_send_buffer_size(DATAGRAM_SEND_BUFFER)
        .datagram_receive_buffer_size(Some(DATAGRAM_RECEIVE_BUFFER))
        .initial_rtt(INITIAL_RTT)
        .ack_frequency_config(Some(ack_frequency()))
        .build()
}

fn ack_frequency() -> AckFrequencyConfig {
    let mut config = AckFrequencyConfig::default();
    config.ack_eliciting_threshold(ACK_ELICITING_THRESHOLD.into()).max_ack_delay(Some(MAX_ACK_DELAY));
    config
}

const UNPACED_WINDOW: u64 = 1 << 40;
const RECOVERED_WINDOW: u64 = 256 * 1024;

#[derive(Debug, Clone)]
pub struct DeferringController {
    mtu: u64,
    slow_start_window: Option<u64>,
}

impl DeferringController {
    fn new(mtu: u16) -> Self {
        Self { mtu: mtu.into(), slow_start_window: None }
    }

    fn minimum_window(&self) -> u64 {
        2 * self.mtu
    }

    fn acked(&mut self, bytes: u64) {
        if let Some(window) = self.slow_start_window {
            let window = window + bytes;
            self.slow_start_window = (window < RECOVERED_WINDOW).then_some(window);
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
        if is_persistent_congestion {
            self.slow_start_window = Some(self.minimum_window());
        }
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu.into();
        let minimum = self.minimum_window();
        if let Some(window) = &mut self.slow_start_window {
            *window = (*window).max(minimum);
        }
    }

    fn window(&self) -> u64 {
        self.slow_start_window.unwrap_or(UNPACED_WINDOW)
    }

    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }

    fn initial_window(&self) -> u64 {
        UNPACED_WINDOW
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

    fn congestion(controller: &mut DeferringController, persistent: bool) {
        let now = Instant::now();
        controller.on_congestion_event(now, now, persistent, false, 120_000, 100);
    }

    #[test]
    fn leaves_the_window_and_the_pacer_open_through_ordinary_loss() {
        let mut controller = DeferringController::new(1200);
        assert!(controller.window() > u64::from(u32::MAX), "noq paces any window up to u32::MAX");
        congestion(&mut controller, false);
        assert_eq!(controller.window(), UNPACED_WINDOW);
    }

    #[test]
    fn slow_starts_from_two_packets_after_persistent_congestion_then_steps_aside() {
        let mut controller = DeferringController::new(1200);
        congestion(&mut controller, true);
        assert_eq!(controller.window(), 2_400);

        controller.acked(2_400);
        assert_eq!(controller.window(), 4_800);

        controller.acked(RECOVERED_WINDOW);
        assert_eq!(controller.window(), UNPACED_WINDOW);
    }
}
