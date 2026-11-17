//! In-process chain and wallets for tests. Only
//! built with the `test-utils` feature; release artifacts must not export
//! any `grin_test_*` symbol.
//!
//! Each `chain_dir` gets one `WalletProxy` over a real `grin_chain::Chain`
//! at `ChainTypes::AutomatedTesting` (coinbase maturity 3), running on its
//! own thread. Test wallets use `LocalWalletClient` through the same
//! `FfiNodeClient` enum, session registry and entry points as real wallets.
//!
//! Network choice: `grin_test_create_wallet` accepts every network so tests
//! can check keychain derivation and address prefixes, but the chain itself
//! is always AutomatedTesting. grin_chain validates blocks against the
//! calling thread's chain type (proof of work size, maturity, genesis), so
//! `grin_test_mine_blocks` builds blocks under AutomatedTesting whatever the
//! wallet's network is, and a Mainnet or Testnet wallet applies its own
//! coinbase maturity (1440 blocks) when computing balances. Funded flows
//! therefore use AutomatedTesting wallets, and the Mainnet + Testnet
//! concurrency test uses `grin_wallet_create` against an unreachable node.
//!
//! Harness limits: `LocalWalletClient` matches replies to requests only by
//! order, so do not run two node-touching calls on the same test wallet at
//! once; `WalletProxy` panics on an unknown client id, so every client is
//! registered before its wallet makes a node call; and `mine_lock` only
//! serializes `grin_test_mine_blocks`, while a `post_tx` handled on the proxy
//! thread also mines a block, so do not mine and broadcast on one chain at
//! the same moment.
//!
//! Breaking one of these rules used to hang the caller, because the proxy
//! drops a request it cannot answer. Every wait on the proxy thread is now
//! bounded by `PROXY_WAIT` and ends in an Internal error that names these
//! rules.

use std::cell::Cell;
use std::collections::HashMap;
use std::os::raw::c_char;
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use grin_chain::Chain;
use grin_core::core::{Transaction, TxKernel};
use grin_core::global::{self, ChainTypes};
use grin_keychain::ExtKeychain;
use grin_util::secp::key::SecretKey;
use grin_util::secp::pedersen;
use grin_wallet_impls::test_framework::{self, LocalWalletClient, WalletProxy};
use grin_wallet_libwallet::{Error as LibwalletError, NodeClient, NodeVersionInfo};
use serde::Serialize;

use crate::config::{
    chain_type_from_u8, FfiNodeClient, NodeSettings, DEFAULT_REQUEST_TIMEOUT_SECS,
};
use crate::error::{
    panic_message, read_opt_secret, read_secret, read_str, to_json, GrinError, GrinFfiResult,
};
use crate::handle::{
    canonical_data_dir_create, get_session, lookup_session, register_session, DirLease,
    WalletInstance, WalletLc, WalletSession,
};
use crate::lifecycle::{
    check_data_dir_name, open_backend, validate_mnemonic_words, OpenMode, SEED_FILE,
};

type Proxy = WalletProxy<'static, WalletLc, FfiNodeClient, ExtKeychain>;

/// Longest a caller waits for the proxy thread, for a reply to a node call
/// or for a wallet to be registered. Generous, because a proxy request can
/// mine a block, but finite, so a broken test fails instead of hanging.
const PROXY_WAIT: Duration = Duration::from_secs(120);

/// The harness rules (see the module comment) whose violation leaves a
/// request unanswered, named in the timeout errors.
const HARNESS_RULES: &str = "it probably broke a test harness rule: register every test \
    wallet before its first node call, run one node call at a time per test wallet, and do not \
    mine while a broadcast is in flight on the same chain (a transaction the chain rejects, such \
    as one that is already mined, has the same effect)";

/// Last error or panic of `WalletProxy::run`, shared with the clients so a
/// timeout can say what went wrong on the proxy thread.
type LastProxyFailure = Arc<Mutex<Option<String>>>;

fn proxy_timeout(what: &str, last_failure: &LastProxyFailure) -> String {
    let last = last_failure
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    let last = last.map_or_else(String::new, |e| format!(". Last proxy failure: {e}"));
    format!(
        "test proxy thread {what} within {} s; {HARNESS_RULES}{last}",
        PROXY_WAIT.as_secs()
    )
}

