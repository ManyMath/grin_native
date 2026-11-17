//! Session registry, `Drop`-based close and the per-directory LMDB guard.
//!
//! `OPEN_DIRS` is keyed by directory identity (`DirKey`), not by path, so a
//! wallet database reached through a bind mount or through a directory
//! renamed while it was open still maps to the one entry.
//!
//! Lock rules: `SESSION_REGISTRY` and `OPEN_DIRS` are never held at the same
//! time, no LMDB work runs while either is held, and both are locked with
//! `unwrap_or_else(PoisonError::into_inner)` because `Drop` may run while a
//! thread unwinds.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};

use grin_core::global::{self, ChainTypes};
use grin_keychain::ExtKeychain;
use grin_util::secp::key::SecretKey;
use grin_wallet_config::GRIN_WALLET_DIR;
use grin_wallet_impls::DefaultLCProvider;
use grin_wallet_libwallet::WalletInst;
use zeroize::Zeroize;

use crate::config::{FfiNodeClient, NodeSettings};
use crate::error::{GrinError, GrinErrorCode};

/// Lifecycle provider of every wallet in this crate.
pub type WalletLc = DefaultLCProvider<FfiNodeClient, ExtKeychain>;

/// The one concrete wallet type. libwallet's owner functions take exactly
/// this shape (`Arc<grin_util::Mutex<Box<dyn WalletInst>>>`).
pub type WalletInstance =
    Arc<grin_util::Mutex<Box<dyn WalletInst<'static, WalletLc, FfiNodeClient, ExtKeychain>>>>;

/// Bits of `ScanProgressState::flags`.
const SCANNING: u8 = 1;
const CANCEL: u8 = 2;
const CLOSED: u8 = 4;

/// Outcome of `ScanProgressState::begin_scan`.
#[derive(Debug, PartialEq, Eq)]
pub enum ScanStart {
    Started,
    /// Another scan is running on this wallet.
    Busy,
    /// The handle was closed; the session only lives on in this call.
    Closed,
}

/// Progress of the current or most recent scan, readable without the wallet
/// mutex.
///
/// The running, cancel and closed states share one atomic word, so starting
/// a scan, cancelling it and closing the wallet cannot interleave in a way
/// that loses a cancel or lets a stale one stop a later scan.
#[derive(Debug, Default)]
pub struct ScanProgressState {
    flags: AtomicU8,
    pub scanned_height: AtomicU64,
    pub tip_height: AtomicU64,
    pub start_height: AtomicU64,
}

impl ScanProgressState {
    /// Marks a scan as running and drops a cancel request left over from an
    /// earlier scan. A closed session never starts one.
    pub fn begin_scan(&self) -> ScanStart {
        let r = self
            .flags
            .try_update(Ordering::AcqRel, Ordering::Acquire, |f| {
                if f & (SCANNING | CLOSED) == 0 {
                    Some(SCANNING)
                } else {
                    None
                }
            });
        match r {
            Ok(_) => ScanStart::Started,
            Err(f) if f & CLOSED != 0 => ScanStart::Closed,
            Err(_) => ScanStart::Busy,
        }
    }

    /// Clears the running and cancel bits when a scan ends, however it ends.
    pub fn end_scan(&self) {
        self.flags.fetch_and(!(SCANNING | CANCEL), Ordering::AcqRel);
    }

    /// Asks the running scan to stop at its next batch boundary. Does
    /// nothing (and returns false) when no scan is running.
    pub fn request_cancel(&self) -> bool {
        self.flags
            .try_update(Ordering::AcqRel, Ordering::Acquire, |f| {
                if f & SCANNING != 0 {
                    Some(f | CANCEL)
                } else {
                    None
                }
            })
            .is_ok()
    }

    /// Set when the handle is closed. Stops a running scan at its next batch
    /// boundary and keeps an in-flight call from starting a new one.
    pub fn mark_closed(&self) {
        self.flags.fetch_or(CLOSED, Ordering::AcqRel);
    }

