//! PCX decoder for `QuakeWorld` player skins (.pcx).
//!
//! QW skins are 8bpp paletted PCX with the palette appended.
//! We use the `pcx` crate for parsing and convert to RGBA.

use crate::{ImageError, RgbaImage};

pub fn decode(bytes: &[u8]) -> Result<RgbaImage, ImageError> {
    let mut reader =
        pcx::Reader::new(std::io::Cursor::new(bytes)).map_err(|_| ImageError::PcxUnsupported)?;
    if !reader.is_paletted() {
        return Err(ImageError::PcxUnsupported);
    }
    let width = u32::from(reader.width());
    let height = u32::from(reader.height());
    let total = (width as usize) * (height as usize);

    // Read paletted scanlines, then resolve the palette.
    let mut indices = vec![0u8; total];
    for y in 0..height {
        reader
            .next_row_paletted(
                &mut indices[(y as usize) * width as usize..((y + 1) as usize) * width as usize],
            )
            .map_err(|_| ImageError::PcxUnsupported)?;
    }
    let mut palette = [0u8; 256 * 3];
    reader
        .read_palette(&mut palette)
        .map_err(|_| ImageError::PcxUnsupported)?;

    let mut pixels = Vec::with_capacity(total * 4);
    for &idx in &indices {
        let p = (idx as usize) * 3;
        pixels.extend_from_slice(&[palette[p], palette[p + 1], palette[p + 2], 255]);
    }

    Ok(RgbaImage {
        width,
        height,
        pixels,
    })
}
