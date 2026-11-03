use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

use crate::windowed::{Keep, Windowed};

const BURST_WINDOW: Duration = Duration::from_secs(10);
const RECEIVE_WINDOW: Duration = Duration::from_millis(500);
const DELAY_WINDOW: Duration = Duration::from_secs(10);
const QUEUE_THRESHOLD: Duration = Duration::from_millis(2);
const JITTER_THRESHOLD_GAIN: f64 = 4.0;
const JITTER_GAIN: f64 = 1.0 / 16.0;
const TRUSTED_SPAN_JITTERS: f64 = 2.0;
const OVERUSE_SAMPLES: u32 = 2;
const BACKOFF: f64 = 0.85;
const MAX_BACKOFF: f64 = 0.5;
const CAP_GROWTH_PER_SECOND: f64 = 0.25;
const MIN_SPAN: Duration = Duration::from_micros(100);
const MIN_SAMPLE_BYTES: usize = 2400;
const MIN_RATE_BPS: f64 = 300e3;
const RECENT_DELAYS: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Delivery {
    pub bytes: usize,
    pub receive_span: Duration,
    pub send_span: Duration,
}

#[derive(Debug, Clone, Copy)]
struct Cap {
    from_bps: f64,
    since: Instant,
    bps: f64,
}

#[derive(Debug)]
pub struct Estimator {
    initial_bps: f64,
    max_bps: f64,
    bursts: Windowed<f64>,
    acked: VecDeque<(Instant, usize)>,
    acked_bytes: usize,
    cap: Option<Cap>,
    base_delay: Windowed<i64>,
    recent_delays: VecDeque<i64>,
    last_delay: Option<i64>,
    delay_before: Option<i64>,
    jitter_us: f64,
    queue_delay_us: i64,
    overuse: u32,
    last_backoff: Option<Instant>,
}

impl Estimator {
    pub fn new(initial_bps: f64, max_bps: f64) -> Self {
        Self {
            initial_bps: initial_bps.clamp(MIN_RATE_BPS, max_bps),
            max_bps,
            bursts: Windowed::new(BURST_WINDOW, Keep::Largest),
            acked: VecDeque::new(),
            acked_bytes: 0,
            cap: None,
            base_delay: Windowed::new(DELAY_WINDOW, Keep::Smallest),
            recent_delays: VecDeque::new(),
            last_delay: None,
            delay_before: None,
            jitter_us: 0.0,
            queue_delay_us: 0,
            overuse: 0,
            last_backoff: None,
        }
    }

    pub fn estimate_bps(&self) -> f64 {
        let estimate = match (self.cap, self.bursts.best(), self.receive_bps()) {
            (Some(cap), ..) => cap.bps,
            (None, Some(burst), receive) => burst.max(receive.unwrap_or(0.0)),
            (None, None, receive) => receive.unwrap_or(0.0).max(self.initial_bps),
        };
        estimate.clamp(MIN_RATE_BPS, self.max_bps)
    }

    pub fn measured(&self) -> bool {
        self.last_delay.is_some() || !self.bursts.is_empty()
    }

    pub fn queue_delay_us(&self) -> i64 {
        self.queue_delay_us
    }

    pub fn receive_bps(&self) -> Option<f64> {
        let (oldest, oldest_bytes) = *self.acked.front()?;
        let newest = self.acked.back()?.0;
        let span = newest.saturating_duration_since(oldest);
        if span < RECEIVE_WINDOW / 4 {
            return None;
        }
        Some((self.acked_bytes - oldest_bytes) as f64 * 8.0 / span.as_secs_f64())
    }

    fn queue_threshold_us(&self) -> f64 {
        QUEUE_THRESHOLD.as_micros() as f64 + JITTER_THRESHOLD_GAIN * self.jitter_us
    }

    fn queued(&self) -> bool {
        self.overuse > 0 || (self.queue_delay_us as f64) >= self.queue_threshold_us()
    }

