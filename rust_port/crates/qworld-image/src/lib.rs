//! Image decoders for the texture pipeline.
//!
//! - PNG / TGA / JPG via the `image` crate (already industrial-strength).
//! - LMP (Quake-palette indexed 8bpp) — custom decoder, needed for
//!   Quake's gfx wad textures and skies.
//! - PCX (QW player skins) — custom decoder.
//!
//! All decoders emit RGBA8 for the renderer to upload as a texture.

pub mod lmp;
pub mod pcx;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ImageError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("image crate error: {0}")]
    Image(#[from] image::ImageError),

    #[error("LMP size mismatch: header says {expected}, got {actual}")]
    LmpSizeMismatch { expected: usize, actual: usize },

    #[error("PCX: unsupported encoding/bpp")]
    PcxUnsupported,
}

#[derive(Debug, Clone)]
pub struct RgbaImage {
    pub width: u32,
    pub height: u32,
    /// Row-major, 4 bytes per pixel (R, G, B, A).
    pub pixels: Vec<u8>,
}

impl RgbaImage {
    pub fn from_png_tga_jpg(bytes: &[u8]) -> Result<Self, ImageError> {
        let img = image::load_from_memory(bytes)?.to_rgba8();
        Ok(Self {
            width: img.width(),
            height: img.height(),
            pixels: img.into_raw(),
        })
    }
}
