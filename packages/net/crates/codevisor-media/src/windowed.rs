use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keep {
    Smallest,
    Largest,
}

#[derive(Debug)]
pub struct Windowed<T> {
    window: Duration,
    keep: Keep,
    entries: VecDeque<(Instant, T)>,
}

impl<T: PartialOrd + Copy> Windowed<T> {
    pub fn new(window: Duration, keep: Keep) -> Self {
        Self { window, keep, entries: VecDeque::new() }
    }

    pub fn push(&mut self, now: Instant, value: T) {
        while self.entries.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > self.window) {
            self.entries.pop_front();
        }
        let keep = self.keep;
        while self.entries.back().is_some_and(|(_, kept)| match keep {
            Keep::Smallest => *kept >= value,
            Keep::Largest => *kept <= value,
        }) {
            self.entries.pop_back();
        }
        self.entries.push_back((now, value));
    }

    pub fn best(&self) -> Option<T> {
        self.entries.front().map(|(_, value)| *value)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn expire(&mut self, now: Instant) {
        while self.entries.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > self.window) {
            self.entries.pop_front();
        }
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_extreme_of_the_window() {
        let start = Instant::now();
        let second = Duration::from_secs(1);
        let mut largest = Windowed::new(2 * second, Keep::Largest);
        let mut smallest = Windowed::new(2 * second, Keep::Smallest);
        for (offset, value) in [(0, 5), (1, 3), (2, 4), (3, 1)] {
            largest.push(start + second * offset, value);
            smallest.push(start + second * offset, value);
        }
        assert_eq!(largest.best(), Some(4), "5 is over 2 s old");
        assert_eq!(smallest.best(), Some(1));
    }
}
