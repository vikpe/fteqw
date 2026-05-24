//! Q1 BSP loader.
//!
//! Supports both vanilla **BSP v29** (id1, 16-bit edge/face indices)
//! and **BSP2** (modern `QuakeWorld` custom maps, 32-bit indices). The
//! two share the 15-lump directory layout; only the edge + face record
//! widths differ. In-memory types are always BSP2-shaped; V29 widens
//! on read.
//!
//! Reference: <https://www.gamers.org/dEngine/quake/QDP/qmapspec.html>

pub mod entity;
pub mod geom;
pub mod header;
pub mod lumps;
pub mod texture;

use std::io;
use thiserror::Error;

pub use header::{BspHeader, BspVersion, BSP_MAGIC_BSP2, BSP_MAGIC_V29};
pub use lumps::Lump;

#[derive(Debug, Error)]
pub enum BspError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),

    #[error("unsupported BSP magic: {0:#x} (expected {v29:#x} or {bsp2:#x})",
        v29 = BSP_MAGIC_V29, bsp2 = BSP_MAGIC_BSP2)]
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
    pub fn version(&self) -> BspVersion {
        self.header.version
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

    /// Raw bytes of the lighting lump. Each face's `lightofs` is a
    /// byte offset into this slice; lightmap dimensions are derived
    /// from the face's texinfo + surface extents by the renderer.
    #[must_use]
    pub fn lighting_bytes(&self) -> &[u8] {
        self.lump_bytes(Lump::Lighting)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a header-only BSP file for the given 4-byte magic.
    fn make_header_bytes(magic: u32) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(4 + Lump::COUNT * 8);
        bytes.extend_from_slice(&magic.to_le_bytes());
        for _ in 0..Lump::COUNT {
            bytes.extend_from_slice(&0u32.to_le_bytes()); // offset
            bytes.extend_from_slice(&0u32.to_le_bytes()); // length
        }
        bytes
    }

    #[test]
    fn rejects_unknown_magic() {
        let bytes = make_header_bytes(42);
        let err = Bsp::from_bytes(bytes).unwrap_err();
        assert!(matches!(err, BspError::UnsupportedVersion(42)));
    }

    #[test]
    fn accepts_v29_magic() {
        let bytes = make_header_bytes(BSP_MAGIC_V29);
        let bsp = Bsp::from_bytes(bytes).unwrap();
        assert_eq!(bsp.version(), BspVersion::V29);
        assert_eq!(bsp.entities_str().unwrap(), "");
        assert!(bsp.lighting_bytes().is_empty());
    }

    #[test]
    fn accepts_bsp2_magic() {
        let bytes = make_header_bytes(BSP_MAGIC_BSP2);
        let bsp = Bsp::from_bytes(bytes).unwrap();
        assert_eq!(bsp.version(), BspVersion::Bsp2);
    }
}
