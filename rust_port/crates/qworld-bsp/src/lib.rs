//! Q1 BSP loader.
//!
//! Supports BSP version 29 (vanilla id1). Future work:
//! BSP2 (modern QW maps) — see BSPX extensions in
//! `specs/bspx.txt` of the parent repo.
//!
//! Reference: <https://www.gamers.org/dEngine/quake/QDP/qmapspec.html>

pub mod entity;
pub mod geom;
pub mod header;
pub mod lumps;

use std::io;
use thiserror::Error;

pub use header::{BspHeader, BSP_VERSION_Q1};
pub use lumps::Lump;

#[derive(Debug, Error)]
pub enum BspError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),

    #[error("unsupported BSP version: {0} (expected {expected})", expected = BSP_VERSION_Q1)]
    UnsupportedVersion(u32),

    #[error("lump {0:?} out of bounds: offset {1}, length {2}, file size {3}")]
    LumpOutOfBounds(Lump, u32, u32, u64),

    #[error("malformed entity lump: {0}")]
    EntityParse(String),
}

/// A parsed BSP file (lumps not yet decoded — call type-specific loaders).
#[derive(Debug)]
pub struct Bsp {
    pub header: BspHeader,
    pub raw: Vec<u8>,
}

impl Bsp {
    pub fn from_bytes(raw: Vec<u8>) -> Result<Self, BspError> {
        let header = BspHeader::parse(&raw)?;
        if header.version != BSP_VERSION_Q1 {
            return Err(BspError::UnsupportedVersion(header.version));
        }
        let file_size = raw.len() as u64;
        for lump in Lump::ALL {
            let dir = header.dir[lump as usize];
            if u64::from(dir.offset) + u64::from(dir.length) > file_size {
                return Err(BspError::LumpOutOfBounds(
                    lump, dir.offset, dir.length, file_size,
                ));
            }
        }
        Ok(Self { header, raw })
    }

    #[must_use] 
    pub fn lump_bytes(&self, lump: Lump) -> &[u8] {
        let dir = self.header.dir[lump as usize];
        &self.raw[dir.offset as usize..(dir.offset + dir.length) as usize]
    }

    /// Convenience: get the entity string (lump 0).
    pub fn entities_str(&self) -> Result<&str, BspError> {
        let bytes = self.lump_bytes(Lump::Entities);
        let nul = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
        std::str::from_utf8(&bytes[..nul]).map_err(|e| BspError::EntityParse(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_header(version: u32) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(4 + Lump::COUNT * 8);
        bytes.extend_from_slice(&version.to_le_bytes());
        for _ in 0..Lump::COUNT {
            bytes.extend_from_slice(&0u32.to_le_bytes()); // offset
            bytes.extend_from_slice(&0u32.to_le_bytes()); // length
        }
        bytes
    }

    #[test]
    fn rejects_wrong_version() {
        let bytes = make_header(42);
        let err = Bsp::from_bytes(bytes).unwrap_err();
        assert!(matches!(err, BspError::UnsupportedVersion(42)));
    }

    #[test]
    fn accepts_q1_version_with_empty_lumps() {
        let bytes = make_header(BSP_VERSION_Q1);
        let bsp = Bsp::from_bytes(bytes).unwrap();
        assert_eq!(bsp.header.version, BSP_VERSION_Q1);
        // Entities lump is empty, so entities_str returns ""
        assert_eq!(bsp.entities_str().unwrap(), "");
    }
}