/// `AddWallet` registration states. The proxy thread moves PENDING to
/// REGISTERED before it registers the wallet; a caller that times out moves
/// PENDING to ABANDONED, and the proxy then drops the command instead.
const PENDING: u8 = 0;
const REGISTERED: u8 = 1;
const ABANDONED: u8 = 2;

enum ProxyCommand {
    AddWallet {
        client: LocalWalletClient,
        wallet: WalletInstance,
        mask: Option<SecretKey>,
        state: Arc<AtomicU8>,
        ack: mpsc::Sender<()>,
    },
}

/// Node client of a test wallet: `LocalWalletClient` with every reply wait
/// bounded by `PROXY_WAIT`. `LocalWalletClient` blocks in `recv()` with no
/// timeout, and the proxy never answers a request it failed on, so each
/// call that waits for the proxy runs on a short-lived helper thread. On a
/// timeout the helper is left blocked (it is a test, and the chain is
/// already broken) and the caller gets an Internal error.
#[derive(Clone)]
pub struct TestNodeClient {
    inner: LocalWalletClient,
    last_failure: LastProxyFailure,
    refuse_next_post: Arc<AtomicBool>,
    refuse_next_range: Arc<AtomicBool>,
}

impl TestNodeClient {
    fn bounded<T, F>(&self, method: &str, f: F) -> Result<T, LibwalletError>
    where
        T: Send + 'static,
        F: FnOnce(LocalWalletClient) -> Result<T, LibwalletError> + Send + 'static,
    {
        let inner = self.inner.clone();
        // The helper works under the caller's chain type.
        let chain_type = global::CHAIN_TYPE.with(Cell::get);
        let (tx, rx) = mpsc::channel();
        thread::Builder::new()
            .name("grin-test-request".to_owned())
            .spawn(move || {
                if let Some(c) = chain_type {
                    global::set_local_chain_type(c);
                }
                let _ = tx.send(catch_unwind(AssertUnwindSafe(|| f(inner))));
            })
            .map_err(|e| LibwalletError::GenericError(format!("test client thread: {e}")))?;
        match rx.recv_timeout(PROXY_WAIT) {
            Ok(Ok(res)) => res,
            // Panics in the client (it unwraps replies) reach the caller as
            // before, and ffi_guard turns them into InternalPanic.
            Ok(Err(payload)) => resume_unwind(payload),
            // GenericError maps to GrinErrorCode::Internal.
            Err(_) => Err(LibwalletError::GenericError(proxy_timeout(
                &format!("did not answer {method}"),
                &self.last_failure,
            ))),
        }
    }
}

impl NodeClient for TestNodeClient {
    fn node_url(&self) -> &str {
        self.inner.node_url()
    }

    fn set_node_url(&mut self, node_url: &str) {
        self.inner.set_node_url(node_url)
    }

    fn node_api_secret(&self) -> Option<String> {
        self.inner.node_api_secret()
    }

    fn set_node_api_secret(&mut self, node_api_secret: Option<String>) {
        self.inner.set_node_api_secret(node_api_secret)
    }

    fn get_version_info(&mut self) -> Option<NodeVersionInfo> {
        self.inner.get_version_info()
    }

    fn post_tx(&self, tx: &Transaction, fluff: bool) -> Result<(), LibwalletError> {
        if self.refuse_next_post.swap(false, Ordering::SeqCst) {
            return Err(LibwalletError::ClientCallback(
                "the test node refused the transaction".to_owned(),
            ));
        }
        let tx = tx.clone();
        self.bounded("post_tx", move |c| c.post_tx(&tx, fluff))
    }

    fn get_chain_tip(&self) -> Result<(u64, String), LibwalletError> {
        self.bounded("get_chain_tip", |c| c.get_chain_tip())
    }

    fn get_kernel(
        &mut self,
        excess: &pedersen::Commitment,
        min_height: Option<u64>,
        max_height: Option<u64>,
    ) -> Result<Option<(TxKernel, u64, u64)>, LibwalletError> {
        let excess = *excess;
        self.bounded("get_kernel", move |mut c| {
            c.get_kernel(&excess, min_height, max_height)
        })
    }

