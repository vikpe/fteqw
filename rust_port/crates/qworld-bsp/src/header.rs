//! BSP header, version detection, and lump directory.

use byteorder::{LittleEndian, ReadBytesExt};
use std::fmt;
use std::io::Cursor;

use crate::{BspError, Lump};

/// Vanilla Q1 BSP magic (a literal `u32` 29, written little-endian).
pub const BSP_MAGIC_V29: u32 = 29;

/// BSP2 magic: the four ASCII bytes `BSP2`.
pub const BSP_MAGIC_BSP2: u32 = u32::from_le_bytes(*b"BSP2");

/// Number of lumps in a Q1 BSP. Both V29 and BSP2 share this layout.
pub const NUM_LUMPS: usize = 15;

/// Which on-disk BSP format the file is in. Vanilla id1 maps are
/// [`V29`](BspVersion::V29); modern QW maps with extended counts are
/// [`Bsp2`](BspVersion::Bsp2). The two formats use the same 15-lump
/// directory but differ in edge/face record widths (u16 vs u32).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BspVersion {
    V29,
    Bsp2,
}

impl BspVersion {
    /// Decode the 4-byte magic at the start of the file.
    #[must_use]
    pub fn from_magic(magic: u32) -> Option<Self> {
        match magic {
            BSP_MAGIC_V29 => Some(Self::V29),
            BSP_MAGIC_BSP2 => Some(Self::Bsp2),
            _ => None,
        }
    }
}

impl fmt::Display for BspVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::V29 => f.write_str("29"),
            Self::Bsp2 => f.write_str("BSP2"),
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct LumpDir {
    pub offset: u32,
    pub length: u32,
}

#[derive(Debug, Clone)]
pub struct BspHeader {
    pub version: BspVersion,
    pub dir: [LumpDir; NUM_LUMPS],
}

impl BspHeader {
    pub fn parse(raw: &[u8]) -> Result<Self, BspError> {
        let mut cur = Cursor::new(raw);
        let magic = cur.read_u32::<LittleEndian>()?;
        let version = BspVersion::from_magic(magic).ok_or(BspError::UnsupportedVersion(magic))?;
        let mut dir = [LumpDir::default(); NUM_LUMPS];
        for d in dir.iter_mut().take(Lump::COUNT) {
            d.offset = cur.read_u32::<LittleEndian>()?;
            d.length = cur.read_u32::<LittleEndian>()?;
        }
        Ok(Self { version, dir })
    }
}
