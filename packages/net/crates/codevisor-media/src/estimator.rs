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
const FILLING_SHARE: f64 = 0.5;
const CAP_IDLE: Duration = Duration::from_millis(250);
const CAP_DOUBLING: Duration = Duration::from_secs(1);
const LINK_LIMITED: f64 = 0.75;
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
    grown_at: Instant,
    bps: f64,
}

#[derive(Debug)]
pub struct Estimator {
    initial_bps: f64,
    max_bps: f64,
    bursts: Windowed<f64>,
    acked: Throughput,
    sent: Throughput,
    cap: Option<Cap>,
    base_delay: Windowed<i64>,
    recent_delays: VecDeque<i64>,
    last_delay: Option<i64>,
    delay_before: Option<i64>,
    jitter_us: f64,
    queue_delay_us: i64,
    standing_us: i64,
    max_standing_us: f64,
    overuse: u32,
    last_backoff: Option<Instant>,
    first_sent: Option<Instant>,
    bytes_sent: usize,
}

impl Estimator {
    pub fn new(initial_bps: f64, max_bps: f64, max_standing: Duration) -> Self {
        Self {
            max_standing_us: max_standing.as_micros() as f64,
            initial_bps: initial_bps.clamp(MIN_RATE_BPS, max_bps),
            max_bps,
            bursts: Windowed::new(BURST_WINDOW, Keep::Largest),
            acked: Throughput::default(),
            sent: Throughput::default(),
            cap: None,
            base_delay: Windowed::new(DELAY_WINDOW, Keep::Smallest),
            recent_delays: VecDeque::new(),
            last_delay: None,
            delay_before: None,
            jitter_us: 0.0,
            queue_delay_us: 0,
            standing_us: 0,
            overuse: 0,
            last_backoff: None,
            first_sent: None,
            bytes_sent: 0,
        }
    }

    pub fn estimate_bps(&self) -> f64 {
        let estimate = match (self.cap, self.bursts.best(), self.receive_bps()) {
            (Some(cap), ..) => cap.bps,
            (None, Some(burst), receive) => burst.max(receive.unwrap_or(0.0)),
            (None, None, Some(receive)) if self.link_limited(receive) => receive,
            (None, None, receive) => receive.unwrap_or(0.0).max(self.initial_bps),
        };
        estimate.clamp(MIN_RATE_BPS, self.max_bps)
    }

    pub fn measured(&self) -> bool {
        !self.bursts.is_empty() || self.receive_bps().is_some()
    }

    pub fn queue_delay_us(&self) -> i64 {
        self.queue_delay_us
    }

    pub fn receive_bps(&self) -> Option<f64> {
        self.acked.bps()
    }

    fn link_limited(&self, receive_bps: f64) -> bool {
        self.sent.bps().is_some_and(|sent| receive_bps < sent * LINK_LIMITED)
    }

    fn queue_threshold_us(&self) -> f64 {
        QUEUE_THRESHOLD.as_micros() as f64 + JITTER_THRESHOLD_GAIN * self.jitter_us
    }

    fn queued(&self) -> bool {
        let threshold = self.queue_threshold_us();
        ((self.queue_delay_us - self.standing_us) as f64) >= threshold
            || (self.queue_delay_us as f64) >= self.max_standing_us + threshold
    }

    pub fn on_acked(&mut self, now: Instant, bytes: usize) {
        self.acked.push(now, bytes);
    }