    fn get_outputs_from_node(
        &self,
        wallet_outputs: Vec<pedersen::Commitment>,
    ) -> Result<HashMap<pedersen::Commitment, (String, u64, u64)>, LibwalletError> {
        self.bounded("get_outputs_from_node", move |c| {
            c.get_outputs_from_node(wallet_outputs)
        })
    }

    #[allow(clippy::type_complexity)]
    fn get_outputs_by_pmmr_index(
        &self,
        start_height: u64,
        end_height: Option<u64>,
        max_outputs: u64,
    ) -> Result<
        (
            u64,
            u64,
            Vec<(pedersen::Commitment, pedersen::RangeProof, bool, u64, u64)>,
        ),
        LibwalletError,
    > {
        self.bounded("get_outputs_by_pmmr_index", move |c| {
            c.get_outputs_by_pmmr_index(start_height, end_height, max_outputs)
        })
    }

    fn height_range_to_pmmr_indices(
        &self,
        start_height: u64,
        end_height: Option<u64>,
    ) -> Result<(u64, u64), LibwalletError> {
        if self.refuse_next_range.swap(false, Ordering::SeqCst) {
            return Err(LibwalletError::ClientCallback(
                "the test node refused the height range".to_owned(),
            ));
        }
        self.bounded("height_range_to_pmmr_indices", move |c| {
            c.height_range_to_pmmr_indices(start_height, end_height)
        })
    }
}

/// Sets the calling thread's chain type and puts the previous thread-local
/// value back when dropped, including while unwinding from a panic.
struct ChainTypeGuard(Option<ChainTypes>);

impl ChainTypeGuard {
    fn set(chain_type: ChainTypes) -> Self {
        let previous = global::CHAIN_TYPE.with(Cell::get);
        global::set_local_chain_type(chain_type);
        ChainTypeGuard(previous)
    }
}

impl Drop for ChainTypeGuard {
    fn drop(&mut self) {
        let previous = self.0;
        global::CHAIN_TYPE.with(|c| c.set(previous));
    }
}

/// One in-process chain and the proxy thread serving it.
pub struct TestChain {
    pub chain_dir: PathBuf,
    pub chain: Arc<Chain>,
    make_client: Box<dyn Fn(&str) -> LocalWalletClient + Send + Sync>,
    commands: mpsc::Sender<ProxyCommand>,
    running: Arc<AtomicBool>,
    last_failure: LastProxyFailure,
    /// Makes the next broadcast on this chain fail without reaching it.
    refuse_next_post: Arc<AtomicBool>,
    /// Makes the next height range request on this chain fail.
    refuse_next_range: Arc<AtomicBool>,
    /// Serializes block production so two callers never build on the same tip.
    mine_lock: Mutex<()>,
}

impl TestChain {
    fn client(&self, client_id: &str) -> TestNodeClient {
        TestNodeClient {
            inner: (self.make_client)(client_id),
            last_failure: self.last_failure.clone(),
            refuse_next_post: self.refuse_next_post.clone(),
            refuse_next_range: self.refuse_next_range.clone(),
        }
    }

    /// `WalletProxy::run` owns the proxy while it loops, so new wallets are
    /// handed to the proxy thread, which stops the loop, registers them and
    /// starts it again. The stop flag is re-sent until the thread confirms,
    /// because `run` sets it back to true on entry. After `PROXY_WAIT` the
    /// command is abandoned, so the proxy never registers (and keeps open)
    /// a wallet whose caller has already given up on it.
    fn add_wallet(
        &self,
        client: &TestNodeClient,
        wallet: WalletInstance,
        mask: Option<SecretKey>,
    ) -> Result<(), GrinError> {
        let (ack, ack_rx) = mpsc::channel();
        let state = Arc::new(AtomicU8::new(PENDING));
        self.commands
            .send(ProxyCommand::AddWallet {
                client: client.inner.clone(),
                wallet,
                mask,
                state: state.clone(),
                ack,
            })
            .map_err(|_| GrinError::internal("test proxy thread has stopped"))?;
        let deadline = Instant::now() + PROXY_WAIT;
        let stopped = loop {
            self.running.store(false, Ordering::SeqCst);
            match ack_rx.recv_timeout(Duration::from_millis(20)) {
                Ok(()) => return Ok(()),
                Err(RecvTimeoutError::Timeout) if Instant::now() < deadline => continue,
                Err(RecvTimeoutError::Timeout) => break false,
                Err(RecvTimeoutError::Disconnected) => break true,
            }
        };
        match state.compare_exchange(PENDING, ABANDONED, Ordering::AcqRel, Ordering::Acquire) {
            // Registered between the last wait and now. The proxy finishes
            // registering before it serves another request, so the wallet
            // can be used.
            Err(REGISTERED) => Ok(()),
            _ if stopped => Err(GrinError::internal("test proxy thread has stopped")),
            _ => Err(GrinError::internal(proxy_timeout(
                "did not register the wallet",
                &self.last_failure,
            ))),
        }
    }
}

