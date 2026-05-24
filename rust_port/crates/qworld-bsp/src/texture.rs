//! Texture lump decoders: `texinfo` and the variable-length `textures`
//! lump (containing zero or more `miptex` blocks).
//!
//! Q1 BSP layout:
//! - `texinfo` lump: array of fixed-size `Texinfo` records (40 bytes
//!   each). Each face references one via `Face::texinfo`.
//! - `textures` lump (named `Lump::Textures`): a header
//!   (`dmiptexlump_t` in FTE) of `num_miptex` followed by that many
//!   i32 offsets — each offset points to a `MipTexHeader` block
//!   relative to the lump start. An offset of `-1` means "missing",
//!   e.g. when textures live in an external WAD.
//! - Each `MipTexHeader` is 40 bytes: 16-byte name, `width`,
//!   `height`, then four `offsets[4]` to the mip levels (also
//!   relative to the miptex start). Pixel data is paletted (one
//!   byte per pixel) at full, half, quarter, and eighth resolution.

use byteorder::{LittleEndian, ReadBytesExt};
use glam::Vec3;
use std::io::Cursor;

use crate::{Bsp, BspError, Lump};

/// Per-face texture mapping: s/t projection vectors + offsets,
/// the index of the miptex to apply, and a flags bitfield.
#[derive(Debug, Clone, Copy)]
pub struct Texinfo {
    /// World-space basis vector for the S (u) texture coordinate.
    pub s_vector: Vec3,
    pub s_offset: f32,
    /// World-space basis vector for the T (v) texture coordinate.
    pub t_vector: Vec3,
    pub t_offset: f32,
    /// Index into the decoded `MipTex` list.
    pub miptex_index: u32,
    /// `TEX_SPECIAL = 1` for sky/liquids; other bits vary by tool.
    pub flags: u32,
}

pub const TEXINFO_BYTES: usize = 40;
pub const MIPTEX_HEADER_BYTES: usize = 40;

/// `Texinfo::flags & TEX_SPECIAL` marks sky / liquid surfaces. They
/// skip lightmap generation and use animated shader effects.
pub const TEX_SPECIAL: u32 = 1;

/// Number of mip levels stored per miptex block.
pub const MIP_LEVELS: usize = 4;

pub fn decode_texinfo(bsp: &Bsp) -> Result<Vec<Texinfo>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Texinfo);
    if !bytes.len().is_multiple_of(TEXINFO_BYTES) {
        return Err(BspError::EntityParse(format!(
            "texinfo lump size {} not divisible by {TEXINFO_BYTES}",
            bytes.len()
        )));
    }
    let count = bytes.len() / TEXINFO_BYTES;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let s_vector = Vec3::new(
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        );
        let s_offset = cur.read_f32::<LittleEndian>()?;
        let t_vector = Vec3::new(
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        );
        let t_offset = cur.read_f32::<LittleEndian>()?;
        let miptex_index = cur.read_u32::<LittleEndian>()?;
        let flags = cur.read_u32::<LittleEndian>()?;
        out.push(Texinfo {
            s_vector,
            s_offset,
            t_vector,
            t_offset,
            miptex_index,
            flags,
        });
    }
    Ok(out)
}

/// One miptex block: a 16-char name, four mip levels of paletted
/// pixel data (full / half / quarter / eighth resolution). Some
/// entries in the textures lump are absent (offset = -1) — those
/// are returned as [`MipTex::Missing`] so the indexing matches
/// [`Texinfo::miptex_index`].
#[derive(Debug, Clone)]
pub enum MipTex {
    Loaded(MipTexData),
    Missing,
}

#[derive(Debug, Clone)]
pub struct MipTexData {
    pub name: String,
    pub width: u32,
    pub height: u32,
    /// Four mip levels of paletted pixels. `mips[0]` is full-size
    /// (`width * height` bytes); each subsequent level halves both
    /// dimensions. An empty `Vec` means the mip was not stored
    /// (`offsets[i] == 0`).
    pub mips: [Vec<u8>; MIP_LEVELS],
}

