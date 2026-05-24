//! Filesystem layer: PAK (Q1/Q2) and PK3 (zip) archive readers.
//!
//! Quake resolves files through layered gamedir lookups. This crate
//! handles individual archive readers; the `qworld-engine` crate
//! composes them into a Quake-style virtual filesystem.
//!
//! Web: reads come from JS-provided byte buffers (no native FS).
//! Native: reads come from disk via `std::fs`.

pub mod pak;
pub mod pk3;

use std::io;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum FsError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),

    #[error("invalid PAK magic: expected b\"PACK\", got {0:?}")]
    InvalidPakMagic([u8; 4]),

    #[error("PAK directory offset {offset} + length {length} exceeds file size {size}")]
    PakDirOutOfBounds { offset: u32, length: u32, size: u64 },

    #[error("PAK entry name not nul-terminated")]
    PakEntryNameInvalid,

    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
}

/// A virtual file entry resolved through any backing archive.
#[derive(Debug, Clone)]
pub struct VirtualEntry {
    pub name: String,
    pub size: u64,
}

/// Common trait for archive readers (PAK, PK3, raw dir).
pub trait Archive {
    fn entries(&self) -> Box<dyn Iterator<Item = VirtualEntry> + '_>;
    fn read(&mut self, name: &str) -> Result<Vec<u8>, FsError>;
}
