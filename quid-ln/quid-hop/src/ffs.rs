//! Flat file system abstraction.
//!
//! Copied verbatim from quid's `quid/src/unstable/ffs.rs` (quid→quid rename
//! only). This is the reusable local storage primitive that backs the hop's
//! persister, so we do NOT hand-write a storage layer — see
//! `quid-hop/src/persister.rs` for the thin `Vfs`-over-`Ffs` adapter.

use std::{
    fs,
    io::{self, Read, Write as _},
    path::{Path, PathBuf},
};

use quid_crypto::rng::{RngExt, ThreadFastRng};

/// Abstraction over a flat file system (no subdirs), suitable for mocking.
///
/// **Invariant**: The `Ffs` must always be ready for `read` / `write` /
/// `delete` calls, including after `delete_all`.
pub trait Ffs {
    /// Reads the entire contents of `filename`.
    ///
    /// NOTE: Use [`io::ErrorKind::NotFound`] to detect if a file is missing.
    fn read(&self, filename: &str) -> io::Result<Vec<u8>> {
        let mut buf = Vec::new();
        self.read_into(filename, &mut buf)?;
        Ok(buf)
    }

    /// Reads the contents of `filename` into `buf`.
    fn read_into(&self, filename: &str, buf: &mut Vec<u8>) -> io::Result<()>;

    /// Reads all filenames in the `Ffs`.
    fn read_dir(&self) -> io::Result<Vec<String>> {
        let mut filenames = Vec::new();
        self.read_dir_visitor(|filename| {
            filenames.push(filename.to_owned());
            Ok(())
        })?;
        Ok(filenames)
    }

    /// Visit all filenames in the `Ffs`.
    fn read_dir_visitor(
        &self,
        dir_visitor: impl FnMut(&str) -> io::Result<()>,
    ) -> io::Result<()>;

    /// Write `data` to `filename`, overwriting any existing file.
    fn write(&self, filename: &str, data: &[u8]) -> io::Result<()>;

    /// Delete all files and directories in the `Ffs` without deleting the `Ffs`
    /// itself or any artifacts required for its continued use.
    fn delete_all(&self) -> io::Result<()>;

    /// Delete file.
    fn delete(&self, filename: &str) -> io::Result<()>;
}

/// File system impl for [`Ffs`] that does real IO.
#[derive(Clone)]
pub struct DiskFs {
    /// Files are stored flat (i.e., no subdirectories) in this directory.
    base_dir: PathBuf,

    /// `{base_dir}/.write`
    ///
    /// Used to support atomic writes. We fully write files to this subdir
    /// before moving them to their final destination in `base_dir`.
    write_dir: PathBuf,
}

impl DiskFs {
    /// Create a new [`DiskFs`] ready for use.
    pub fn create_dir_all(base_dir: PathBuf) -> anyhow::Result<Self> {
        fs::create_dir_all(base_dir.as_path())?;

        let write_dir = Self::write_dir_path(&base_dir);
        fsext::remove_dir_all_idempotent(&write_dir)?;
        fs::create_dir(write_dir.as_path())?;

        Ok(Self {
            base_dir,
            write_dir,
        })
    }

    fn write_dir_path(base_dir: &Path) -> PathBuf {
        base_dir.join(".write")
    }
}

impl Ffs for DiskFs {
    fn read_into(&self, filename: &str, buf: &mut Vec<u8>) -> io::Result<()> {
        let mut file = fs::File::open(self.base_dir.join(filename).as_path())?;
        file.read_to_end(buf)?;
        Ok(())
    }

    fn read_dir_visitor(
        &self,
        mut dir_visitor: impl FnMut(&str) -> io::Result<()>,
    ) -> io::Result<()> {
        for maybe_file_entry in self.base_dir.read_dir()? {
            let file_entry = maybe_file_entry?;

            // Only visit files.
            if file_entry.file_type()?.is_file() {
                // Just skip non-UTF-8 filenames.
                if let Some(filename) = file_entry.file_name().to_str() {
                    dir_visitor(filename)?;
                }
            }
        }
        Ok(())
    }