/// Closes the backend of a wallet the proxy did not register. A queued
/// command may still hold a clone of the instance, so dropping our `Arc`
/// would not close it; this runs while the caller still holds the lease.
fn close_unregistered(wallet: &WalletInstance) {
    let mut w = wallet.lock();
    match w.lc_provider() {
        Ok(lc) => {
            if let Err(e) = lc.close_wallet(None) {
                log::warn!("test wallet: close_wallet failed: {e}");
            }
        }
        Err(e) => log::warn!("test wallet: no lifecycle provider: {e}"),
    }
}

static TEST_CHAINS: LazyLock<Mutex<HashMap<PathBuf, Arc<TestChain>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn proxy_thread(
    mut proxy: Proxy,
    commands: mpsc::Receiver<ProxyCommand>,
    last_failure: LastProxyFailure,
) {
    global::set_local_chain_type(ChainTypes::AutomatedTesting);
    loop {
        loop {
            match commands.try_recv() {
                Ok(ProxyCommand::AddWallet {
                    client,
                    wallet,
                    mask,
                    state,
                    ack,
                }) => {
                    let claimed = state
                        .compare_exchange(PENDING, REGISTERED, Ordering::AcqRel, Ordering::Acquire)
                        .is_ok();
                    // An abandoned command is dropped here with its clone of
                    // the wallet; the caller has closed the backend.
                    if claimed {
                        let id = client.id.clone();
                        proxy.add_wallet(&id, client.get_send_instance(), wallet, mask);
                        let _ = ack.send(());
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return,
            }
        }
        // A failed or panicked `run` leaves its current request unanswered;
        // the waiting client times out and reports this message.
        let failure = match catch_unwind(AssertUnwindSafe(|| proxy.run())) {
            Ok(Ok(())) => None,
            Ok(Err(e)) => {
                log::warn!("test proxy: {e}");
                Some(e.to_string())
            }
            Err(p) => {
                let message = panic_message(p.as_ref());
                log::error!("test proxy panicked: {message}");
                Some(format!("panic: {message}"))
            }
        };
        if failure.is_some() {
            *last_failure.lock().unwrap_or_else(PoisonError::into_inner) = failure;
        }
    }
}

/// Returns the chain for `chain_dir`, creating it and its proxy thread on
/// first use. Leaves this thread's chain type at AutomatedTesting.
fn chain_for(chain_dir: &str) -> Result<Arc<TestChain>, GrinError> {
    std::fs::create_dir_all(chain_dir)?;
    let key = std::fs::canonicalize(chain_dir)?;
    let mut chains = TEST_CHAINS.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(c) = chains.get(&key) {
        return Ok(c.clone());
    }
    let dir = key
        .to_str()
        .ok_or_else(|| GrinError::invalid_argument("chain_dir is not a valid UTF-8 path"))?;
    // Sets this thread's chain type to AutomatedTesting and mines genesis.
    let proxy: Proxy = WalletProxy::new(dir);
    let chain = proxy.chain.clone();
    let proxy_tx = proxy.tx.clone();
    let running = proxy.running.clone();
    let last_failure = LastProxyFailure::default();
    let thread_failure = last_failure.clone();
    let (commands, commands_rx) = mpsc::channel();
    thread::Builder::new()
        .name("grin-test-proxy".to_owned())
        .spawn(move || proxy_thread(proxy, commands_rx, thread_failure))?;
    let test_chain = Arc::new(TestChain {
        chain_dir: key.clone(),
        chain,
        make_client: Box::new(move |id| LocalWalletClient::new(id, proxy_tx.clone())),
        commands,
        running,
        last_failure,
        refuse_next_post: Arc::new(AtomicBool::new(false)),
        refuse_next_range: Arc::new(AtomicBool::new(false)),
        mine_lock: Mutex::new(()),
    });
    chains.insert(key, test_chain.clone());
    Ok(test_chain)
}

#[derive(Serialize)]
struct HandleOut {
    handle: u64,
}

#[derive(Serialize)]
struct HeightOut {
    height: u64,
}

/// Creates (or opens, if `wallet.seed` exists) a wallet in
/// `<wallet_dir>/wallet_data` connected to the in-process chain in
/// `chain_dir` as `client_id`. `is_new_wallet` works as in
/// `grin_wallet_create` and is ignored when the wallet is opened. Returns
/// `{"handle": u64}`.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_test_create_wallet(
    chain_dir: *const c_char,
    wallet_dir: *const c_char,
    client_id: *const c_char,
    network: u8,
    mnemonic: *const c_char,
    password: *const c_char,
    is_new_wallet: bool,
) -> GrinFfiResult {
    ffi_guard! {
        let chain_type = chain_type_from_u8(network)?;
        let chain_dir = read_str(&chain_dir, "chain_dir")?;
        let wallet_dir = read_str(&wallet_dir, "wallet_dir")?;
        let client_id = read_str(&client_id, "client_id")?;
        if client_id.is_empty() || client_id == "node" {
            return Err(GrinError::invalid_argument(
                "client_id must be non-empty and not \"node\"",
            ));
        }
        let mnemonic = read_opt_secret(mnemonic, "mnemonic")?;
        let password = read_secret(password, "password")?;
        if let Some(m) = &mnemonic {
            validate_mnemonic_words(m)?;
        }

        let test_chain = chain_for(chain_dir)?;
        // chain_for may have switched this thread to AutomatedTesting.
        global::set_local_chain_type(chain_type);

        let (data_dir, existed) = canonical_data_dir_create(wallet_dir)?;
        check_data_dir_name(&data_dir)?;
        let lease = DirLease::acquire(&data_dir)?;
        let mode = if data_dir.join(SEED_FILE).exists() {
            OpenMode::Open
        } else {
            OpenMode::Create {
                mnemonic,
                is_new: is_new_wallet,
            }
        };
        let client = test_chain.client(client_id);
        let opened = open_backend(FfiNodeClient::Local(client.clone()), &data_dir, password, mode)
            .and_then(|(wallet, mask)| {
                if let Err(e) = test_chain.add_wallet(&client, wallet.clone(), mask.clone()) {
                    // Closed here, before `lease` is released on return.
                    close_unregistered(&wallet);
                    return Err(e);
                }
                Ok((wallet, mask))
            });
        let (wallet, mask) = match opened {
            Ok(v) => v,
            Err(e) => {
                if !existed {
                    let _ = std::fs::remove_dir_all(&data_dir);
                }
                return Err(e);
            }
        };

        let node = NodeSettings {
            url: format!("local:{client_id}"),
            api_secret: None,
            socks_proxy: None,
            timeout: Duration::from_secs(DEFAULT_REQUEST_TIMEOUT_SECS),
            enabled: true,
        };
        let handle = register_session(|h| {
            let mut s = WalletSession::new(h, chain_type, wallet, mask, node, lease);
            s.test_chain = Some(test_chain);
            s
        });
        to_json(&HandleOut { handle })
    }
}

/// Mines `count` blocks whose coinbase goes to `handle`'s wallet. Returns
/// `{"height": u64}`, the chain height afterwards.
#[no_mangle]
pub extern "C" fn grin_test_mine_blocks(handle: u64, count: u64) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        let test_chain = session
            .test_chain
            .clone()
            .ok_or_else(|| GrinError::invalid_argument("handle is not a test wallet"))?;
        let count = usize::try_from(count)
            .map_err(|_| GrinError::invalid_argument("count is too large"))?;
        let mask = session.mask();
        let height = {
            let _mining = test_chain
                .mine_lock
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            {
                // Blocks are built and validated with the chain's own
                // parameters. The guard puts this thread's chain type back
                // (the session's, set by get_session) even if mining panics.
                let _chain_type = ChainTypeGuard::set(ChainTypes::AutomatedTesting);
                test_framework::award_blocks_to_wallet(
                    &test_chain.chain,
                    session.wallet.clone(),
                    mask.as_ref(),
                    count,
                    false,
                )?;
            }
            test_chain
                .chain
                .head()
                .map_err(|e| GrinError::internal(format!("chain head: {e}")))?
                .height
        };
        to_json(&HeightOut { height })
    }
}