    pub fn on_sent(&mut self, now: Instant, bytes: usize) {
        self.sent.push(now, bytes);
        self.first_sent.get_or_insert(now);
        self.bytes_sent += bytes;
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
            self.standing_us = 0;
        } else if growing {
            self.overuse += 1;
        }
        let rested = self.last_backoff.is_none_or(|at| now.saturating_duration_since(at) >= hold_off);
        let threshold = self.queue_threshold_us();
        let grown = self.overuse >= OVERUSE_SAMPLES && ((queue - self.standing_us) as f64) >= threshold;
        let standing_too_long = (queue as f64) >= self.max_standing_us + threshold;
        if rested && (grown || standing_too_long) {
            self.back_off(now);
        }
        self.grow_cap(now);
    }

    pub fn on_heavy_loss(&mut self, now: Instant, loss: f64) {
        let estimate = self.estimate_bps();
        let target = self.heavy_loss_target(now, estimate, loss).max(MIN_RATE_BPS);
        self.cap = Some(Cap { from_bps: target, since: now, grown_at: now, bps: target });
        self.bursts.clear();
        self.last_backoff = Some(now);
    }

    fn heavy_loss_target(&self, now: Instant, estimate: f64, loss: f64) -> f64 {
        if let Some(delivered) = self.delivered_before_any_measurement(now, loss) {
            return (delivered * BACKOFF).min(estimate);
        }
        let carried = self.acked.bps_until(now).map_or(0.0, |receive| receive * BACKOFF);
        (estimate * (1.0 - loss / 2.0)).max(carried).min(estimate)
    }

    fn delivered_before_any_measurement(&self, now: Instant, loss: f64) -> Option<f64> {
        if self.last_backoff.is_some() || self.measured() {
            return None;
        }
        let elapsed = now.saturating_duration_since(self.first_sent?);
        (elapsed >= RECEIVE_WINDOW).then(|| self.bytes_sent as f64 * 8.0 / elapsed.as_secs_f64() * (1.0 - loss))
    }

    fn back_off(&mut self, now: Instant) {
        let estimate = self.estimate_bps();
        let receive = self.acked.bps_until(now).or_else(|| self.acked.bps()).unwrap_or(estimate);
        let filling = receive >= estimate * FILLING_SHARE;
        let link_limited = self.link_limited(receive);
        let from = if filling || link_limited { receive.min(estimate) } else { estimate };
        let target = (from * BACKOFF).max(MIN_RATE_BPS);
        self.cap = Some(Cap { from_bps: target, since: now, grown_at: now, bps: target });
        self.standing_us = self.queue_delay_us;
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
            *cap = Cap { from_bps: cap.bps, since: now, grown_at: now, bps: cap.bps };
            return;
        }
        let quiet = now.saturating_duration_since(cap.grown_at).saturating_sub(CAP_IDLE);
        cap.since += quiet;
        cap.grown_at = now;
        let elapsed = now.saturating_duration_since(cap.since).as_secs_f64();
        cap.bps = cap.from_bps * 2f64.powf(elapsed / CAP_DOUBLING.as_secs_f64());
        if self.bursts.best().is_some_and(|burst| cap.bps >= burst) || cap.bps >= self.max_bps {
            self.cap = None;
        }
    }
}

#[derive(Debug, Default)]
struct Throughput {
    entries: VecDeque<(Instant, usize)>,
    bytes: usize,
}

