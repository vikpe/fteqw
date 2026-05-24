//! LMP (Quake-palette 8bpp) decoder.
//!
//! Format:
//! - u32 width
//! - u32 height
//! - width*height bytes of palette indices
//!
//! Decoded against the Quake palette (256 RGB triplets, loaded from
//! id1/gfx/palette.lmp at startup). Index 255 is transparent in
//! sprites/skins; we expose that as alpha=0.

use byteorder::{LittleEndian, ReadBytesExt};
use qworld_core::color::QuakePalette;
use std::io::{Cursor, Read};

use crate::{ImageError, RgbaImage};

pub fn decode(bytes: &[u8], palette: &QuakePalette) -> Result<RgbaImage, ImageError> {
    let mut cur = Cursor::new(bytes);
    let width = cur.read_u32::<LittleEndian>()? as usize;
    let height = cur.read_u32::<LittleEndian>()? as usize;
    let expected = width * height;
    let mut indices = vec![0u8; expected];
    cur.read_exact(&mut indices)?;

    if indices.len() != expected {
        return Err(ImageError::LmpSizeMismatch {
            expected,
            actual: indices.len(),
        });
    }

    let mut pixels = Vec::with_capacity(expected * 4);
    for &idx in &indices {
        let rgb = palette[idx as usize];
        pixels.extend_from_slice(&[rgb[0], rgb[1], rgb[2], if idx == 255 { 0 } else { 255 }]);
    }

    Ok(RgbaImage {
        width: width as u32,
        height: height as u32,
        pixels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_solid_red_4x2() {
        let mut palette = [[0u8; 3]; 256];
        palette[7] = [255, 0, 0];
        palette[255] = [128, 128, 128];

        let mut bytes = Vec::new();
        bytes.extend_from_slice(&4u32.to_le_bytes());
        bytes.extend_from_slice(&2u32.to_le_bytes());
        bytes.extend(std::iter::repeat_n(7u8, 7));
        bytes.push(255);

        let img = decode(&bytes, &palette).unwrap();
        assert_eq!(img.width, 4);
        assert_eq!(img.height, 2);
        assert_eq!(&img.pixels[0..4], &[255, 0, 0, 255]);
        let last = img.pixels.len() - 4;
        // Index 255 -> transparent alpha
        assert_eq!(&img.pixels[last..], &[128, 128, 128, 0]);
    }
}
