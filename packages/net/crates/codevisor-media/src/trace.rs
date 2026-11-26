use std::{io::Write, sync::OnceLock, time::Instant};

static START: OnceLock<Instant> = OnceLock::new();

pub fn enabled() -> bool {
    true
}

pub fn log(now: Instant, line: std::fmt::Arguments<'_>) {
    let start = *START.get_or_init(|| now);
    let t = now.saturating_duration_since(start).as_micros();
    let text = line.to_string();
    if text.starts_with("D ") || text.starts_with("P ") || text.starts_with("W ") {
        return;
    }
    let _ = writeln!(std::io::stderr().lock(), "MT {t} {text}");
}

pub fn init_logging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new("noq_proto=debug"))
            .with_writer(std::io::stderr)
            .with_ansi(false)
            .try_init();
    });
}