/// Panics inside the guard so callers can check InternalPanic handling.
#[no_mangle]
pub extern "C" fn grin_test_panic() -> GrinFfiResult {
    ffi_guard! {
        panic!("grin_test_panic")
    }
}

/// Makes the next broadcast on `handle`'s test chain fail with a node
/// error, as an unreachable or unwilling node would. The transaction never
/// reaches the chain. Returns false when `handle` is not a test wallet.
/// Plain Rust, not exported.
pub fn refuse_next_post(handle: u64) -> bool {
    let Some(chain) = lookup_session(handle).and_then(|s| s.test_chain.clone()) else {
        return false;
    };
    chain.refuse_next_post.store(true, Ordering::SeqCst);
    true
}

/// Makes the next height range request on `handle`'s test chain fail with a
/// node error. A scan asks for one range per batch, so this fails the next
/// batch. Returns false when `handle` is not a test wallet. Plain Rust, not
/// exported.
pub fn refuse_next_range(handle: u64) -> bool {
    let Some(chain) = lookup_session(handle).and_then(|s| s.test_chain.clone()) else {
        return false;
    };
    chain.refuse_next_range.store(true, Ordering::SeqCst);
    true
}

/// Clones a registered session's `Arc`, standing in for an in-flight call
/// that outlives `grin_wallet_close`. Plain Rust, not exported.
pub fn retain_session(handle: u64) -> Option<Arc<WalletSession>> {
    lookup_session(handle)
}