impl Throughput {
    fn push(&mut self, now: Instant, bytes: usize) {
        while self.entries.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > RECEIVE_WINDOW) {
            let (_, old) = self.entries.pop_front().expect("checked above");
            self.bytes -= old;
        }
        self.entries.push_back((now, bytes));
        self.bytes += bytes;
    }

    fn bps(&self) -> Option<f64> {
        let (oldest, oldest_bytes) = *self.entries.front()?;
        let span = self.entries.back()?.0.saturating_duration_since(oldest);
        (span >= RECEIVE_WINDOW / 4).then(|| (self.bytes - oldest_bytes) as f64 * 8.0 / span.as_secs_f64())
    }

    fn bps_until(&self, now: Instant) -> Option<f64> {
        let mut recent = self
            .entries
            .iter()
            .filter(|(at, _)| *at <= now && now.saturating_duration_since(*at) <= RECEIVE_WINDOW)
            .peekable();
        let oldest = recent.peek()?.0;
        let bytes: usize = recent.skip(1).map(|(_, bytes)| bytes).sum();
        let span = now.saturating_duration_since(oldest);
        (span >= RECEIVE_WINDOW / 4).then(|| bytes as f64 * 8.0 / span.as_secs_f64())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);
    const FRAME: Duration = Duration::from_micros(16_667);
    const OFFSET: i64 = 5_000_000;

    fn burst(bytes: usize, span: Duration) -> Delivery {
        Delivery { bytes, receive_span: span, send_span: Duration::ZERO }
    }

    fn feed_traffic(
        estimator: &mut Estimator,
        start: Instant,
        delays: impl IntoIterator<Item = i64>,
        acked: usize,
        sent: usize,
    ) -> Vec<f64> {
        delays
            .into_iter()
            .enumerate()
            .map(|(index, delay)| {
                let at = start + 4 * MS * index as u32;
                estimator.on_acked(at, acked);
                estimator.on_sent(at, sent);
                estimator.on_delay(at, OFFSET + delay, 20 * MS);
                estimator.estimate_bps()
            })
            .collect()
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
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
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
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
        estimator.on_delivery(start, Delivery { bytes: 125_000, receive_span: MS, send_span: 10 * MS });
        assert_eq!(estimator.estimate_bps(), 100e6);
    }

    #[test]
    fn the_estimate_is_never_under_what_the_viewer_received() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
        estimator.on_delivery(start, burst(12_500, 10 * MS));
        for index in 0..=10 {
            estimator.on_acked(start + 20 * MS * index, 50_000);
        }
        assert_eq!(estimator.estimate_bps(), 20e6);
    }

    #[test]
    fn a_growing_queue_backs_off_once_per_hold_off() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9, FRAME);
        let estimates = feed_delays(&mut estimator, start, (0..16).map(|_| 0).chain((1..=15).map(|step| step * 2_000)));

        assert_eq!(estimates[23], 100e6, "the queue isn't in every recent sample yet");
        assert_eq!(estimates[24], 100e6, "the queue has to grow twice");
        assert_eq!(estimates[25], 85e6);
        assert!((85e6..85e6 * 1.01).contains(&estimates[29]), "no second back-off inside the hold-off");
        assert_eq!(estimates[30], estimates[29] * 0.85, "the queue grew again, so it backs off again");
    }

    #[test]
    fn a_standing_delay_backs_off_once_and_lets_the_cap_grow() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9, FRAME);
        let standing = (0..200).map(|index| 5_000 + (index % 50) * 10);
        let estimates = feed_delays(&mut estimator, start, (0..16).map(|_| 0).chain(standing));

        let lowest = estimates.iter().copied().fold(f64::MAX, f64::min);
        assert_eq!(lowest, 85e6, "one back-off for a delay that stopped growing");
        assert!(estimates.last().is_some_and(|last| *last > 85e6 * 1.5), "{:?}", estimates.last());
    }

    #[test]
    fn a_back_off_while_sending_little_only_takes_fifteen_percent() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
        estimator.on_delivery(start, burst(125_000, 10 * MS));
        for index in 0..=10 {
            estimator.on_acked(start + 20 * MS * index, 25_000);
        }
        let estimates = feed_delays(&mut estimator, start, (0..16).map(|_| 0).chain((1..=10).map(|step| step * 2_000)));
        assert_eq!(estimates.last(), Some(&85e6), "a 10 Mbit/s receive rate is the sender's choice, not the link's");
    }

    #[test]
    fn a_back_off_while_sending_more_than_arrives_goes_under_what_arrived() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
        estimator.on_delivery(start, burst(125_000, 10 * MS));
        let delays = (0..40).map(|_| 0).chain((1..=10).map(|step| step * 2_000));
        let estimates = feed_traffic(&mut estimator, start, delays, 5_000, 20_000);
        assert_eq!(estimates.last(), Some(&(10e6 * 0.85)), "the link carried 10 of the 40 Mbit/s sent");
    }

    #[test]
    fn heavy_loss_backs_off_by_half_the_loss_but_not_under_what_arrived() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
        estimator.on_delivery(start, burst(125_000, 10 * MS));
        for index in 0..=10 {
            estimator.on_acked(start + 20 * MS * index, 150_000);
        }
        estimator.on_heavy_loss(start + 200 * MS, 0.4);
        assert_eq!(estimator.estimate_bps(), 80e6);
        estimator.on_heavy_loss(start + 200 * MS, 1.0);
        assert_eq!(estimator.estimate_bps(), 60e6 * 0.85, "the link still carried 60 Mbit/s");
    }

    #[test]
    fn heavy_loss_before_anything_is_measured_cuts_from_what_was_sent_not_the_initial_guess() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9, FRAME);
        estimator.on_sent(start, 125_000);

        estimator.on_heavy_loss(start + 1_000 * MS, 0.2);

        assert!((estimator.estimate_bps() - 1e6 * 0.8 * BACKOFF).abs() < 1.0, "{}", estimator.estimate_bps());
    }

    #[test]
    fn jitter_raises_the_queue_a_back_off_needs() {
        let start = Instant::now();
        let mut estimator = Estimator::new(100e6, 1e9, FRAME);
        let jitter = (0..200).map(|index| if index % 2 == 0 { 0 } else { 3_000 });
        let estimates = feed_delays(&mut estimator, start, jitter.chain((1..=10).map(|step| 3_000 + step * 1_000)));

        assert_eq!(estimates.last(), Some(&100e6), "a 10 ms queue is within 4 jitters of 3 ms");
    }

    #[test]
    fn a_back_off_goes_under_the_receive_rate_and_holds_until_the_queue_clears() {
        let start = Instant::now();
        let mut estimator = Estimator::new(10e6, 1e9, FRAME);
        estimator.on_delivery(start, burst(125_000, 10 * MS));
        let delays = (0..40).map(|_| 0).chain((1..=10).map(|step| step * 2_000));
        let estimates = feed_traffic(&mut estimator, start, delays, 30_000, 30_000);
        let backed_off = estimates.iter().position(|estimate| *estimate < 100e6).expect("a back-off");
        assert_eq!(estimates[backed_off], 60e6 * 0.85, "85% of the 60 Mbit/s that arrived");

        let after = start + 4 * MS * backed_off as u32;
        estimator.on_delivery(after + 50 * MS, burst(125_000, 5 * MS));
        assert!(estimator.estimate_bps() < 60e6 * 0.85 * 1.1, "a fast burst doesn't lift the cap");

        let quiet = after + Duration::from_secs(5);
        estimator.on_delivery(quiet, burst(125_000, 5 * MS));
        let woken = estimator.estimate_bps();
        assert!(woken < 60e6 * 0.85 * 2f64.powf(0.5), "a quiet 5 s counts as a quarter second: {woken}");

        for step in 1..=40 {
            estimator.on_delivery(quiet + 100 * MS * step, burst(125_000, 5 * MS));
        }
        assert_eq!(estimator.estimate_bps(), 200e6, "steady feedback lets the cap grow past the bursts and go");
    }
}
