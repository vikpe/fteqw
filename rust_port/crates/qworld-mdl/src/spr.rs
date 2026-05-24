//! SPR (IDSP) sprite loader.
//!
//! Versions 1 (vanilla) and 2 (Hexen 2, but useful for some QW
//! content). Header is small; frames are arrays of paletted images
//! with origin offsets for billboard placement.

use byteorder::{LittleEndian, ReadBytesExt};
use std::io::{Cursor, Read};

use crate::ModelError;

pub const SPR_MAGIC: &[u8; 4] = b"IDSP";

#[derive(Debug, Clone, Copy)]
pub enum SpriteType {
    ViewParallelUpright = 0,
    Upright = 1,
    ViewParallel = 2,
    Oriented = 3,
    ViewParallelOriented = 4,
}

#[derive(Debug, Clone)]
pub struct SprHeader {
    pub version: u32,
    pub sprite_type: u32,
    pub bounding_radius: f32,
    pub max_width: u32,
    pub max_height: u32,
    pub num_frames: u32,
    pub beam_length: f32,
    pub synctype: u32,
}

impl SprHeader {
    pub fn parse(raw: &[u8]) -> Result<Self, ModelError> {
        let mut cur = Cursor::new(raw);
        let mut magic = [0u8; 4];
        cur.read_exact(&mut magic)?;
        if &magic != SPR_MAGIC {
            return Err(ModelError::InvalidSprMagic(magic));
        }
        let version = cur.read_u32::<LittleEndian>()?;
        if version != 1 && version != 2 {
            return Err(ModelError::UnsupportedSprVersion(version));
        }
        Ok(Self {
            version,
            sprite_type: cur.read_u32::<LittleEndian>()?,
            bounding_radius: cur.read_f32::<LittleEndian>()?,
            max_width: cur.read_u32::<LittleEndian>()?,
            max_height: cur.read_u32::<LittleEndian>()?,
            num_frames: cur.read_u32::<LittleEndian>()?,
            beam_length: cur.read_f32::<LittleEndian>()?,
            synctype: cur.read_u32::<LittleEndian>()?,
        })
    }
}
