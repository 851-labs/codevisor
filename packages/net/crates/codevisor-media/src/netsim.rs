//! The benchmark's emulated network (Tier 1's `BenchNetworkModel` in `ScreenSharingBench`, ported): seeded
//! Gilbert loss, a rate-limited link with an optional packet queue, and Gaussian delay jitter. The deterministic tests
//! and the bench's impaired transport both use it, so a seed gives the same losses in both.

use std::time::Duration;

/// The N0–N7 network conditions of the benchmark design (851-3582).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetworkConditions {
    pub id: &'static str,
    pub delay_ms: f64,
    pub delay_sd_ms: f64,
    pub loss_percent: f64,
    pub average_burst_loss: Option<u32>,
    pub capacity_kbps: Option<u64>,
    pub queue_packets: Option<usize>,
}

impl NetworkConditions {
    const NONE: Self = Self {
        id: "N0",
        delay_ms: 0.0,
        delay_sd_ms: 0.0,
        loss_percent: 0.0,
        average_burst_loss: None,
        capacity_kbps: None,
        queue_packets: None,
    };
    pub const N0: Self = Self::NONE;
    pub const N1: Self = Self { id: "N1", delay_ms: 1.0, capacity_kbps: Some(1_000_000), ..Self::NONE };
    pub const N2: Self = Self {
        id: "N2",
        delay_ms: 5.0,
        delay_sd_ms: 3.0,
        loss_percent: 0.5,
        capacity_kbps: Some(200_000),
        ..Self::NONE
    };
    pub const N3: Self =
        Self { id: "N3", delay_ms: 1.0, loss_percent: 1.0, capacity_kbps: Some(1_000_000), ..Self::NONE };
    pub const N4: Self = Self { id: "N4", average_burst_loss: Some(5), ..Self::N3 };
    pub const N5: Self =
        Self { id: "N5", delay_ms: 10.0, capacity_kbps: Some(30_000), queue_packets: Some(30), ..Self::NONE };
    pub const N6: Self = Self {
        id: "N6",
        delay_ms: 25.0,
        delay_sd_ms: 5.0,
        loss_percent: 0.1,
        capacity_kbps: Some(50_000),
        ..Self::NONE
    };
    pub const N7: Self = Self { id: "N7", delay_ms: 50.0, loss_percent: 5.0, capacity_kbps: Some(1_000), ..Self::NONE };
    pub const ALL: [Self; 8] = [Self::N0, Self::N1, Self::N2, Self::N3, Self::N4, Self::N5, Self::N6, Self::N7];

    pub fn by_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|conditions| conditions.id.eq_ignore_ascii_case(id))
    }
}

#[derive(Debug, Clone)]
pub struct SplitMix64(u64);

impl SplitMix64 {
    pub fn new(seed: u64) -> Self {
        Self(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    pub fn next_unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }
}

/// Independent loss, or Gilbert bursts with the given mean length.
#[derive(Debug, Clone)]
struct LossModel {
    continue_burst: f64,
    start_burst: f64,
    random: SplitMix64,
    bursting: bool,
}

impl LossModel {
    fn new(loss_percent: f64, average_burst: Option<u32>, seed: u64) -> Self {
        let loss = loss_percent / 100.0;
        assert!((0.0..1.0).contains(&loss), "loss must be at least 0% and below 100%");
        let (continue_burst, start_burst) = match average_burst {
            None => (loss, loss),
            Some(length) => {
                let length = f64::from(length);
                assert!(length > (loss / (1.0 - loss)).ceil(), "bursts too short for this loss rate");
                (1.0 - 1.0 / length, loss / (1.0 - loss) / length)
            }
        };
        Self { continue_burst, start_burst, random: SplitMix64::new(seed), bursting: false }
    }

