//! Q1 model formats: MDL (alias models) and SPR (sprites).
//!
//! MDL stores vertex-animated meshes (players, monsters, weapons).
//! SPR stores billboard sprites (explosions, particles).
//!
//! Reference: <https://www.gamers.org/dEngine/quake/QDP/qmapspec.html>

pub mod mdl;
pub mod spr;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ModelError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("invalid MDL magic: expected b\"IDPO\", got {0:?}")]
    InvalidMdlMagic([u8; 4]),

    #[error("invalid SPR magic: expected b\"IDSP\", got {0:?}")]
    InvalidSprMagic([u8; 4]),

    #[error("unsupported MDL version: {0} (expected 6)")]
    UnsupportedMdlVersion(u32),

    #[error("unsupported SPR version: {0} (expected 1 or 2)")]
    UnsupportedSprVersion(u32),
}
