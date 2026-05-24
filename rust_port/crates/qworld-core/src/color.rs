//! Color types.

/// Linear RGBA color, 4 floats in [0.0, 1.0].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    pub const WHITE: Self = Self {
        r: 1.0,
        g: 1.0,
        b: 1.0,
        a: 1.0,
    };
    pub const BLACK: Self = Self {
        r: 0.0,
        g: 0.0,
        b: 0.0,
        a: 1.0,
    };
    pub const TRANSPARENT: Self = Self {
        r: 0.0,
        g: 0.0,
        b: 0.0,
        a: 0.0,
    };

    #[must_use] 
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }
}

/// Quake's standard 256-entry palette (id1 PALETTE.LMP).
/// First 16 entries are greys/skins, palette indexes for fullbright
/// fonts start at 224. Index 255 is transparency for sprites/skins.
pub type QuakePalette = [[u8; 3]; 256];

/// Expected byte length of a Quake palette: 256 entries x 3 bytes.
pub const QUAKE_PALETTE_BYTES_LEN: usize = 768;

/// Raw bytes of the vanilla id1 palette (the contents of
/// `gfx/palette.lmp`). Useful as a default when no custom palette
/// file is available.
pub const QUAKE_PALETTE_BYTES: [u8; QUAKE_PALETTE_BYTES_LEN] = [
    0, 0, 0, 15, 15, 15, 31, 31, 31, 47, 47, 47, 63, 63, 63, 75, 75, 75, 91, 91, 91, 107, 107, 107,
    123, 123, 123, 139, 139, 139, 155, 155, 155, 171, 171, 171, 187, 187, 187, 203, 203, 203, 219,
    219, 219, 235, 235, 235, 15, 11, 7, 23, 15, 11, 31, 23, 11, 39, 27, 15, 47, 35, 19, 55, 43, 23,
    63, 47, 23, 75, 55, 27, 83, 59, 27, 91, 67, 31, 99, 75, 31, 107, 83, 31, 115, 87, 31, 123, 95,
    35, 131, 103, 35, 143, 111, 35, 11, 11, 15, 19, 19, 27, 27, 27, 39, 39, 39, 51, 47, 47, 63, 55,
    55, 75, 63, 63, 87, 71, 71, 103, 79, 79, 115, 91, 91, 127, 99, 99, 139, 107, 107, 151, 115,
    115, 163, 123, 123, 175, 131, 131, 187, 139, 139, 203, 0, 0, 0, 7, 7, 0, 11, 11, 0, 19, 19, 0,
    27, 27, 0, 35, 35, 0, 43, 43, 7, 47, 47, 7, 55, 55, 7, 63, 63, 7, 71, 71, 7, 75, 75, 11, 83,
    83, 11, 91, 91, 11, 99, 99, 11, 107, 107, 15, 7, 0, 0, 15, 0, 0, 23, 0, 0, 31, 0, 0, 39, 0, 0,
    47, 0, 0, 55, 0, 0, 63, 0, 0, 71, 0, 0, 79, 0, 0, 87, 0, 0, 95, 0, 0, 103, 0, 0, 111, 0, 0,
    119, 0, 0, 127, 0, 0, 19, 19, 0, 27, 27, 0, 35, 35, 0, 47, 43, 0, 55, 47, 0, 67, 55, 0, 75, 59,
    7, 87, 67, 7, 95, 71, 7, 107, 75, 11, 119, 83, 15, 131, 87, 19, 139, 91, 19, 151, 95, 27, 163,
    99, 31, 175, 103, 35, 35, 19, 7, 47, 23, 11, 59, 31, 15, 75, 35, 19, 87, 43, 23, 99, 47, 31,
    115, 55, 35, 127, 59, 43, 143, 67, 51, 159, 79, 51, 175, 99, 47, 191, 119, 47, 207, 143, 43,
    223, 171, 39, 239, 203, 31, 255, 243, 27, 11, 7, 0, 27, 19, 0, 43, 35, 15, 55, 43, 19, 71, 51,
    27, 83, 55, 35, 99, 63, 43, 111, 71, 51, 127, 83, 63, 139, 95, 71, 155, 107, 83, 167, 123, 95,
    183, 135, 107, 195, 147, 123, 211, 163, 139, 227, 179, 151, 171, 139, 163, 159, 127, 151, 147,
    115, 135, 139, 103, 123, 127, 91, 111, 119, 83, 99, 107, 75, 87, 95, 63, 75, 87, 55, 67, 75,
    47, 55, 67, 39, 47, 55, 31, 35, 43, 23, 27, 35, 19, 19, 23, 11, 11, 15, 7, 7, 187, 115, 159,
    175, 107, 143, 163, 95, 131, 151, 87, 119, 139, 79, 107, 127, 75, 95, 115, 67, 83, 107, 59, 75,
    95, 51, 63, 83, 43, 55, 71, 35, 43, 59, 31, 35, 47, 23, 27, 35, 19, 19, 23, 11, 11, 15, 7, 7,
    219, 195, 187, 203, 179, 167, 191, 163, 155, 175, 151, 139, 163, 135, 123, 151, 123, 111, 135,
    111, 95, 123, 99, 83, 107, 87, 71, 95, 75, 59, 83, 63, 51, 67, 51, 39, 55, 43, 31, 39, 31, 23,
    27, 19, 15, 15, 11, 7, 111, 131, 123, 103, 123, 111, 95, 115, 103, 87, 107, 95, 79, 99, 87, 71,
    91, 79, 63, 83, 71, 55, 75, 63, 47, 67, 55, 43, 59, 47, 35, 51, 39, 31, 43, 31, 23, 35, 23, 15,
    27, 19, 11, 19, 11, 7, 11, 7, 255, 243, 27, 239, 223, 23, 219, 203, 19, 203, 183, 15, 187, 167,
    15, 171, 151, 11, 155, 131, 7, 139, 115, 7, 123, 99, 7, 107, 83, 0, 91, 71, 0, 75, 55, 0, 59,
    43, 0, 43, 31, 0, 27, 15, 0, 11, 7, 0, 0, 0, 255, 11, 11, 239, 19, 19, 223, 27, 27, 207, 35,
    35, 191, 43, 43, 175, 47, 47, 159, 47, 47, 143, 47, 47, 127, 47, 47, 111, 47, 47, 95, 43, 43,
    79, 35, 35, 63, 27, 27, 47, 19, 19, 31, 11, 11, 15, 43, 0, 0, 59, 0, 0, 75, 7, 0, 95, 7, 0,
    111, 15, 0, 127, 23, 7, 147, 31, 7, 163, 39, 11, 183, 51, 15, 195, 75, 27, 207, 99, 43, 219,
    127, 59, 227, 151, 79, 231, 171, 95, 239, 191, 119, 247, 211, 139, 167, 123, 59, 183, 155, 55,
    199, 195, 55, 231, 227, 87, 127, 191, 255, 171, 231, 255, 215, 255, 255, 103, 0, 0, 139, 0, 0,
    179, 0, 0, 215, 0, 0, 255, 0, 0, 255, 243, 147, 255, 247, 199, 255, 255, 255, 159, 91, 83,
];