    /// True once a cancel or a close asks the running scan to stop.
    pub fn should_stop(&self) -> bool {
        self.flags.load(Ordering::Acquire) & (CANCEL | CLOSED) != 0
    }

    pub fn is_scanning(&self) -> bool {
        self.flags.load(Ordering::Acquire) & SCANNING != 0
    }

    /// Same as `should_stop`; the name `grin_wallet_scan_progress` reports.
    pub fn cancel_requested(&self) -> bool {
        self.should_stop()
    }

    /// Resets the heights for a scan that is starting at `start`.
    pub fn reset(&self, start: u64) {
        self.start_height.store(start, Ordering::Release);
        self.tip_height.store(0, Ordering::Release);
        self.scanned_height.store(0, Ordering::Release);
    }

    /// Percentage of the current or last scan range covered, 0 to 100.
    pub fn progress_pct(&self) -> u8 {
        let start = self.start_height.load(Ordering::Acquire);
        let tip = self.tip_height.load(Ordering::Acquire);
        let scanned = self.scanned_height.load(Ordering::Acquire);
        if tip == 0 {
            return 0;
        }
        if tip <= start {
            return if scanned >= tip { 100 } else { 0 };
        }
        let done = scanned.saturating_sub(start) as u128 * 100 / (tip - start) as u128;
        done.min(100) as u8
    }
}

/// An open wallet. Dropping the last `Arc` closes the backend, zeroizes the
/// keychain mask and then releases the directory lease.
pub struct WalletSession {
    pub handle: u64,
    pub chain_type: ChainTypes,
    pub wallet: WalletInstance,
    /// XOR mask for the in-memory keychain. Zeroized in `Drop`.
    pub keychain_mask: Mutex<Option<SecretKey>>,
    pub scan_state: ScanProgressState,
    /// Canonical `<wallet_dir>/wallet_data` as it was when the wallet was
    /// opened. The directory lease is keyed by `dir_key()`, not by this path.
    pub data_dir: PathBuf,
    pub node: Mutex<NodeSettings>,
    /// In-process chain of a wallet made by `grin_test_create_wallet`.
    #[cfg(feature = "test-utils")]
    pub(crate) test_chain: Option<Arc<crate::test_support::TestChain>>,
    /// Batch size and per-batch callback that tests set for scans.
    #[cfg(feature = "test-utils")]
    pub(crate) scan_hooks: crate::test_support::ScanTestHooks,
    /// Declared last so it is dropped after everything above.
    _lease: DirLease,
}

impl WalletSession {
    pub(crate) fn new(
        handle: u64,
        chain_type: ChainTypes,
        wallet: WalletInstance,
        keychain_mask: Option<SecretKey>,
        node: NodeSettings,
        lease: DirLease,
    ) -> Self {
        WalletSession {
            handle,
            chain_type,
            wallet,
            keychain_mask: Mutex::new(keychain_mask),
            scan_state: ScanProgressState::default(),
            data_dir: lease.path().to_path_buf(),
            node: Mutex::new(node),
            #[cfg(feature = "test-utils")]
            test_chain: None,
            #[cfg(feature = "test-utils")]
            scan_hooks: Default::default(),
            _lease: lease,
        }
    }

    /// Identity of the data directory, as held in `OPEN_DIRS`.
    pub fn dir_key(&self) -> &DirKey {
        self._lease.key()
    }

    /// Copy of the keychain mask for one libwallet call.
    pub fn mask(&self) -> Option<SecretKey> {
        self.keychain_mask
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn node_settings(&self) -> MutexGuard<'_, NodeSettings> {
        self.node.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Fails with a Node error, before anything is read or sent, when the
    /// wallet's network is turned off.
    pub fn require_network(&self) -> Result<(), GrinError> {
        self.node_settings().require_enabled()
    }

    /// Clones the wallet's node client so network calls run without the
    /// wallet mutex held.
    pub fn node_client(&self) -> Result<FfiNodeClient, GrinError> {
        let mut w = self.wallet.lock();
        let lc = w.lc_provider()?;
        let backend = lc.wallet_inst()?;
        Ok(backend.w2n_client().clone())
    }
}

impl std::fmt::Debug for WalletSession {
    // Leaves out the wallet and the keychain mask on purpose.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalletSession")
            .field("handle", &self.handle)
            .field("chain_type", &self.chain_type)
            .field("data_dir", &self.data_dir)
            .finish_non_exhaustive()
    }
}