    fn drops_next(&mut self) -> bool {
        let probability = if self.bursting { self.continue_burst } else { self.start_burst };
        self.bursting = self.random.next_unit() < probability;
        self.bursting
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fate {
    /// Arrives this long after the model's epoch.
    Delivered(Duration),
    Lost,
    QueueOverflow,
}

/// One direction of an emulated link. Times are offsets from an epoch the caller picks.
#[derive(Debug, Clone)]
pub struct NetworkModel {
    pub conditions: NetworkConditions,
    loss: LossModel,
    jitter: SplitMix64,
    departures: std::collections::VecDeque<Duration>,
    link_free: Duration,
    last_arrival: Duration,
}

const JITTER_SEED_SALT: u64 = 0xA5A5_5A5A_C3C3_3C3C;

impl NetworkModel {
    pub fn new(conditions: NetworkConditions, seed: u64) -> Self {
        Self {
            conditions,
            loss: LossModel::new(conditions.loss_percent, conditions.average_burst_loss, seed),
            jitter: SplitMix64::new(seed ^ JITTER_SEED_SALT),
            departures: Default::default(),
            link_free: Duration::ZERO,
            last_arrival: Duration::ZERO,
        }
    }

    /// What happens to a `bytes`-long packet sent at `sent`. Arrivals never reorder.
    pub fn send(&mut self, bytes: usize, sent: Duration) -> Fate {
        let lost = self.loss.drops_next();
        while self.departures.front().is_some_and(|departure| *departure <= sent) {
            self.departures.pop_front();
        }
        if self.conditions.queue_packets.is_some_and(|length| self.departures.len() >= length) {
            return Fate::QueueOverflow;
        }
        let serialization = self
            .conditions
            .capacity_kbps
            .map_or(Duration::ZERO, |kbps| Duration::from_nanos(bytes as u64 * 8 * 1_000_000 / kbps));
        self.link_free = self.link_free.max(sent) + serialization;
        if self.conditions.queue_packets.is_some() {
            self.departures.push_back(self.link_free);
        }
        if lost {
            return Fate::Lost;
        }
        self.last_arrival = (self.link_free + self.delay()).max(self.last_arrival);
        Fate::Delivered(self.last_arrival)
    }

    fn delay(&mut self) -> Duration {
        let mut delay_ms = self.conditions.delay_ms;
        if self.conditions.delay_sd_ms > 0.0 {
            let radius = (-2.0 * (1.0 - self.jitter.next_unit()).ln()).sqrt();
            delay_ms +=
                self.conditions.delay_sd_ms * radius * (2.0 * std::f64::consts::PI * self.jitter.next_unit()).cos();
        }
        Duration::from_secs_f64(delay_ms.max(0.0) / 1000.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_mix_matches_the_swift_bench_sequence() {
        // The first outputs of SplitMix64 seeded with 0, the reference values every implementation shares.
        let mut random = SplitMix64::new(0);
        assert_eq!(random.next_u64(), 0xE220_A839_7B1D_CDAF);
        assert_eq!(random.next_u64(), 0x6E78_9E6A_A1B9_65F4);
    }

    #[test]
    fn link_serializes_packets_at_capacity_and_overflows_its_queue() {
        let conditions = NetworkConditions {
            id: "test",
            delay_ms: 1.0,
            capacity_kbps: Some(8_000),
            queue_packets: Some(2),
            ..NetworkConditions::N0
        };
        let mut model = NetworkModel::new(conditions, 1);
        // 1000 bytes at 8 Mbit/s take 1 ms on the wire, then 1 ms of delay.
        assert_eq!(model.send(1000, Duration::ZERO), Fate::Delivered(Duration::from_millis(2)));
        assert_eq!(model.send(1000, Duration::ZERO), Fate::Delivered(Duration::from_millis(3)));
        assert_eq!(model.send(1000, Duration::ZERO), Fate::QueueOverflow);
        assert_eq!(model.send(1000, Duration::from_millis(1)), Fate::Delivered(Duration::from_millis(4)));
    }

    #[test]
    fn loss_rate_and_bursts_follow_the_conditions() {
        for (conditions, expected_runs) in [(NetworkConditions::N3, 1.0..1.1), (NetworkConditions::N4, 4.5..5.5)] {
            let mut model = NetworkModel::new(conditions, 42);
            let fates: Vec<bool> = (0..1_000_000).map(|_| model.send(1200, Duration::ZERO) == Fate::Lost).collect();
            let lost = fates.iter().filter(|lost| **lost).count();
            let runs = fates.windows(2).filter(|pair| !pair[0] && pair[1]).count();
            let rate = lost as f64 / fates.len() as f64;
            assert!((0.009..0.011).contains(&rate), "{}: {rate}", conditions.id);
            assert!(expected_runs.contains(&(lost as f64 / runs as f64)), "{}", conditions.id);
        }
    }
}
