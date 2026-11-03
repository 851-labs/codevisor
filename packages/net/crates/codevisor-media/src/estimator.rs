use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

const RATE_WINDOW: Duration = Duration::from_secs(1);
const DELAY_WINDOW: Duration = Duration::from_secs(10);
const QUEUE_THRESHOLD: Duration = Duration::from_millis(2);
const OVERUSE_SAMPLES: u32 = 2;
const BACKOFF: f64 = 0.85;
const MIN_SPAN: Duration = Duration::from_micros(100);
const MIN_RATE_BPS: f64 = 500e3;
const RECENT_DELAYS: usize = 8;

#[derive(Debug)]
pub struct Estimator {
    estimate_bps: f64,
    max_bps: f64,
    samples: VecDeque<(Instant, f64)>,
    min_delay: VecDeque<(Instant, i64)>,
    recent_delays: VecDeque<i64>,
    queue_delay_us: i64,
    overuse: u32,
    last_backoff: Option<Instant>,
}

impl Estimator {
    pub fn new(initial_bps: f64, max_bps: f64) -> Self {
        Self {
            estimate_bps: initial_bps.clamp(MIN_RATE_BPS, max_bps),
            max_bps,
            samples: VecDeque::new(),
            min_delay: VecDeque::new(),
            recent_delays: VecDeque::new(),
            queue_delay_us: 0,
            overuse: 0,
            last_backoff: None,
        }
    }

    pub fn estimate_bps(&self) -> f64 {
        self.estimate_bps
    }

    pub fn queue_delay_us(&self) -> i64 {
        self.queue_delay_us
    }

    pub fn on_delivery(&mut self, now: Instant, bytes: usize, span: Duration) {
        if span < MIN_SPAN || bytes == 0 {
            return;
        }
        let rate = bytes as f64 * 8.0 / span.as_secs_f64();
        while self.samples.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > RATE_WINDOW) {
            self.samples.pop_front();
        }
        self.samples.push_back((now, rate));
        let max = self.samples.iter().map(|(_, rate)| *rate).fold(0.0, f64::max);
        self.estimate_bps = max.clamp(MIN_RATE_BPS, self.max_bps);
    }

    pub fn on_delay(&mut self, now: Instant, one_way_us: i64, hold_off: Duration) {
        while self.min_delay.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > DELAY_WINDOW) {
            self.min_delay.pop_front();
        }
        while self.min_delay.back().is_some_and(|(_, delay)| *delay >= one_way_us) {
            self.min_delay.pop_back();
        }
        self.min_delay.push_back((now, one_way_us));
        if self.recent_delays.len() == RECENT_DELAYS {
            self.recent_delays.pop_front();
        }
        self.recent_delays.push_back(one_way_us);
        let base = self.min_delay.front().map_or(one_way_us, |(_, delay)| *delay);
        let queue = self.recent_delays.iter().min().copied().unwrap_or(one_way_us) - base;
        let growing = queue > self.queue_delay_us;
        self.queue_delay_us = queue;
        if queue < QUEUE_THRESHOLD.as_micros() as i64 {
            self.overuse = 0;
            return;
        }
        if growing {
            self.overuse += 1;
        }
        let rested = self.last_backoff.is_none_or(|at| now.saturating_duration_since(at) >= hold_off);
        if self.overuse >= OVERUSE_SAMPLES && rested {
            self.estimate_bps = (self.estimate_bps * BACKOFF).max(MIN_RATE_BPS);
            self.samples.clear();
            self.overuse = 0;
            self.last_backoff = Some(now);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);

    #[test]
    fn estimate_is_the_fastest_recent_delivery_and_forgets_old_ones() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9);
        estimator.on_delivery(start, 125_000, 10 * MS);
        estimator.on_delivery(start + 500 * MS, 125_000, 20 * MS);
        assert_eq!(estimator.estimate_bps(), 100e6);
        estimator.on_delivery(start + 1100 * MS, 125_000, 20 * MS);
        assert_eq!(estimator.estimate_bps(), 50e6);
        estimator.on_delivery(start + 1200 * MS, 125_000, Duration::from_micros(50));
        assert_eq!(estimator.estimate_bps(), 50e6, "too short to time");
    }

    #[test]
    fn only_a_queue_every_recent_sample_sees_backs_off_once_per_hold_off() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9);
        let offset = 5_000_000;
        let delays =
            (0..16).map(|index| if index % 2 == 0 { 0 } else { 5_000 }).chain((1..=14).map(|step| 2_000 + step * 500));
        let mut estimates = Vec::new();
        for (index, delay) in delays.enumerate() {
            estimator.on_delay(start + 4 * MS * index as u32, offset + delay, 20 * MS);
            estimates.push(estimator.estimate_bps());
        }

        assert_eq!(estimates[15], 100e6, "jitter alone");
        assert_eq!(estimates[23], 100e6, "the queue isn't in every recent sample yet");
        assert_eq!(estimates[24], 85e6);
        assert_eq!(estimates[28], 85e6, "still inside the hold-off");
        assert_eq!(estimates[29], 85e6 * 0.85);
    }
}
