//! BSP header and lump directory.

use byteorder::{LittleEndian, ReadBytesExt};
use std::io::Cursor;

use crate::{BspError, Lump};

/// Vanilla Q1 BSP version.
pub const BSP_VERSION_Q1: u32 = 29;

/// Number of lumps in a Q1 BSP.
pub const NUM_LUMPS: usize = 15;

#[derive(Debug, Clone, Copy, Default)]
pub struct LumpDir {
    pub offset: u32,
    pub length: u32,
}

#[derive(Debug, Clone)]
pub struct BspHeader {
    pub version: u32,
    pub dir: [LumpDir; NUM_LUMPS],
}

impl BspHeader {
    pub fn parse(raw: &[u8]) -> Result<Self, BspError> {
        let mut cur = Cursor::new(raw);
        let version = cur.read_u32::<LittleEndian>()?;
        let mut dir = [LumpDir::default(); NUM_LUMPS];
        for d in dir.iter_mut().take(Lump::COUNT) {
            d.offset = cur.read_u32::<LittleEndian>()?;
            d.length = cur.read_u32::<LittleEndian>()?;
        }
        Ok(Self { version, dir })
    }
}
