use std::str::FromStr;

use anyhow::{Context, Result, anyhow, bail};
use rustls_pki_types::{CertificateDer, pem::PemObject};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PathPolicy {
    #[default]
    Auto,
    RelayOnly,
    DirectOnly,
    DirectPinned,
}

impl FromStr for PathPolicy {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "auto" | "" => Ok(Self::Auto),
            "relay-only" => Ok(Self::RelayOnly),
            "direct-only" => Ok(Self::DirectOnly),
            "direct-pinned" => Ok(Self::DirectPinned),
            other => bail!("unknown path policy {other:?} (expected auto, relay-only, direct-only or direct-pinned)"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelaySpec {
    pub url: String,
    pub quic_port: Option<u16>,
}

#[derive(Debug, Clone)]
pub struct NetConfig {
    pub secret_key: [u8; 32],
    pub relays: Vec<RelaySpec>,
    pub trust_anchors_pem: Vec<String>,
    pub bind_addrs: Vec<String>,
    pub path_policy: PathPolicy,
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
        assert_eq!("direct-pinned".parse::<PathPolicy>().unwrap(), PathPolicy::DirectPinned);
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

pub fn secret_key_hex(key: &[u8; 32]) -> String {
    hex::encode(key)
}
