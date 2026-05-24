//! QWD (`QuakeWorld` single-POV demo) parser.
//!
//! Block layout per server packet:
//! - f32 time
//! - u8 message type (1 = read, 2 = set, ...)
//! - depending on type, more headers, then:
//! - u32 length
//! - `length` bytes of QW server packet payload

use binrw::{binrw, BinRead};
use std::io::{Cursor, Read};

use crate::DemoError;

#[binrw]
#[brw(little)]
#[derive(Debug, Clone)]
pub struct QwdBlockHeader {
    pub time: f32,
    pub msg_type: u8,
}

/// A single block (header + payload bytes). Higher-level decoding
/// of the payload goes through `qworld-net::parse_server_message`.
#[derive(Debug, Clone)]
pub struct QwdBlock {
    pub header: QwdBlockHeader,
    pub payload: Vec<u8>,
}

pub struct QwdReader<'a> {
    cur: Cursor<&'a [u8]>,
}

impl<'a> QwdReader<'a> {
    #[must_use] 
    pub fn new(bytes: &'a [u8]) -> Self {
        Self {
            cur: Cursor::new(bytes),
        }
    }

    pub fn next_block(&mut self) -> Option<Result<QwdBlock, DemoError>> {
        if self.cur.position() as usize >= self.cur.get_ref().len() {
            return None;
        }
        Some(self.read_block())
    }

    fn read_block(&mut self) -> Result<QwdBlock, DemoError> {
        let header = QwdBlockHeader::read(&mut self.cur)?;
        // For msg_type = 1 (dem_read), payload length follows.
        // Other types have additional fixed fields not handled here.
        let len = match header.msg_type {
            1 => u32::read_le(&mut self.cur)?,
            _ => {
                return Err(DemoError::Malformed(format!(
                    "qwd msg type {} not yet implemented",
                    header.msg_type
                )));
            }
        };
        let mut payload = vec![0u8; len as usize];
        self.cur.read_exact(&mut payload)?;
        Ok(QwdBlock { header, payload })
    }
}
