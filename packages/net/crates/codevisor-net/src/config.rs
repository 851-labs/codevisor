//! Endpoint configuration. Production and local development differ only in
//! these values (relay URLs, trust anchors, path policy) — never in code.

use std::str::FromStr;

use anyhow::{Context, Result, anyhow, bail};
use rustls_pki_types::{CertificateDer, pem::PemObject};

/// Which transports an endpoint may use. `Auto` is the only production value;
/// the others exist so development and tests can force each path (e.g. the
/// Dev Cloud machine runs `RelayOnly` so a relayed machine always exists).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PathPolicy {
    #[default]
    Auto,
    RelayOnly,
    DirectOnly,
}

impl FromStr for PathPolicy {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "auto" | "" => Ok(Self::Auto),
            "relay-only" => Ok(Self::RelayOnly),
            "direct-only" => Ok(Self::DirectOnly),
            other => bail!("unknown path policy {other:?} (expected auto, relay-only or direct-only)"),
        }
    }
}

/// One relay the endpoint may home on and dial through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelaySpec {
    pub url: String,
    /// UDP port of the relay's QUIC address discovery (QAD). `None` uses
    /// iroh's default (7842); local development allocates per-worktree ports.
    pub quic_port: Option<u16>,
}

#[derive(Debug, Clone)]
pub struct NetConfig {
    /// Ed25519 secret key (32 bytes); its public half is the endpoint id.
    pub secret_key: [u8; 32],
    pub relays: Vec<RelaySpec>,
    /// Extra PEM trust anchors on top of the compiled-in Mozilla roots. Empty
    /// in production (relays use Let's Encrypt); local dev passes its CA.
    pub trust_anchors_pem: Vec<String>,
    /// UDP socket addresses to bind (e.g. `0.0.0.0:41641`, `[::]:41641`).
    /// Empty keeps iroh's defaults (all interfaces, OS-chosen port). A fixed
    /// port lets operators write one firewall/port-forward rule.
    pub bind_addrs: Vec<String>,
    pub path_policy: PathPolicy,
    /// ALPNs this endpoint accepts. Dialing works for any ALPN.
    pub alpns: Vec<Vec<u8>>,
}

impl NetConfig {
    pub(crate) fn trust_anchors(&self) -> Result<Vec<CertificateDer<'static>>> {
        let mut anchors = Vec::new();
        for pem in &self.trust_anchors_pem {
            for cert in CertificateDer::pem_slice_iter(pem.as_bytes()) {
                anchors.push(cert.context("invalid PEM trust anchor")?);
            }
        }
        if !self.trust_anchors_pem.is_empty() && anchors.is_empty() {
            return Err(anyhow!("trust anchor PEM contained no certificates"));
        }
        Ok(anchors)
    }
}

/// Parses a secret key from its 64-char hex form.
pub fn secret_key_from_hex(hex_key: &str) -> Result<[u8; 32]> {
    let bytes = hex::decode(hex_key.trim()).context("secret key is not hex")?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("secret key must be 32 bytes"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_policy_parses_the_configured_spellings() {
        assert_eq!("auto".parse::<PathPolicy>().unwrap(), PathPolicy::Auto);
        assert_eq!("".parse::<PathPolicy>().unwrap(), PathPolicy::Auto);
        assert_eq!("relay-only".parse::<PathPolicy>().unwrap(), PathPolicy::RelayOnly);
        assert_eq!("direct-only".parse::<PathPolicy>().unwrap(), PathPolicy::DirectOnly);
        assert!("relay".parse::<PathPolicy>().is_err());
    }

    #[test]
    fn rejects_pem_without_certificates() {
        let config = NetConfig {
            secret_key: [7; 32],
            relays: vec![],
            trust_anchors_pem: vec!["not a certificate".into()],
            bind_addrs: vec![],
            path_policy: PathPolicy::Auto,
            alpns: vec![],
        };
        assert!(config.trust_anchors().is_err());
    }
}

/// The 64-char hex form of a secret key (how it is persisted).
pub fn secret_key_hex(key: &[u8; 32]) -> String {
    hex::encode(key)
}