pub fn decode_miptex(bsp: &Bsp) -> Result<Vec<MipTex>, BspError> {
    let lump = bsp.lump_bytes(Lump::Textures);
    if lump.is_empty() {
        return Ok(Vec::new());
    }
    let mut cur = Cursor::new(lump);
    let num_miptex = cur.read_i32::<LittleEndian>()?;
    if num_miptex < 0 {
        return Err(BspError::EntityParse(format!(
            "negative num_miptex: {num_miptex}"
        )));
    }
    let num_miptex = num_miptex as usize;
    let mut offsets = Vec::with_capacity(num_miptex);
    for _ in 0..num_miptex {
        offsets.push(cur.read_i32::<LittleEndian>()?);
    }
    let mut out = Vec::with_capacity(num_miptex);
    for offset in offsets {
        if offset < 0 {
            out.push(MipTex::Missing);
            continue;
        }
        let offset = offset as usize;
        if offset + MIPTEX_HEADER_BYTES > lump.len() {
            return Err(BspError::EntityParse(format!(
                "miptex offset {offset} past lump end {}",
                lump.len()
            )));
        }
        out.push(decode_miptex_at(lump, offset)?);
    }
    Ok(out)
}

fn decode_miptex_at(lump: &[u8], base: usize) -> Result<MipTex, BspError> {
    let mut cur = Cursor::new(&lump[base..]);
    let mut name_buf = [0u8; 16];
    std::io::Read::read_exact(&mut cur, &mut name_buf)?;
    let nul = name_buf.iter().position(|&b| b == 0).unwrap_or(16);
    let name = String::from_utf8_lossy(&name_buf[..nul]).into_owned();
    let width = cur.read_u32::<LittleEndian>()?;
    let height = cur.read_u32::<LittleEndian>()?;
    let mut mip_offsets = [0u32; MIP_LEVELS];
    for slot in &mut mip_offsets {
        *slot = cur.read_u32::<LittleEndian>()?;
    }
    let mut mips: [Vec<u8>; MIP_LEVELS] = Default::default();
    for (level, &local_offset) in mip_offsets.iter().enumerate() {
        if local_offset == 0 {
            continue;
        }
        let mip_w = (width >> level) as usize;
        let mip_h = (height >> level) as usize;
        let pixel_count = mip_w * mip_h;
        let start = base + local_offset as usize;
        let end = start + pixel_count;
        if end > lump.len() {
            return Err(BspError::EntityParse(format!(
                "miptex {name:?} mip {level} runs past lump end ({end} > {})",
                lump.len()
            )));
        }
        mips[level] = lump[start..end].to_vec();
    }
    Ok(MipTex::Loaded(MipTexData {
        name,
        width,
        height,
        mips,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::{BSP_MAGIC_V29, NUM_LUMPS};

    /// Build a BSP file whose only populated lumps are texinfo + textures.
    fn make_textured_bsp(texinfo_bytes: &[u8], textures_bytes: &[u8]) -> Bsp {
        let mut file = Vec::new();
        file.extend_from_slice(&BSP_MAGIC_V29.to_le_bytes());
        let dir_pos = file.len();
        file.extend(std::iter::repeat_n(0u8, NUM_LUMPS * 8));

        let mut offsets = [(0u32, 0u32); NUM_LUMPS];
        let put = |file: &mut Vec<u8>, data: &[u8]| -> (u32, u32) {
            let off = file.len() as u32;
            file.extend_from_slice(data);
            (off, data.len() as u32)
        };
        offsets[Lump::Texinfo as usize] = put(&mut file, texinfo_bytes);
        offsets[Lump::Textures as usize] = put(&mut file, textures_bytes);

        for (lump_index, (off, len)) in offsets.iter().enumerate() {
            let p = dir_pos + lump_index * 8;
            file[p..p + 4].copy_from_slice(&off.to_le_bytes());
            file[p + 4..p + 8].copy_from_slice(&len.to_le_bytes());
        }
        Bsp::from_bytes(file).unwrap()
    }

    fn texinfo_record_bytes(
        s: [f32; 3],
        s_off: f32,
        t: [f32; 3],
        t_off: f32,
        miptex: u32,
        flags: u32,
    ) -> Vec<u8> {
        let mut b = Vec::with_capacity(TEXINFO_BYTES);
        for v in s {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&s_off.to_le_bytes());
        for v in t {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&t_off.to_le_bytes());
        b.extend_from_slice(&miptex.to_le_bytes());
        b.extend_from_slice(&flags.to_le_bytes());
        b
    }

    /// Build a textures lump with one miptex (named, 2x2, all 4 mips
    /// stored as solid index 7) plus one missing entry (offset = -1).
    fn make_textures_lump() -> Vec<u8> {
        let miptex_offset: i32 = 4 + 2 * 4; // num_miptex + 2 offsets
        let mut header = Vec::new();
        header.extend_from_slice(&2i32.to_le_bytes());
        header.extend_from_slice(&miptex_offset.to_le_bytes());
        header.extend_from_slice(&(-1i32).to_le_bytes());

        // Miptex starts at offset `miptex_offset`; mip pixels follow
        // the 40-byte miptex header immediately.
        let mut miptex = Vec::new();
        let mut name = [0u8; 16];
        name[..6].copy_from_slice(b"+0wall");
        miptex.extend_from_slice(&name);
        miptex.extend_from_slice(&2u32.to_le_bytes()); // width
        miptex.extend_from_slice(&2u32.to_le_bytes()); // height
        // mip offsets relative to miptex start
        let mip0_offset = MIPTEX_HEADER_BYTES as u32;
        let mip1_offset = mip0_offset + 4; // mip0 is 2x2 = 4 bytes
        let mip2_offset = mip1_offset + 1; // mip1 is 1x1 = 1 byte
        let mip3_offset = 0u32; // missing
        miptex.extend_from_slice(&mip0_offset.to_le_bytes());
        miptex.extend_from_slice(&mip1_offset.to_le_bytes());
        miptex.extend_from_slice(&mip2_offset.to_le_bytes());
        miptex.extend_from_slice(&mip3_offset.to_le_bytes());
        // mip0 = 2x2 = 4 pixels
        miptex.extend_from_slice(&[7, 7, 7, 7]);
        // mip1 = 1x1 = 1 pixel (mip2 0x0 contributes 0 bytes)
        miptex.extend_from_slice(&[7]);

        let mut lump = header;
        lump.extend_from_slice(&miptex);
        lump
    }

    #[test]
    fn decodes_texinfo_records() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&texinfo_record_bytes(
            [1.0, 0.0, 0.0],
            8.0,
            [0.0, -1.0, 0.0],
            16.0,
            3,
            TEX_SPECIAL,
        ));
        bytes.extend_from_slice(&texinfo_record_bytes(
            [0.0, 1.0, 0.0],
            0.0,
            [0.0, 0.0, -1.0],
            0.0,
            0,
            0,
        ));
        let bsp = make_textured_bsp(&bytes, &[]);
        let infos = decode_texinfo(&bsp).unwrap();
        assert_eq!(infos.len(), 2);
        assert_eq!(infos[0].s_vector, Vec3::new(1.0, 0.0, 0.0));
        assert_eq!(infos[0].s_offset, 8.0);
        assert_eq!(infos[0].miptex_index, 3);
        assert_eq!(infos[0].flags, TEX_SPECIAL);
        assert_eq!(infos[1].t_vector, Vec3::new(0.0, 0.0, -1.0));
        assert_eq!(infos[1].flags, 0);
    }

    #[test]
    fn texinfo_rejects_misaligned_lump() {
        // 41 bytes -> not a multiple of TEXINFO_BYTES
        let bsp = make_textured_bsp(&[0u8; 41], &[]);
        assert!(matches!(
            decode_texinfo(&bsp),
            Err(BspError::EntityParse(_))
        ));
    }

    #[test]
    fn decodes_miptex_with_missing_entry() {
        let bsp = make_textured_bsp(&[], &make_textures_lump());
        let miptex = decode_miptex(&bsp).unwrap();
        assert_eq!(miptex.len(), 2);
        match &miptex[0] {
            MipTex::Loaded(data) => {
                assert_eq!(data.name, "+0wall");
                assert_eq!(data.width, 2);
                assert_eq!(data.height, 2);
                assert_eq!(data.mips[0], vec![7, 7, 7, 7]);
                assert_eq!(data.mips[1], vec![7]);
                assert!(data.mips[2].is_empty());
                assert!(data.mips[3].is_empty());
            }
            MipTex::Missing => panic!("expected first entry to be loaded"),
        }
        assert!(matches!(miptex[1], MipTex::Missing));
    }

    #[test]
    fn empty_textures_lump_returns_empty_vec() {
        let bsp = make_textured_bsp(&[], &[]);
        let miptex = decode_miptex(&bsp).unwrap();
        assert!(miptex.is_empty());
    }
}