impl Drop for WalletSession {
    fn drop(&mut self) {
        self.scan_state.mark_closed();
        {
            let mut w = self.wallet.lock();
            match w.lc_provider() {
                Ok(lc) => {
                    if let Err(e) = lc.close_wallet(None) {
                        log::warn!("wallet {}: close_wallet failed: {e}", self.handle);
                    }
                }
                Err(e) => log::warn!("wallet {}: no lifecycle provider: {e}", self.handle),
            }
        }
        if let Some(mut mask) = self
            .keychain_mask
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            mask.zeroize();
        }
        log::debug!("wallet {} closed", self.handle);
        // `_lease` is the last field, so it is released after the backend.
    }
}

static SESSION_REGISTRY: LazyLock<Mutex<HashMap<u64, Arc<WalletSession>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

static OPEN_DIRS: LazyLock<Mutex<HashSet<DirKey>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

fn registry() -> MutexGuard<'static, HashMap<u64, Arc<WalletSession>>> {
    SESSION_REGISTRY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

fn open_dirs() -> MutexGuard<'static, HashSet<DirKey>> {
    OPEN_DIRS.lock().unwrap_or_else(PoisonError::into_inner)
}

fn invalid_handle(handle: u64) -> GrinError {
    GrinError::new(
        GrinErrorCode::InvalidHandle,
        format!("no open wallet with handle {handle}"),
    )
}

/// Allocates a handle, builds the session outside the registry lock and
/// registers it.
pub(crate) fn register_session<F>(build: F) -> u64
where
    F: FnOnce(u64) -> WalletSession,
{
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    let session = Arc::new(build(handle));
    registry().insert(handle, session);
    handle
}

/// Clones the session out of the registry, releases the lock and sets this
/// thread's chain type to the wallet's.
pub fn get_session(handle: u64) -> Result<Arc<WalletSession>, GrinError> {
    let session = lookup_session(handle).ok_or_else(|| invalid_handle(handle))?;
    global::set_local_chain_type(session.chain_type);
    Ok(session)
}

/// Registry lookup without touching the chain type.
pub(crate) fn lookup_session(handle: u64) -> Option<Arc<WalletSession>> {
    if handle == 0 {
        return None;
    }
    registry().get(&handle).cloned()
}

/// Removes the session from the registry and marks it closed, which stops
/// a running scan at its next batch boundary. The caller drops the returned
/// `Arc` after the lock is gone; if it was the last one, the backend closes
/// right there.
pub(crate) fn remove_session(handle: u64) -> Option<Arc<WalletSession>> {
    if handle == 0 {
        return None;
    }
    let session = registry().remove(&handle);
    if let Some(s) = &session {
        s.scan_state.mark_closed();
    }
    session
}

/// Like `remove_session`, but only when no call still holds the session: if
/// another `Arc` exists outside the registry the session stays registered
/// and `WalletBusy` is returned, so a caller that is refused keeps its
/// handle. The check and the removal happen under the registry lock, so a
/// lookup cannot slip in between them.
pub(crate) fn remove_session_if_idle(handle: u64) -> Result<Option<Arc<WalletSession>>, GrinError> {
    if handle == 0 {
        return Ok(None);
    }
    let mut reg = registry();
    let Some(entry) = reg.get(&handle) else {
        return Ok(None);
    };
    if Arc::strong_count(entry) > 1 {
        return Err(GrinError::new(
            GrinErrorCode::WalletBusy,
            "the wallet still has a call running; it was not closed",
        )
        .with_details(serde_json::json!({
            "wallet_dir": entry.data_dir.to_string_lossy(),
        })));
    }
    let session = reg.remove(&handle);
    drop(reg);
    if let Some(s) = &session {
        s.scan_state.mark_closed();
    }
    Ok(session)
}

