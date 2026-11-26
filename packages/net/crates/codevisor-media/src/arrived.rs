use std::{
    cmp::Reverse,
    collections::{BinaryHeap, VecDeque},
    time::{Duration, Instant},
};

const MEMORY: Duration = Duration::from_millis(500);
const MAX_LOST_AHEAD: usize = 4096;

#[derive(Debug, Default)]
pub struct Arrived {
    position: u64,
    carried: VecDeque<(Instant, u64)>,
    lost_behind: u64,
    lost_ahead: BinaryHeap<Reverse<(u64, usize)>>,
    lost_ahead_bytes: u64,
}

impl Arrived {
    pub fn restart(&mut self, at: Instant, position: u64) {
        *self = Self { position, ..Self::default() };
        self.carried.push_back((at, position));
    }

    pub fn note(&mut self, at: Instant, position: u64) {
        if position <= self.position {
            return;
        }
        self.position = position;
        while let Some(&Reverse((_, bytes))) = self.lost_ahead.peek().filter(|lost| lost.0.0 <= position) {
            self.lost_ahead.pop();
            self.lost_behind += bytes as u64;
            self.lost_ahead_bytes -= bytes as u64;
        }
        while self.carried.len() > 1 && at.saturating_duration_since(self.carried[1].0) > MEMORY {
            self.carried.pop_front();
        }
        self.carried.push_back((at, position - self.lost_behind));
    }

    pub fn note_lost(&mut self, position: u64, bytes: usize) {
        if position <= self.position {
            return;
        }
        self.lost_ahead.push(Reverse((position, bytes)));
        self.lost_ahead_bytes += bytes as u64;
        if self.lost_ahead.len() > MAX_LOST_AHEAD
            && let Some(Reverse((_, oldest))) = self.lost_ahead.pop()
        {
            self.lost_ahead_bytes -= oldest as u64;
        }
    }

    pub fn reached(&self, now: Instant, known_bps: Option<f64>) -> Option<u64> {
        let &(at, _) = self.carried.back()?;
        let since = now.saturating_duration_since(at);
        let carried = self.rate(known_bps)? / 8.0 * since.as_secs_f64();
        Some(self.position + self.lost_ahead_bytes + carried as u64)
    }

    pub fn wait_for(&self, now: Instant, position: u64, known_bps: Option<f64>) -> Option<Duration> {
        let ahead = position.saturating_sub(self.reached(now, known_bps)?);
        Some(Duration::from_secs_f64(ahead as f64 * 8.0 / self.rate(known_bps)?))
    }

    fn rate(&self, known_bps: Option<f64>) -> Option<f64> {
        [self.bps(), known_bps].into_iter().flatten().reduce(f64::max).filter(|bps| *bps >= 1.0)
    }

    fn bps(&self) -> Option<f64> {
        let &(newest_at, newest) = self.carried.back()?;
        let rates = self.carried.iter().filter_map(|&(at, carried)| {
            let span = newest_at.checked_duration_since(at).filter(|span| !span.is_zero())?;
            Some((newest - carried) as f64 * 8.0 / span.as_secs_f64())
        });
        rates.reduce(f64::max)
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
    }

    #[test]
    fn the_reach_grows_at_the_rate_the_sightings_advanced() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500);
        assert_eq!(arrived.reached(start + 100 * MS, None), Some(12_500));
        assert_eq!(arrived.reached(start + 300 * MS, None), Some(37_500));
    }

    #[test]
    fn a_burst_after_a_slow_stretch_sets_the_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 400 * MS, 10_000);
        arrived.note(start + 410 * MS, 110_000);
        assert_eq!(arrived.reached(start + 420 * MS, None), Some(210_000));
    }

    #[test]
    fn a_rate_known_from_elsewhere_is_used_when_it_is_higher() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        assert_eq!(arrived.reached(start + 100 * MS, Some(8e6)), Some(100_000));
        arrived.note(start + 100 * MS, 12_500);
        assert_eq!(arrived.reached(start + 200 * MS, Some(8e6)), Some(112_500));
        assert_eq!(arrived.reached(start + 200 * MS, Some(8e3)), Some(25_000));
    }

    #[test]
    fn a_sighting_that_doesnt_advance_is_ignored_and_old_ones_fall_away_but_one() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 10_000);
        arrived.note(start + 200 * MS, 10_000);
        assert_eq!(arrived.reached(start + 200 * MS, None), Some(20_000));
        arrived.note(start + 900 * MS, 20_000);
        arrived.note(start + 1_000 * MS, 22_500);
        assert_eq!(arrived.carried.len(), 3);
        assert_eq!(arrived.reached(start + 1_100 * MS, None), Some(25_000));
    }

    #[test]
    fn a_restart_forgets_the_idle_time_before_it() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 10_000);
        arrived.restart(start + 5_000 * MS, 10_000);
        arrived.note(start + 5_010 * MS, 20_000);
        assert_eq!(arrived.reached(start + 5_020 * MS, None), Some(30_000));
    }

    #[test]
    fn packets_known_lost_take_no_time_to_pass_and_dont_count_towards_the_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500);
        for packet in 0..100 {
            arrived.note_lost(13_500 + packet * 1_000, 1_000);
        }
        assert_eq!(arrived.reached(start + 100 * MS, None), Some(112_500));
        assert_eq!(arrived.reached(start + 200 * MS, None), Some(125_000));

        arrived.note(start + 200 * MS, 125_000);
        assert_eq!(arrived.reached(start + 300 * MS, None), Some(137_500), "the rate is still 1 Mbit/s");
    }

    #[test]
    fn the_wait_for_a_position_is_what_is_ahead_of_it_at_the_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        assert_eq!(arrived.wait_for(start, 50_000, None), None);
        arrived.note(start + 100 * MS, 12_500);
        assert_eq!(arrived.wait_for(start + 100 * MS, 50_000, None), Some(300 * MS));
        assert_eq!(arrived.wait_for(start + 300 * MS, 50_000, None), Some(100 * MS));
        assert_eq!(arrived.wait_for(start + 900 * MS, 50_000, None), Some(Duration::ZERO));
        assert_eq!(arrived.wait_for(start + 100 * MS, 50_000, Some(3e6)), Some(100 * MS));
    }

    #[test]
    fn sightings_that_only_pass_lost_packets_give_no_rate() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note_lost(1_000, 1_000);
        arrived.note(start + 100 * MS, 1_000);
        assert_eq!(arrived.reached(start + 200 * MS, None), None);
        assert_eq!(arrived.wait_for(start + 200 * MS, 50_000, None), None);
    }

    #[test]
    fn losses_ahead_are_remembered_up_to_a_limit() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500);
        for packet in 0..2 * MAX_LOST_AHEAD as u64 {
            arrived.note_lost(13_500 + packet * 1_000, 1_000);
        }
        assert_eq!(arrived.lost_ahead.len(), MAX_LOST_AHEAD);
        assert_eq!(arrived.reached(start + 100 * MS, None), Some(12_500 + MAX_LOST_AHEAD as u64 * 1_000));
    }

    #[test]
    fn a_loss_reported_behind_the_reach_changes_nothing() {
        let start = Instant::now();
        let mut arrived = Arrived::default();
        arrived.restart(start, 0);
        arrived.note(start + 100 * MS, 12_500);
        arrived.note_lost(5_000, 1_000);
        assert_eq!(arrived.reached(start + 200 * MS, None), Some(25_000));
    }
}
