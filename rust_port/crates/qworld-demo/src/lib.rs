//! Demo file parsers for the three formats quake.world serves:
//!
//! - **QWD** — `QuakeWorld` single-stream demo. Just a sequence of
//!   server packets prefixed with view angles.
//! - **MVD** — Multi-View Demo. Adds a layer above QWD to encode
//!   multiple viewers/POVs, with sub-message routing (`dem_cmd`,
//!   `dem_read`, `dem_multiple`, etc.).
//! - **NQ .dem** — `NetQuake` demo. Different message-type set than
//!   QW (uses `svc_*` codes; some shared, some NQ-only).
//!
//! Reference notes:
//! - `.claude/notes/demo_event_extraction_by_format.md` (parent repo)
//! - `.claude/notes/nq_demo_event_extraction_tiers.md`
//! - `.claude/notes/qwd_demo_event_extraction_tiers.md`

pub mod mvd;
pub mod nq;
pub mod qwd;
pub mod svc;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum DemoError {
    #[error("binrw error: {0}")]
    BinRw(#[from] binrw::Error),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("unknown svc code: {0}")]
    UnknownSvc(u8),

    #[error("malformed demo: {0}")]
    Malformed(String),
}

/// What kind of demo a byte stream looks like, based on a peek.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DemoFormat {
    Nq,
    Qwd,
    Mvd,
}

/// Best-effort sniff of the demo format from the first few bytes.
///
/// - NQ .dem starts with an ASCII CD track number ("-1\n" or
///   "0\n", "1\n" ...) followed by binary message blocks.
/// - QWD/MVD start with a packet length (u32 LE) — usually small.
///   We can't fully distinguish without more context, so default to
///   QWD; callers should use file extension when available.
#[must_use]
pub fn sniff(bytes: &[u8]) -> Option<DemoFormat> {
    if bytes.len() < 4 {
        return None;
    }
    // NQ: leading ASCII track digit then '\n'
    if let Some(nl) = bytes.iter().take(8).position(|&b| b == b'\n')
        && bytes[..nl].iter().all(|b| b.is_ascii_digit() || *b == b'-')
    {
        return Some(DemoFormat::Nq);
    }
    // QWD/MVD: undistinguishable from header alone; assume QWD.
    Some(DemoFormat::Qwd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_nq_track_prefix() {
        assert_eq!(sniff(b"-1\n\x00\x00\x00\x00"), Some(DemoFormat::Nq));
        assert_eq!(sniff(b"3\nbinarydata"), Some(DemoFormat::Nq));
    }

    #[test]
    fn sniffs_qwd_default_for_non_nq() {
        assert_eq!(sniff(&[0x10, 0, 0, 0, 0xFF]), Some(DemoFormat::Qwd));
    }
}
