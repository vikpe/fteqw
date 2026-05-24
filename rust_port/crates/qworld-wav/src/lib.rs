//! WAV decoder for Quake sound effects.
//!
//! Quake's sound system uses PCM WAV files with mono/8/16-bit samples
//! and (sometimes) looping markers in the "cue " / "LIST" chunks.
//!
//! We use the `hound` crate to read WAV; loop-point handling for
//! looped ambient sounds is TODO.

use std::io::Cursor;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum WavError {
    #[error("hound error: {0}")]
    Hound(#[from] hound::Error),
}

#[derive(Debug, Clone)]
pub struct DecodedWav {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    /// Interleaved samples as i16 (most Quake WAVs are 16-bit; we
    /// upcast 8-bit to centered i16).
    pub samples: Vec<i16>,
    pub loop_start: Option<u32>,
}

pub fn decode(bytes: &[u8]) -> Result<DecodedWav, WavError> {
    let reader = hound::WavReader::new(Cursor::new(bytes))?;
    let spec = reader.spec();
    let samples: Vec<i16> = match spec.bits_per_sample {
        16 => reader
            .into_samples::<i16>()
            .filter_map(Result::ok)
            .collect(),
        8 => reader
            .into_samples::<i8>()
            .filter_map(Result::ok)
            .map(|s| i16::from(s) << 8)
            .collect(),
        _ => reader
            .into_samples::<i32>()
            .filter_map(Result::ok)
            .map(|s| (s >> 16) as i16)
            .collect(),
    };
    Ok(DecodedWav {
        sample_rate: spec.sample_rate,
        channels: spec.channels,
        bits_per_sample: spec.bits_per_sample,
        samples,
        loop_start: None, // TODO: parse cue chunks
    })
}