/// Called by `grin_wallet_scan` after each batch is saved, with the last
/// height of that batch.
pub type AfterBatch = Box<dyn Fn(u64) + Send + Sync>;

/// Per-session scan knobs for tests. The test chain is far shorter than one
/// production batch, so tests shrink the batch and use the callback to act
/// at an exact batch boundary.
#[derive(Default)]
pub struct ScanTestHooks {
    /// Heights per scan batch; 0 keeps the production size.
    pub(crate) batch_heights: AtomicU64,
    pub(crate) after_batch: Mutex<Option<AfterBatch>>,
}

impl ScanTestHooks {
    pub(crate) fn run_after_batch(&self, height: u64) {
        let hook = self
            .after_batch
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(f) = hook.as_ref() {
            f(height);
        }
    }
}

/// Sets the scan batch size (0 for the production size) and the per-batch
/// callback of a registered session. Returns false for an unknown handle.
/// Plain Rust, not exported.
pub fn set_scan_test_hooks(
    handle: u64,
    batch_heights: u64,
    after_batch: Option<AfterBatch>,
) -> bool {
    let Some(session) = lookup_session(handle) else {
        return false;
    };
    session
        .scan_hooks
        .batch_heights
        .store(batch_heights, Ordering::Release);
    *session
        .scan_hooks
        .after_batch
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = after_batch;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chain_type_guard_restores_after_a_panic() {
        global::set_local_chain_type(ChainTypes::Mainnet);
        let res = catch_unwind(|| {
            let _guard = ChainTypeGuard::set(ChainTypes::AutomatedTesting);
            assert_eq!(global::get_chain_type(), ChainTypes::AutomatedTesting);
            panic!("mining failed");
        });
        assert!(res.is_err());
        assert_eq!(global::get_chain_type(), ChainTypes::Mainnet);
    }
}