    fn write(&self, filename: &str, data: &[u8]) -> io::Result<()> {
        let final_dest_path = self.base_dir.join(filename);

        // Sample a new random alphanumeric filename to use in the .write subdir.
        // This way multiple threads can't partially write to the same file.
        let tmp_write_path = {
            let name: [u8; 16] = ThreadFastRng::new().gen_alphanum_bytes();
            let name_str = std::str::from_utf8(name.as_slice())
                .expect("ASCII is all valid UTF-8");
            self.write_dir.join(name_str)
        };

        // DURABLE atomic write — write to a temp file, fsync it, rename, then fsync
        // the destination directory.
        //
        // DIVERGENCE FROM QUID (deliberate): upstream's `Ffs::write` skips the
        // fsyncs ("low effort atomic write") because in quid custody data is ALSO
        // mirrored to a replicated remote backend, so a local page-cache loss on
        // power-cut isn't the sole source of truth. In the quid hop this flat file
        // store IS the only custody store: `HopPersister::write_monitor` returns
        // `ChannelMonitorUpdateStatus::Completed` the moment this returns, which
        // tells LDK the monitor update is DURABLE — LDK then releases revocation
        // secrets / reveals preimages on the wire. Without the fsyncs a crash
        // between `write` returning and the kernel flushing could reload a STALE
        // monitor (lost revocation secret → a revoked-state broadcast goes
        // unpunished; lost just-claimed preimage). So durability here is
        // load-bearing and we pay for the fsyncs.
        {
            let mut f = fs::File::create(tmp_write_path.as_path())?;
            f.write_all(data)?;
            f.sync_all()?; // flush file contents to disk before the rename
        }
        fs::rename(tmp_write_path.as_path(), final_dest_path)?;
        // fsync the directory so the rename (the directory entry naming the new
        // file) is itself durable — otherwise a crash can lose the rename even
        // though the file bytes were synced.
        if let Ok(dir) = fs::File::open(self.base_dir.as_path()) {
            dir.sync_all()?;
        }
        Ok(())
    }

    fn delete_all(&self) -> io::Result<()> {
        fs::remove_dir_all(self.base_dir.as_path())?;
        fs::create_dir(self.base_dir.as_path())?;
        // Recreate the .write dir so subsequent writes still work.
        fs::create_dir(self.write_dir.as_path())?;
        Ok(())
    }

    fn delete(&self, filename: &str) -> io::Result<()> {
        fs::remove_file(self.base_dir.join(filename).as_path())?;
        Ok(())
    }
}

/// [`std::fs`] extensions.
pub mod fsext {
    use std::{fs, io, path::Path};

    /// [`std::fs::remove_dir_all`] but does not error on file not found.
    /// Returns `true` if the directory existed and was deleted.
    pub fn remove_dir_all_idempotent(dir: &Path) -> io::Result<bool> {
        match fs::remove_dir_all(dir) {
            Ok(()) => Ok(true),
            Err(ref e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }
}

/// An in-memory [`Ffs`] implementation, useful for testing the hop node boot
/// without touching disk.
#[derive(Debug)]
pub struct InMemoryFfs {
    inner: std::sync::Mutex<std::collections::BTreeMap<String, Vec<u8>>>,
}

impl InMemoryFfs {
    /// Create a new empty [`InMemoryFfs`].
    pub fn new() -> Self {
        Self {
            inner: std::sync::Mutex::new(std::collections::BTreeMap::new()),
        }
    }
}

impl Default for InMemoryFfs {
    fn default() -> Self {
        Self::new()
    }
}

impl Ffs for InMemoryFfs {
    fn read_into(&self, filename: &str, buf: &mut Vec<u8>) -> io::Result<()> {
        match self.inner.lock().unwrap().get(filename) {
            Some(data) => buf.extend_from_slice(data),
            None => {
                return Err(io::Error::new(io::ErrorKind::NotFound, filename))
            }
        }
        Ok(())
    }

    fn read_dir_visitor(
        &self,
        mut dir_visitor: impl FnMut(&str) -> io::Result<()>,
    ) -> io::Result<()> {
        let filenames = self
            .inner
            .lock()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for filename in &filenames {
            dir_visitor(filename)?;
        }
        Ok(())
    }

    fn write(&self, filename: &str, data: &[u8]) -> io::Result<()> {
        self.inner
            .lock()
            .unwrap()
            .insert(filename.to_owned(), data.to_owned());
        Ok(())
    }

    fn delete_all(&self) -> io::Result<()> {
        self.inner.lock().unwrap().clear();
        Ok(())
    }

    fn delete(&self, filename: &str) -> io::Result<()> {
        match self.inner.lock().unwrap().remove(filename) {
            Some(_) => Ok(()),
            None => Err(io::Error::new(io::ErrorKind::NotFound, filename)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_ffs_roundtrip() {
        let ffs = InMemoryFfs::new();
        assert!(ffs.read("missing").is_err());
        ffs.write("a", b"hello").unwrap();
        ffs.write("b", b"world").unwrap();
        assert_eq!(ffs.read("a").unwrap(), b"hello");
        let mut names = ffs.read_dir().unwrap();
        names.sort();
        assert_eq!(names, vec!["a".to_string(), "b".to_string()]);
        ffs.delete("a").unwrap();
        assert!(ffs.read("a").is_err());
        assert_eq!(ffs.read("b").unwrap(), b"world");
        ffs.delete_all().unwrap();
        assert!(ffs.read("b").is_err());
        // Still usable after delete_all (the Ffs invariant).
        ffs.write("c", b"again").unwrap();
        assert_eq!(ffs.read("c").unwrap(), b"again");
    }
}