/// Identity of a directory, the key of `OPEN_DIRS`.
///
/// On unix this is the device and inode number of the directory, so two
/// paths to one directory (a bind mount, a renamed parent) give the same key,
/// and a directory removed and made again at the same path gives a new one.
/// On other platforms it is the canonical path: std has no stable way to get
/// the Windows file index yet.
#[cfg(unix)]
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DirKey {
    dev: u64,
    ino: u64,
}

/// Identity of a directory, the key of `OPEN_DIRS`. Here it is the
/// canonical path; see the unix version for what it is there.
#[cfg(not(unix))]
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DirKey(PathBuf);

impl DirKey {
    /// Reads the identity of `dir`, which must exist. On platforms without
    /// inode numbers `dir` must be canonical.
    pub fn of(dir: &Path) -> io::Result<DirKey> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let meta = std::fs::metadata(dir)?;
            Ok(DirKey {
                dev: meta.dev(),
                ino: meta.ino(),
            })
        }
        #[cfg(not(unix))]
        {
            Ok(DirKey(dir.to_path_buf()))
        }
    }
}

/// RAII membership of a wallet data directory in `OPEN_DIRS`. Holds the
/// directory's identity as the key and its canonical path for error details
/// and `WalletSession::data_dir`.
#[derive(Debug)]
pub struct DirLease {
    key: DirKey,
    path: PathBuf,
}

impl DirLease {
    /// Fails with `WalletBusy` if another lease holds the same directory,
    /// whatever path it was reached through. `dir` must exist (it has no
    /// identity otherwise) and should be canonical: it is what the error
    /// detail and `path()` report.
    pub fn acquire(dir: &Path) -> Result<DirLease, GrinError> {
        let key = DirKey::of(dir)?;
        if open_dirs().insert(key.clone()) {
            Ok(DirLease {
                key,
                path: dir.to_path_buf(),
            })
        } else {
            Err(GrinError::new(
                GrinErrorCode::WalletBusy,
                "the wallet directory is in use by an open or still closing wallet",
            )
            .with_details(serde_json::json!({ "wallet_dir": dir.to_string_lossy() })))
        }
    }

