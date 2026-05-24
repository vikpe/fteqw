//! MDL (IDPO version 6) alias-model loader.
//!
//! Layout:
//! - 84-byte header (magic, version, scale/origin, sizes, counts)
//! - Skin texture data (paletted)
//! - Skin texture coords (u/v per vertex)
//! - Triangle list (3 vertex indices per triangle)
//! - Frame data (vertex positions for each animation frame)

use byteorder::{LittleEndian, ReadBytesExt};
use std::io::{Cursor, Read};

use crate::ModelError;

pub const MDL_MAGIC: &[u8; 4] = b"IDPO";
pub const MDL_VERSION: u32 = 6;

#[derive(Debug, Clone)]
pub struct MdlHeader {
    pub scale: [f32; 3],
    pub origin: [f32; 3],
    pub bounding_radius: f32,
    pub eye_position: [f32; 3],
    pub num_skins: u32,
    pub skin_width: u32,
    pub skin_height: u32,
    pub num_vertices: u32,
    pub num_triangles: u32,
    pub num_frames: u32,
    pub synctype: u32,
    pub flags: u32,
    pub size: f32,
}

impl MdlHeader {
    pub fn parse(raw: &[u8]) -> Result<Self, ModelError> {
        let mut cur = Cursor::new(raw);
        let mut magic = [0u8; 4];
        cur.read_exact(&mut magic)?;
        if &magic != MDL_MAGIC {
            return Err(ModelError::InvalidMdlMagic(magic));
        }
        let version = cur.read_u32::<LittleEndian>()?;
        if version != MDL_VERSION {
            return Err(ModelError::UnsupportedMdlVersion(version));
        }
        let scale = [
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        ];
        let origin = [
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        ];
        let bounding_radius = cur.read_f32::<LittleEndian>()?;
        let eye_position = [
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        ];
        let num_skins = cur.read_u32::<LittleEndian>()?;
        let skin_width = cur.read_u32::<LittleEndian>()?;
        let skin_height = cur.read_u32::<LittleEndian>()?;
        let num_vertices = cur.read_u32::<LittleEndian>()?;
        let num_triangles = cur.read_u32::<LittleEndian>()?;
        let num_frames = cur.read_u32::<LittleEndian>()?;
        let synctype = cur.read_u32::<LittleEndian>()?;
        let flags = cur.read_u32::<LittleEndian>()?;
        let size = cur.read_f32::<LittleEndian>()?;

        Ok(Self {
            scale,
            origin,
            bounding_radius,
            eye_position,
            num_skins,
            skin_width,
            skin_height,
            num_vertices,
            num_triangles,
            num_frames,
            synctype,
            flags,
            size,
        })
    }
}

/// A loaded MDL with header + raw bytes for further decode.
pub struct Mdl {
    pub header: MdlHeader,
    pub raw: Vec<u8>,
}

impl Mdl {
    pub fn from_bytes(raw: Vec<u8>) -> Result<Self, ModelError> {
        let header = MdlHeader::parse(&raw)?;
        Ok(Self { header, raw })
    }

    // TODO: skin decoder (paletted texture indexing into Quake palette)
    // TODO: triangle / vertex iterators
    // TODO: frame interpolation
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_mdl_header() -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(MDL_MAGIC);
        b.extend_from_slice(&MDL_VERSION.to_le_bytes());
        // scale
        for _ in 0..3 {
            b.extend_from_slice(&1.0f32.to_le_bytes());
        }
        // origin
        for _ in 0..3 {
            b.extend_from_slice(&0.0f32.to_le_bytes());
        }
        // bounding_radius
        b.extend_from_slice(&64.0f32.to_le_bytes());
        // eye_position
        for _ in 0..3 {
            b.extend_from_slice(&0.0f32.to_le_bytes());
        }
        // counts and remaining fields (12 u32 + 1 f32)
        let u32s: [u32; 9] = [1, 32, 32, 100, 200, 5, 0, 0, 0];
        for v in u32s {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&50.0f32.to_le_bytes());
        b
    }

    #[test]
    fn parses_minimal_header() {
        let h = MdlHeader::parse(&fake_mdl_header()).unwrap();
        assert_eq!(h.num_skins, 1);
        assert_eq!(h.skin_width, 32);
        assert_eq!(h.skin_height, 32);
        assert_eq!(h.num_vertices, 100);
        assert_eq!(h.num_triangles, 200);
        assert_eq!(h.num_frames, 5);
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bytes = fake_mdl_header();
        bytes[0..4].copy_from_slice(b"NOPE");
        assert!(matches!(
            MdlHeader::parse(&bytes),
            Err(ModelError::InvalidMdlMagic(_))
        ));
    }
}
