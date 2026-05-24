//! PK3 / ZIP archive reader.
//!
//! Quake3 (and modern QW content) packages assets in ZIP files
//! renamed to `.pk3`. We use the `zip` crate which handles deflate
//! and modern zip features.

use std::fs::File;
use std::io::Read;
use std::path::Path;

use crate::{Archive, FsError, VirtualEntry};

pub struct Pk3Reader {
    archive: zip::ZipArchive<File>,
}

impl Pk3Reader {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, FsError> {
        let file = File::open(path)?;
        let archive = zip::ZipArchive::new(file)?;
        Ok(Self { archive })
    }

    #[must_use] 
    pub fn len(&self) -> usize {
        self.archive.len()
    }

    #[must_use] 
    pub fn is_empty(&self) -> bool {
        self.archive.is_empty()
    }
}

impl Archive for Pk3Reader {
    fn entries(&self) -> Box<dyn Iterator<Item = VirtualEntry> + '_> {
        // Note: zip crate doesn't expose a clean iterator without
        // mutable access; clone names into a vec.
        let names: Vec<(String, u64)> = (0..self.archive.len())
            .filter_map(|i| {
                // SAFETY: by_index needs &mut, so we use file_names
                // and skip sizes; a real impl would store metadata
                // at open time. Stub.
                None::<(String, u64)>
                    .or_else(|| self.archive.file_names().nth(i).map(|n| (n.to_string(), 0)))
            })
            .collect();
        Box::new(
            names
                .into_iter()
                .map(|(name, size)| VirtualEntry { name, size }),
        )
    }

    fn read(&mut self, name: &str) -> Result<Vec<u8>, FsError> {
        let mut file = self.archive.by_name(name)?;
        let mut buf = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut buf)?;
        Ok(buf)
    }
}
