//! `NetQuake` .dem parser.
//!
//! Format:
//! - ASCII CD track number ("-1\n" or "<n>\n"), terminated by newline
//! - Sequence of blocks:
//!   - u32 length
//!   - 3 floats: view angles (pitch, yaw, roll)
//!   - `length` bytes of NQ server message data
//!
//! Initial scaffold.

use binrw::BinRead;
use std::io::{BufRead, BufReader, Cursor, Read};

use crate::DemoError;

#[derive(Debug, Clone)]
pub struct NqHeader {
    /// CD track number (-1 = none).
    pub cd_track: i32,
}

#[derive(Debug, Clone)]
pub struct NqBlock {
    pub view_angles: [f32; 3],
    pub payload: Vec<u8>,
}

pub struct NqReader<'a> {
    cur: Cursor<&'a [u8]>,
    pub header: NqHeader,
}

impl<'a> NqReader<'a> {
    pub fn new(bytes: &'a [u8]) -> Result<Self, DemoError> {
        let mut br = BufReader::new(Cursor::new(bytes));
        let mut line = String::new();
        br.read_line(&mut line)?;
        let cd_track: i32 = line
            .trim_end_matches('\n')
            .parse()
            .map_err(|e: std::num::ParseIntError| DemoError::Malformed(e.to_string()))?;
        // Advance underlying cursor past the line we consumed.
        let consumed = line.len();
        let mut cur = Cursor::new(bytes);
        cur.set_position(consumed as u64);
        Ok(Self {
            cur,
            header: NqHeader { cd_track },
        })
    }

    pub fn next_block(&mut self) -> Option<Result<NqBlock, DemoError>> {
        if self.cur.position() as usize >= self.cur.get_ref().len() {
            return None;
        }
        Some(self.read_block())
    }

    fn read_block(&mut self) -> Result<NqBlock, DemoError> {
        let len = u32::read_le(&mut self.cur)?;
        let view_angles = [
            f32::read_le(&mut self.cur)?,
            f32::read_le(&mut self.cur)?,
            f32::read_le(&mut self.cur)?,
        ];
        let mut payload = vec![0u8; len as usize];
        self.cur.read_exact(&mut payload)?;
        Ok(NqBlock {
            view_angles,
            payload,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_header_track_only() {
        let bytes = b"-1\n";
        let reader = NqReader::new(bytes).unwrap();
        assert_eq!(reader.header.cd_track, -1);
    }

    #[test]
    fn parses_one_block() {
        // Header: "0\n"
        // Block: len=2, angles=(1.0, 2.0, 3.0), payload=[0xAA, 0xBB]
        let mut bytes = Vec::from(*b"0\n");
        bytes.extend_from_slice(&2u32.to_le_bytes());
        bytes.extend_from_slice(&1.0f32.to_le_bytes());
        bytes.extend_from_slice(&2.0f32.to_le_bytes());
        bytes.extend_from_slice(&3.0f32.to_le_bytes());
        bytes.extend_from_slice(&[0xAA, 0xBB]);

        let mut reader = NqReader::new(&bytes).unwrap();
        let block = reader.next_block().unwrap().unwrap();
        assert_eq!(block.view_angles, [1.0, 2.0, 3.0]);
        assert_eq!(block.payload, vec![0xAA, 0xBB]);
        assert!(reader.next_block().is_none());
    }
}
