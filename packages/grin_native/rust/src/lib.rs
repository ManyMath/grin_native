//! C ABI over grin-wallet.
//!
//! There is no process-wide chain type: every entry point sets the calling
//! thread's chain type from its `network` argument, its config, or the
//! session it looks up.

// The entry points that take raw pointers are `unsafe`. Their safety
// contracts are plain comments above each function, because cbindgen copies
// doc comments into include/grin_ffi.h and a `# Safety` doc section would
// change the header.
#![allow(clippy::missing_safety_doc)]

#[macro_use]
pub mod error;

pub mod address;
pub mod balance;
pub mod config;
pub mod handle;
pub mod lifecycle;
pub mod logging;
pub mod proof;
pub mod scan;
pub mod sidecar;
pub mod slatepack;
#[cfg(feature = "test-utils")]
pub mod test_support;
pub mod transaction;

pub use crate::address::{grin_address_validate, grin_wallet_get_address};
pub use crate::balance::{
    grin_node_test_connection, grin_wallet_get_balance, grin_wallet_get_chain_height,
};
pub use crate::error::{
    grin_ffi_result_free, grin_string_free, GrinError, GrinErrorCode, GrinFfiResult,
};
pub use crate::lifecycle::{
    grin_mnemonic_generate, grin_mnemonic_validate, grin_wallet_change_password, grin_wallet_close,
    grin_wallet_close_finalizer, grin_wallet_create, grin_wallet_delete, grin_wallet_get_mnemonic,
    grin_wallet_open, grin_wallet_update_network,
};
pub use crate::logging::grin_init_logs;
pub use crate::proof::{grin_payment_proof_export, grin_payment_proof_verify};
pub use crate::scan::{
    grin_wallet_get_last_scanned_height, grin_wallet_scan, grin_wallet_scan_cancel,
    grin_wallet_scan_progress,
};
pub use crate::slatepack::grin_slatepack_decode;
#[cfg(feature = "test-utils")]
pub use crate::test_support::{grin_test_create_wallet, grin_test_mine_blocks, grin_test_panic};
pub use crate::transaction::{
    grin_tx_cancel, grin_tx_estimate_fee, grin_tx_finalize_invoice, grin_tx_finalize_slatepack,
    grin_tx_init_send, grin_tx_issue_invoice, grin_tx_process_invoice, grin_tx_receive_slatepack,
    grin_tx_repost, grin_tx_send_http, grin_txs_get,
};
