use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

const MEMORY: Duration = Duration::from_millis(500);
const MIN_SPAN: Duration = Duration::from_millis(5);

#[derive(Debug, Clone, Copy)]
struct Sighting {
    at: Instant,
    position: u64,
    carried: u64,
}

#[derive(Debug, Default)]
pub struct Arrived {
    seen: VecDeque<Sighting>,
    lost: u64,
}

impl Arrived {
    pub fn restart(&mut self, at: Instant, position: u64) {
        self.seen.clear();
        self.seen.push_back(Sighting { at, position, carried: position.saturating_sub(self.lost) });
    }

    pub fn note(&mut self, at: Instant, position: u64, lost_behind: u64) {
        if self.seen.back().is_some_and(|newest| position <= newest.position) {
            return;
        }
        while self.seen.len() > 1 && at.saturating_duration_since(self.seen[1].at) > MEMORY {
            self.seen.pop_front();
        }
        if let Some(oldest) = self.seen.front_mut() {
            oldest.at = oldest.at.min(at);
        }
        let carried = position.saturating_sub(self.lost.saturating_add(lost_behind));
        self.seen.push_back(Sighting { at, position, carried });
    }

    pub fn note_lost(&mut self, bytes: u64) {
        self.lost = self.lost.saturating_add(bytes);
    }

    pub fn reached(&self, now: Instant, known_bps: Option<f64>) -> Option<u64> {
        let newest = self.seen.back()?;
        let since = now.saturating_duration_since(newest.at);
        let carried = self.rate(known_bps)? / 8.0 * since.as_secs_f64();
        Some(newest.position.saturating_add(carried as u64))
    }

    pub fn wait_for(&self, now: Instant, position: u64, known_bps: Option<f64>) -> Option<Duration> {
        let ahead = position.saturating_sub(self.reached(now, known_bps)?);
        Some(Duration::from_secs_f64(ahead as f64 * 8.0 / self.rate(known_bps)?))
    }

    fn rate(&self, known_bps: Option<f64>) -> Option<f64> {
        [self.bps(), known_bps].into_iter().flatten().reduce(f64::max).filter(|bps| *bps >= 1.0)
    }

    fn bps(&self) -> Option<f64> {
        let (oldest, newest) = (self.seen.front()?, self.seen.back()?);
        let span = newest.at.checked_duration_since(oldest.at).filter(|span| *span >= MIN_SPAN)?;
        Some(newest.carried.saturating_sub(oldest.carried) as f64 * 8.0 / span.as_secs_f64())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);

    #[test]
    fn nothing_seen_or_one_sighting_gives_no_reach() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        assert_eq!(arrived.reached(start, None), None);
        arrived.restart(start, 1_000);
        assert_eq!(arrived.reached(start + 50 * MS, None), None);
        assert_eq!(arrived.wait_for(start + 50 * MS, 50_000, None), None);
    }

    #[test]
    fn the_reach_grows_at_the_rate_the_sightings_advanced() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500, 0);
        assert_eq!(arrived.reached(start + 100 * MS, None), Some(12_500));
        assert_eq!(arrived.reached(start + 300 * MS, None), Some(37_500));
    }

    #[test]
    fn the_wait_for_a_position_is_what_is_ahead_of_it_at_the_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500, 0);
        assert_eq!(arrived.wait_for(start + 100 * MS, 50_000, None), Some(300 * MS));
        assert_eq!(arrived.wait_for(start + 300 * MS, 50_000, None), Some(100 * MS));
        assert_eq!(arrived.wait_for(start + 900 * MS, 50_000, None), Some(Duration::ZERO));
        assert_eq!(arrived.wait_for(start + 100 * MS, 50_000, Some(3e6)), Some(100 * MS));
    }

    #[test]
    fn a_rate_known_from_elsewhere_is_used_when_it_is_higher() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        assert_eq!(arrived.reached(start + 100 * MS, Some(8e6)), Some(100_000));
        arrived.note(start + 100 * MS, 12_500, 0);
        assert_eq!(arrived.reached(start + 200 * MS, Some(8e6)), Some(112_500));
        assert_eq!(arrived.reached(start + 200 * MS, Some(8e3)), Some(25_000));
    }

    #[test]
    fn two_sightings_moments_apart_dont_set_the_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 20 * Duration::from_micros(1), 12_000, 0);
        assert_eq!(arrived.reached(start + 100 * MS, None), None);

        arrived.note(start + 100 * MS, 12_500, 0);
        arrived.note(start + 100 * MS + 20 * Duration::from_micros(1), 25_000, 0);
        let reached = arrived.reached(start + 200 * MS, None).expect("two sightings 100 ms apart");
        assert!((49_000..=51_000).contains(&reached), "{reached}");
    }

    #[test]
    fn a_sighting_that_doesnt_advance_is_ignored_and_old_ones_fall_away_but_one() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 10_000, 0);
        arrived.note(start + 200 * MS, 10_000, 0);
        assert_eq!(arrived.reached(start + 200 * MS, None), Some(20_000));
        arrived.note(start + 900 * MS, 20_000, 0);
        arrived.note(start + 1_000 * MS, 22_500, 0);
        assert_eq!(arrived.seen.len(), 3);
        assert_eq!(arrived.reached(start + 1_100 * MS, None), Some(23_888), "12.5 KB in the 0.9 s it still remembers");
    }

    #[test]
    fn a_restart_forgets_the_idle_time_before_it() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 10_000, 0);
        arrived.restart(start + 5_000 * MS, 10_000);
        arrived.note(start + 5_010 * MS, 20_000, 0);
        assert_eq!(arrived.reached(start + 5_020 * MS, None), Some(30_000));
    }

    #[test]
    fn a_sighting_before_the_restarts_time_moves_the_restart_back_to_it() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start + 100 * MS, 0);
        arrived.note(start + 62 * MS, 5_000, 0);
        assert_eq!(arrived.reached(start + 70 * MS, None), None);

        arrived.note(start + 105 * MS, 12_500, 0);
        assert_eq!(arrived.reached(start + 105 * MS + 43 * MS, None), Some(25_000), "12.5 KB in 43 ms, not in 5");
    }

    #[test]
    fn lost_packets_dont_count_towards_the_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500, 0);
        arrived.note_lost(100_000);
        arrived.note(start + 200 * MS, 125_000, 0);
        assert_eq!(arrived.reached(start + 300 * MS, None), Some(137_500), "the link still carries 1 Mbit/s");
    }

    #[test]
    fn losses_behind_a_sighting_reported_with_it_dont_count_either() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 112_500, 100_000);
        arrived.note_lost(100_000);
        assert_eq!(arrived.reached(start + 200 * MS, None), Some(125_000));
        arrived.note(start + 200 * MS, 125_000, 0);
        assert_eq!(arrived.reached(start + 300 * MS, None), Some(137_500));
    }

    #[test]
    fn more_reported_lost_than_sent_gives_no_rate_instead_of_wrapping() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note_lost(u64::MAX);
        arrived.note_lost(768_000);
        arrived.note(start + 100 * MS, 12_000, 5_000);
        assert_eq!(arrived.reached(start + 200 * MS, None), None);
        assert_eq!(arrived.reached(start + 200 * MS, Some(1e6)), Some(24_500));
    }
}