    pub fn key(&self) -> &DirKey {
        &self.key
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for DirLease {
    fn drop(&mut self) {
        open_dirs().remove(&self.key);
    }
}

/// `<wallet_dir>/wallet_data` as given (not canonical).
pub fn data_dir_path(wallet_dir: &str) -> PathBuf {
    Path::new(wallet_dir).join(GRIN_WALLET_DIR)
}

/// Refuses a `<wallet_dir>/wallet_data` that is itself a symbolic link.
/// Create, open and delete act on the directory the link points at, so a
/// link planted in one wallet directory would let a delete remove another
/// wallet's data (the name check alone passes when the target is also
/// called `wallet_data`). A missing path is fine: it is not a link.
pub fn refuse_symlinked_data_dir(wallet_dir: &str) -> Result<(), GrinError> {
    match std::fs::symlink_metadata(data_dir_path(wallet_dir)) {
        Ok(m) if m.file_type().is_symlink() => Err(GrinError::invalid_argument(format!(
            "{GRIN_WALLET_DIR} must be a directory, not a symbolic link"
        ))),
        Ok(_) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

/// For create: makes `<wallet_dir>/wallet_data` if needed and returns its
/// canonical path plus whether it existed before.
pub fn canonical_data_dir_create(wallet_dir: &str) -> Result<(PathBuf, bool), GrinError> {
    let dir = data_dir_path(wallet_dir);
    let existed = dir.exists();
    std::fs::create_dir_all(&dir)?;
    restrict_dir(&dir);
    Ok((std::fs::canonicalize(&dir)?, existed))
}

/// Makes `dir` accessible only to its owner on Unix, so the seed, database
/// and transaction metadata inside it are not readable by other accounts
/// whatever the umask. Elsewhere the platform's defaults apply. A failure,
/// for example on a filesystem without Unix modes, is logged and ignored.
fn restrict_dir(dir: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let result = std::fs::metadata(dir).and_then(|m| {
            if m.permissions().mode() & 0o077 != 0 {
                std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            } else {
                Ok(())
            }
        });
        if let Err(e) = result {
            log::warn!("could not restrict the wallet data directory: {e}");
        }
    }
    #[cfg(not(unix))]
    let _ = dir;
}

/// For open and delete: the canonical data directory, or `None` if it does
/// not exist.
pub fn canonical_data_dir_existing(wallet_dir: &str) -> Result<Option<PathBuf>, GrinError> {
    match std::fs::canonicalize(data_dir_path(wallet_dir)) {
        Ok(p) => {
            // Wallets created before the directory was restricted.
            restrict_dir(&p);
            Ok(Some(p))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn symlinked_data_dir_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let real = root.path().join("real");
        std::fs::create_dir_all(real.join(GRIN_WALLET_DIR)).unwrap();
        assert!(refuse_symlinked_data_dir(real.to_str().unwrap()).is_ok());
        let missing = root.path().join("missing");
        assert!(refuse_symlinked_data_dir(missing.to_str().unwrap()).is_ok());
        let decoy = root.path().join("decoy");
        std::fs::create_dir(&decoy).unwrap();
        std::os::unix::fs::symlink(real.join(GRIN_WALLET_DIR), decoy.join(GRIN_WALLET_DIR))
            .unwrap();
        let e = refuse_symlinked_data_dir(decoy.to_str().unwrap()).unwrap_err();
        assert_eq!(e.code, GrinErrorCode::InvalidArgument);
        // A link higher up the path is not the data directory itself.
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(refuse_symlinked_data_dir(link.to_str().unwrap()).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn data_dir_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let root = tempfile::tempdir().unwrap();

        let wallet_dir = root.path().join("new");
        let (dir, existed) = canonical_data_dir_create(wallet_dir.to_str().unwrap()).unwrap();
        assert!(!existed);
        assert_eq!(mode(&dir), 0o700);

        // A directory left with open permissions by an older version.
        let wallet_dir = root.path().join("old");
        let old = data_dir_path(wallet_dir.to_str().unwrap());
        std::fs::create_dir_all(&old).unwrap();
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o755)).unwrap();
        let dir = canonical_data_dir_existing(wallet_dir.to_str().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(mode(&dir), 0o700);
    }

    #[test]
    fn lease_is_exclusive_and_released() {
        let root = tempfile::tempdir().unwrap();
        let root_canon = std::fs::canonicalize(root.path()).unwrap();
        let p = root_canon.join("wallet_data");
        std::fs::create_dir(&p).unwrap();

        // Other spellings of the same directory: `dir/./` and, where the
        // platform allows it without privileges, a symlink to the parent.
        // Callers canonicalize first; on unix the key does not need that.
        #[cfg_attr(not(unix), allow(unused_mut))]
        let mut aliases = vec![p.join(".").join("")];
        #[cfg(unix)]
        {
            let link = root_canon.join("link");
            std::os::unix::fs::symlink(&root_canon, &link).unwrap();
            aliases.push(link.join("wallet_data"));
        }
        let key = DirKey::of(&p).unwrap();
        for alias in &aliases {
            let canon = std::fs::canonicalize(alias).unwrap();
            assert_eq!(DirKey::of(&canon).unwrap(), key, "{}", alias.display());
            #[cfg(unix)]
            assert_eq!(DirKey::of(alias).unwrap(), key, "{}", alias.display());
        }

        let a = DirLease::acquire(&p).unwrap();
        assert_eq!(*a.key(), key);
        assert_eq!(a.path(), p);
        let e = DirLease::acquire(&p).unwrap_err();
        assert_eq!(e.code, GrinErrorCode::WalletBusy);
        assert_eq!(
            e.details.unwrap()["wallet_dir"],
            p.to_string_lossy().as_ref()
        );
        for alias in &aliases {
            let canon = std::fs::canonicalize(alias).unwrap();
            let e = DirLease::acquire(&canon).unwrap_err();
            assert_eq!(e.code, GrinErrorCode::WalletBusy);
            #[cfg(unix)]
            {
                let e = DirLease::acquire(alias).unwrap_err();
                assert_eq!(e.code, GrinErrorCode::WalletBusy);
            }
        }
        drop(a);
        let _b = DirLease::acquire(&p).unwrap();
    }

    #[test]
    fn lease_needs_an_existing_directory() {
        let root = tempfile::tempdir().unwrap();
        let e = DirLease::acquire(&root.path().join("missing")).unwrap_err();
        assert_eq!(e.code, GrinErrorCode::Io);
    }

    #[cfg(unix)]
    #[test]
    fn lease_follows_the_directory_not_the_path() {
        let root = tempfile::tempdir().unwrap();
        let root_canon = std::fs::canonicalize(root.path()).unwrap();
        let p = root_canon.join("wallet_data");
        std::fs::create_dir(&p).unwrap();

        // Renamed while held: the new path is still busy.
        let a = DirLease::acquire(&p).unwrap();
        let moved = root_canon.join("moved");
        std::fs::rename(&p, &moved).unwrap();
        let e = DirLease::acquire(&moved).unwrap_err();
        assert_eq!(e.code, GrinErrorCode::WalletBusy);
        let first = a.key().clone();
        drop(a);
        std::fs::rename(&moved, &p).unwrap();

        // Removed and made again at the same path: a different directory.
        // The open handle keeps the old inode allocated so the filesystem
        // cannot hand the same number to the new directory.
        let a = DirLease::acquire(&p).unwrap();
        let pin = std::fs::File::open(&p).unwrap();
        std::fs::remove_dir(&p).unwrap();
        std::fs::create_dir(&p).unwrap();
        let b = DirLease::acquire(&p).unwrap();
        assert_ne!(*b.key(), first);
        assert_eq!(a.path(), b.path());
        drop(a);
        drop(pin);
        // Dropping the old lease leaves the new directory's lease in place.
        let e = DirLease::acquire(&p).unwrap_err();
        assert_eq!(e.code, GrinErrorCode::WalletBusy);
        drop(b);
        let _c = DirLease::acquire(&p).unwrap();
    }

    #[test]
    fn progress_pct() {
        let s = ScanProgressState::default();
        assert_eq!(s.progress_pct(), 0);
        s.start_height.store(1, Ordering::Release);
        s.tip_height.store(101, Ordering::Release);
        s.scanned_height.store(51, Ordering::Release);
        assert_eq!(s.progress_pct(), 50);
        s.scanned_height.store(500, Ordering::Release);
        assert_eq!(s.progress_pct(), 100);
    }

    #[test]
    fn scan_flags() {
        let s = ScanProgressState::default();
        // Cancel with no scan running does nothing.
        assert!(!s.request_cancel());
        assert!(!s.cancel_requested());
        assert_eq!(s.begin_scan(), ScanStart::Started);
        assert!(s.is_scanning());
        assert_eq!(s.begin_scan(), ScanStart::Busy);
        assert!(s.request_cancel());
        assert!(s.should_stop());
        s.end_scan();
        assert!(!s.is_scanning() && !s.cancel_requested());
        // A new scan starts clean even if a cancel slipped in at the end.
        assert_eq!(s.begin_scan(), ScanStart::Started);
        assert!(s.request_cancel());
        s.end_scan();
        assert_eq!(s.begin_scan(), ScanStart::Started);
        assert!(!s.should_stop());
        // Closing stops the running scan and blocks new ones.
        s.mark_closed();
        assert!(s.should_stop() && s.cancel_requested());
        s.end_scan();
        assert_eq!(s.begin_scan(), ScanStart::Closed);
        assert!(s.cancel_requested());
    }

    #[test]
    fn unknown_handles() {
        assert_eq!(
            get_session(0).unwrap_err().code,
            GrinErrorCode::InvalidHandle
        );
        assert_eq!(
            get_session(u64::MAX).unwrap_err().code,
            GrinErrorCode::InvalidHandle
        );
        assert!(remove_session(0).is_none());
    }
}
