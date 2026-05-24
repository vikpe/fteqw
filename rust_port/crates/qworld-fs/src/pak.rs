//! Q1/Q2 PAK archive reader.
//!
//! Format:
//! - 12-byte header: `PACK` magic, u32 dir offset, u32 dir length.
//! - Dir at `offset` contains `length/64` entries.
//! - Each entry: 56-byte nul-padded name + u32 file offset + u32 size.

use byteorder::{LittleEndian, ReadBytesExt};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use crate::{Archive, FsError, VirtualEntry};

pub const PAK_MAGIC: &[u8; 4] = b"PACK";
pub const PAK_ENTRY_SIZE: usize = 64;
pub const PAK_NAME_LEN: usize = 56;

#[derive(Debug, Clone)]
pub struct PakEntry {
    pub name: String,
    pub offset: u32,
    pub size: u32,
}

#[derive(Debug)]
pub struct PakReader {
    file: File,
    entries: Vec<PakEntry>,
}

impl PakReader {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, FsError> {
        let mut file = File::open(path)?;
        let file_size = file.metadata()?.len();

        // Header
        let mut magic = [0u8; 4];
        file.read_exact(&mut magic)?;
        if &magic != PAK_MAGIC {
            return Err(FsError::InvalidPakMagic(magic));
        }
        let dir_offset = file.read_u32::<LittleEndian>()?;
        let dir_length = file.read_u32::<LittleEndian>()?;

        if u64::from(dir_offset) + u64::from(dir_length) > file_size {
            return Err(FsError::PakDirOutOfBounds {
                offset: dir_offset,
                length: dir_length,
                size: file_size,
            });
        }

        // Entries
        file.seek(SeekFrom::Start(u64::from(dir_offset)))?;
        let entry_count = dir_length as usize / PAK_ENTRY_SIZE;
        let mut entries = Vec::with_capacity(entry_count);
        for _ in 0..entry_count {
            let mut name_buf = [0u8; PAK_NAME_LEN];
            file.read_exact(&mut name_buf)?;
            let nul_pos = name_buf
                .iter()
                .position(|&b| b == 0)
                .ok_or(FsError::PakEntryNameInvalid)?;
            let name = std::str::from_utf8(&name_buf[..nul_pos])
                .map_err(|_| FsError::PakEntryNameInvalid)?
                .to_string();
            let offset = file.read_u32::<LittleEndian>()?;
            let size = file.read_u32::<LittleEndian>()?;
            entries.push(PakEntry { name, offset, size });
        }

        Ok(Self { file, entries })
    }

    #[must_use] 
    pub fn entries_slice(&self) -> &[PakEntry] {
        &self.entries
    }

    #[must_use] 
    pub fn find(&self, name: &str) -> Option<&PakEntry> {
        self.entries.iter().find(|e| e.name == name)
    }
}

impl Archive for PakReader {
    fn entries(&self) -> Box<dyn Iterator<Item = VirtualEntry> + '_> {
        Box::new(self.entries.iter().map(|e| VirtualEntry {
            name: e.name.clone(),
            size: u64::from(e.size),
        }))
    }

    fn read(&mut self, name: &str) -> Result<Vec<u8>, FsError> {
        let entry = self
            .entries
            .iter()
            .find(|e| e.name == name)
            .cloned()
            .ok_or_else(|| {
                FsError::Io(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    format!("PAK entry not found: {name}"),
                ))
            })?;
        self.file.seek(SeekFrom::Start(u64::from(entry.offset)))?;
        let mut buf = vec![0u8; entry.size as usize];
        self.file.read_exact(&mut buf)?;
        Ok(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn make_pak(entries: &[(&str, &[u8])]) -> NamedTempFile {
        // Build a minimal PAK in memory then write it.
        let mut file_data = Vec::new();
        // Header placeholder (12 bytes)
        file_data.extend_from_slice(&[0u8; 12]);

        let mut entry_meta = Vec::new();
        for (name, data) in entries {
            entry_meta.push((name.to_string(), file_data.len() as u32, data.len() as u32));
            file_data.extend_from_slice(data);
        }

        let dir_offset = file_data.len() as u32;
        for (name, offset, size) in &entry_meta {
            let mut name_buf = [0u8; PAK_NAME_LEN];
            let nb = name.as_bytes();
            name_buf[..nb.len()].copy_from_slice(nb);
            file_data.extend_from_slice(&name_buf);
            file_data.extend_from_slice(&offset.to_le_bytes());
            file_data.extend_from_slice(&size.to_le_bytes());
        }
        let dir_length = (entry_meta.len() * PAK_ENTRY_SIZE) as u32;

        // Patch header
        file_data[0..4].copy_from_slice(PAK_MAGIC);
        file_data[4..8].copy_from_slice(&dir_offset.to_le_bytes());
        file_data[8..12].copy_from_slice(&dir_length.to_le_bytes());

        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(&file_data).unwrap();
        tmp.flush().unwrap();
        tmp
    }

    #[test]
    fn parse_minimal_pak() {
        let tmp = make_pak(&[
            ("progs.dat", b"fake-progs-bytes"),
            ("maps/dm3.bsp", b"fake-bsp"),
        ]);
        let mut reader = PakReader::open(tmp.path()).unwrap();
        assert_eq!(reader.entries_slice().len(), 2);
        assert_eq!(reader.entries_slice()[0].name, "progs.dat");
        let data = reader.read("maps/dm3.bsp").unwrap();
        assert_eq!(data, b"fake-bsp");
    }

    #[test]
    fn rejects_bad_magic() {
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"WRONG\0\0\0\0\0\0\0").unwrap();
        tmp.flush().unwrap();
        let err = PakReader::open(tmp.path()).unwrap_err();
        assert!(matches!(err, FsError::InvalidPakMagic(_)));
    }
}