/// Vanilla id1 palette as a [`QuakePalette`], decoded at compile
/// time from [`QUAKE_PALETTE_BYTES`].
pub const QUAKE_PALETTE: QuakePalette = {
    let mut out = [[0u8; 3]; 256];
    let mut entry_index = 0;
    while entry_index < 256 {
        let offset = entry_index * 3;
        out[entry_index] = [
            QUAKE_PALETTE_BYTES[offset],
            QUAKE_PALETTE_BYTES[offset + 1],
            QUAKE_PALETTE_BYTES[offset + 2],
        ];
        entry_index += 1;
    }
    out
};

#[derive(Debug, thiserror::Error)]
pub enum PaletteError {
    #[error("palette must be exactly {QUAKE_PALETTE_BYTES_LEN} bytes, got {0}")]
    WrongSize(usize),
}

/// Parse a 768-byte raw RGB palette (the layout of `gfx/palette.lmp`)
/// into a [`QuakePalette`]. Use [`QUAKE_PALETTE`] directly when the
/// vanilla id1 palette is what's needed.
pub fn load_palette(bytes: &[u8]) -> Result<QuakePalette, PaletteError> {
    if bytes.len() != QUAKE_PALETTE_BYTES_LEN {
        return Err(PaletteError::WrongSize(bytes.len()));
    }
    let mut out: QuakePalette = [[0u8; 3]; 256];
    for (entry_index, entry) in out.iter_mut().enumerate() {
        let offset = entry_index * 3;
        entry[0] = bytes[offset];
        entry[1] = bytes[offset + 1];
        entry[2] = bytes[offset + 2];
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_synthetic_palette() {
        let mut bytes = vec![0u8; QUAKE_PALETTE_BYTES_LEN];
        // Entry 0 = (1, 2, 3), entry 7 = (255, 128, 64),
        // entry 255 = (10, 20, 30).
        bytes[0..3].copy_from_slice(&[1, 2, 3]);
        bytes[21..24].copy_from_slice(&[255, 128, 64]);
        bytes[765..768].copy_from_slice(&[10, 20, 30]);

        let pal = load_palette(&bytes).unwrap();
        assert_eq!(pal[0], [1, 2, 3]);
        assert_eq!(pal[7], [255, 128, 64]);
        assert_eq!(pal[255], [10, 20, 30]);
    }

    #[test]
    fn rejects_wrong_size() {
        let short = vec![0u8; 767];
        assert!(matches!(
            load_palette(&short),
            Err(PaletteError::WrongSize(767))
        ));
        let long = vec![0u8; 769];
        assert!(matches!(
            load_palette(&long),
            Err(PaletteError::WrongSize(769))
        ));
    }

    #[test]
    fn embedded_palette_matches_runtime_decode() {
        // The const-evaluated QUAKE_PALETTE must agree byte-for-byte
        // with what load_palette produces from the same source bytes.
        let runtime = load_palette(&QUAKE_PALETTE_BYTES).unwrap();
        assert_eq!(runtime, QUAKE_PALETTE);
        // Spot-check vanilla id1 entries: index 0 is black, last entry
        // is the well-known reddish-brown (159, 91, 83).
        assert_eq!(QUAKE_PALETTE[0], [0, 0, 0]);
        assert_eq!(QUAKE_PALETTE[255], [159, 91, 83]);
    }
}