    pub fn on_acked(&mut self, now: Instant, bytes: usize) {
        while self.acked.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > RECEIVE_WINDOW) {
            let (_, old) = self.acked.pop_front().expect("checked above");
            self.acked_bytes -= old;
        }
        self.acked.push_back((now, bytes));
        self.acked_bytes += bytes;
    }

    pub fn on_delivery(&mut self, now: Instant, delivery: Delivery) {
        let trusted = Duration::from_secs_f64(TRUSTED_SPAN_JITTERS * self.jitter_us / 1e6).max(MIN_SPAN);
        if delivery.receive_span >= trusted && delivery.bytes >= MIN_SAMPLE_BYTES {
            let span = delivery.receive_span.max(delivery.send_span);
            self.bursts.push(now, delivery.bytes as f64 * 8.0 / span.as_secs_f64());
        }
        self.grow_cap(now);
    }

    pub fn on_delay(&mut self, now: Instant, one_way_us: i64, hold_off: Duration) {
        if let (Some(last), Some(before)) = (self.last_delay, self.delay_before) {
            let curvature = (one_way_us - 2 * last + before).abs() as f64 / 2.0;
            self.jitter_us += JITTER_GAIN * (curvature - self.jitter_us);
        }
        self.delay_before = self.last_delay;
        self.last_delay = Some(one_way_us);
        if self.recent_delays.len() == RECENT_DELAYS {
            self.recent_delays.pop_front();
        }
        self.recent_delays.push_back(one_way_us);
        let recent = self.recent_delays.iter().min().copied().unwrap_or(one_way_us);
        self.base_delay.push(now, recent);
        let queue = recent - self.base_delay.best().unwrap_or(recent);
        let growing = queue > self.queue_delay_us;
        self.queue_delay_us = queue;
        if (queue as f64) < self.queue_threshold_us() {
            self.overuse = 0;
        } else if growing {
            self.overuse += 1;
        }
        let rested = self.last_backoff.is_none_or(|at| now.saturating_duration_since(at) >= hold_off);
        if self.overuse >= OVERUSE_SAMPLES && rested {
            self.back_off(now);
        }
        self.grow_cap(now);
    }

    fn back_off(&mut self, now: Instant) {
        let estimate = self.estimate_bps();
        let receive = self.receive_bps().unwrap_or(estimate);
        let target = (receive * BACKOFF).clamp(estimate * MAX_BACKOFF, estimate * BACKOFF).max(MIN_RATE_BPS);
        self.cap = Some(Cap { from_bps: target, since: now, bps: target });
        self.bursts.clear();
        self.overuse = 0;
        self.last_backoff = Some(now);
    }

    fn grow_cap(&mut self, now: Instant) {
        let queued = self.queued();
        let Some(cap) = self.cap.as_mut() else {
            return;
        };
        if queued {
            *cap = Cap { from_bps: cap.bps, since: now, bps: cap.bps };
            return;
        }
        let elapsed = now.saturating_duration_since(cap.since).as_secs_f64();
        cap.bps = cap.from_bps * (1.0 + CAP_GROWTH_PER_SECOND * elapsed);
        if self.bursts.best().is_some_and(|burst| cap.bps >= burst) || cap.bps >= self.max_bps {
            self.cap = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);
    const OFFSET: i64 = 5_000_000;

    fn burst(bytes: usize, span: Duration) -> Delivery {
        Delivery { bytes, receive_span: span, send_span: Duration::ZERO }
    }

    fn feed_delays(estimator: &mut Estimator, start: Instant, delays: impl IntoIterator<Item = i64>) -> Vec<f64> {
        delays
            .into_iter()
            .enumerate()
            .map(|(index, delay)| {
                estimator.on_delay(start + 4 * MS * index as u32, OFFSET + delay, 20 * MS);
                estimator.estimate_bps()
            })
            .collect()
    }

    #[test]
    fn estimate_is_the_fastest_recent_delivery_and_forgets_old_ones() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9);
        estimator.on_delivery(start, burst(125_000, 10 * MS));
        estimator.on_delivery(start + 5_000 * MS, burst(125_000, 20 * MS));
        assert_eq!(estimator.estimate_bps(), 100e6);
        estimator.on_delivery(start + 10_100 * MS, burst(125_000, 20 * MS));
        assert_eq!(estimator.estimate_bps(), 50e6);
        estimator.on_delivery(start + 10_200 * MS, burst(125_000, Duration::from_micros(50)));
        estimator.on_delivery(start + 10_200 * MS, burst(2_000, 10 * MS));
        assert_eq!(estimator.estimate_bps(), 50e6, "too short to time, or too small");
    }

    #[test]
    fn a_burst_counts_no_faster_than_it_was_sent() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9);
        estimator.on_delivery(start, Delivery { bytes: 125_000, receive_span: MS, send_span: 10 * MS });
        assert_eq!(estimator.estimate_bps(), 100e6);
    }

    #[test]
    fn the_estimate_is_never_under_what_the_viewer_received() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9);
        estimator.on_delivery(start, burst(12_500, 10 * MS));
        for index in 0..=10 {
            estimator.on_acked(start + 20 * MS * index, 50_000);
        }
        assert_eq!(estimator.estimate_bps(), 20e6);
    }

    #[test]
    fn a_growing_queue_backs_off_once_per_hold_off() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9);
        let estimates = feed_delays(&mut estimator, start, (0..16).map(|_| 0).chain((1..=15).map(|step| step * 2_000)));

        assert_eq!(estimates[23], 100e6, "the queue isn't in every recent sample yet");
        assert_eq!(estimates[24], 100e6, "the queue has to grow twice");
        assert_eq!(estimates[25], 85e6);
        assert_eq!(estimates[29], 85e6, "still inside the hold-off");
        assert_eq!(estimates[30], 85e6 * 0.85);
    }

    #[test]
    fn jitter_raises_the_queue_a_back_off_needs() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9);
        let jitter = (0..200).map(|index| if index % 2 == 0 { 0 } else { 3_000 });
        let estimates = feed_delays(&mut estimator, start, jitter.chain((1..=10).map(|step| 3_000 + step * 1_000)));

        assert_eq!(estimates.last(), Some(&100e6), "a 10 ms queue is within 4 jitters of 3 ms");
    }

    #[test]
    fn a_back_off_goes_under_the_receive_rate_and_holds_until_the_queue_clears() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9);
        estimator.on_delivery(start, burst(125_000, 10 * MS));
        for index in 0..=10 {
            estimator.on_acked(start + 20 * MS * index, 150_000);
        }
        let estimates = feed_delays(&mut estimator, start, (0..16).map(|_| 0).chain((1..=10).map(|step| step * 2_000)));
        assert_eq!(estimates.last(), Some(&(60e6 * 0.85)));

        estimator.on_delivery(start + 200 * MS, burst(125_000, 5 * MS));
        assert_eq!(estimator.estimate_bps(), 60e6 * 0.85, "a fast burst doesn't lift the cap");
        let cleared = (0..8).map(|_| 0);
        let later = start + Duration::from_secs(1);
        for (index, delay) in cleared.enumerate() {
            estimator.on_delay(later + 4 * MS * index as u32, OFFSET + delay, 20 * MS);
        }
        estimator.on_delivery(later + Duration::from_secs(2), burst(125_000, 5 * MS));
        let grown = estimator.estimate_bps();
        let expected = 60e6 * 0.85 * (1.0 + 0.25 * 2.8);
        assert!((grown - expected).abs() < 1e3, "a quarter a second since the queue cleared at 0.2 s: {grown}");
        estimator.on_delivery(later + Duration::from_secs(13), burst(125_000, 5 * MS));
        assert_eq!(estimator.estimate_bps(), 200e6, "and lets go once it passes the bursts");
    }
}
