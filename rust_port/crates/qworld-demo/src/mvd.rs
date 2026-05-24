//! MVD (Multi-View Demo) parser.
//!
//! MVD is a superset of QWD where each block is tagged with a
//! demo-message type that routes the payload to specific recipients
//! (single client, multiple clients, all clients) or carries
//! engine-side commands. See FTE's `engine/client/cl_demo.c` for the
//! full message-type set.
//!
//! Initial scaffold — full implementation defers to net protocol.

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MvdMessageType {
    Cmd = 0,
    Read = 1,
    Set = 2,
    Multiple = 3,
    Single = 4,
    Stats = 5,
    All = 6,
}

#[derive(Debug, Error)]
pub enum MvdError {
    #[error("unknown mvd message type: {0}")]
    UnknownType(u8),
}

impl TryFrom<u8> for MvdMessageType {
    type Error = MvdError;
    fn try_from(v: u8) -> Result<Self, MvdError> {
        Ok(match v {
            0 => Self::Cmd,
            1 => Self::Read,
            2 => Self::Set,
            3 => Self::Multiple,
            4 => Self::Single,
            5 => Self::Stats,
            6 => Self::All,
            _ => return Err(MvdError::UnknownType(v)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_codes_map() {
        assert_eq!(MvdMessageType::try_from(0).unwrap(), MvdMessageType::Cmd);
        assert_eq!(MvdMessageType::try_from(6).unwrap(), MvdMessageType::All);
        assert!(MvdMessageType::try_from(99).is_err());
    }
}
