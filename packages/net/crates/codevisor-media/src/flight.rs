use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

use crate::estimator::Delivery;

const MAX_OPEN: usize = 64;

#[derive(Debug, Clone, Copy)]
pub struct Arrival {
    pub first_tx: Instant,
    pub latest_tx: Option<Instant>,
    pub first_rx_us: u64,
    pub last_rx_us: u64,
    pub original_bytes: usize,
    pub first_packet_bytes: usize,
}

#[derive(Debug, Default)]
struct Flight {
    pending: usize,
    reported: usize,
    first_tx: Option<Instant>,
    latest_tx: Option<Instant>,
    first_rx_us: u64,
    first_packet_bytes: usize,
    last_rx_us: u64,
    bytes: usize,
}

#[derive(Debug, Default)]
pub struct Flights {
    current: Option<(u64, Instant)>,
    next: u64,
    open: BTreeMap<u64, Flight>,
}

impl Flights {
    pub fn join(&mut self, now: Instant, gap: Duration) -> u64 {
        let id = match self.current {
            Some((id, opened)) if now.saturating_duration_since(opened) <= gap => id,
            _ => {
                let id = self.next;
                self.next += 1;
                self.current = Some((id, now));
                id
            }
        };
        let flight = self.open.entry(id).or_insert_with(|| Flight { first_rx_us: u64::MAX, ..Flight::default() });
        flight.pending += 1;
        while self.open.len() > MAX_OPEN {
            self.open.pop_first();
        }
        id
    }

    pub fn report(&mut self, id: u64, arrival: Option<Arrival>) -> Option<Delivery> {
        let flight = self.open.get_mut(&id)?;
        flight.pending -= 1;
        if let Some(arrival) = arrival {
            flight.reported += 1;
            flight.first_tx = Some(flight.first_tx.map_or(arrival.first_tx, |at| at.min(arrival.first_tx)));
            flight.latest_tx = flight.latest_tx.max(arrival.latest_tx);
            if arrival.first_rx_us < flight.first_rx_us {
                flight.first_rx_us = arrival.first_rx_us;
                flight.first_packet_bytes = arrival.first_packet_bytes;
            }
            flight.last_rx_us = flight.last_rx_us.max(arrival.last_rx_us);
            flight.bytes += arrival.original_bytes + arrival.first_packet_bytes;
        }
        if flight.pending > 0 {
            return None;
        }
        let flight = self.open.remove(&id)?;
        if flight.reported < 2 {
            return None;
        }
        let first_tx = flight.first_tx?;
        Some(Delivery {
            bytes: flight.bytes - flight.first_packet_bytes,
            receive_span: Duration::from_micros(flight.last_rx_us.saturating_sub(flight.first_rx_us)),
            send_span: flight.latest_tx.map_or(Duration::ZERO, |latest| latest.saturating_duration_since(first_tx)),
        })
    }
}
