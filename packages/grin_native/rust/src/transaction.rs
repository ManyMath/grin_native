//! Transaction entry points: fee estimate, history, the S1/S2/S3 and
//! I1/I2/I3 Slatepack flows, the synchronous HTTP send, repost and cancel.
//!
//! Locking: libwallet's `&mut WalletBackend` functions run with the wallet
//! mutex held (`with_backend`). Functions that take the wallet `Arc`
//! (`create_slatepack_message`, `retrieve_txs`, `cancel_tx`, ...) lock it
//! themselves, and network calls (`post_tx`, the HTTP send) run with it
//! released. `post_tx` must not hold it: the test chain mines a posted
//! transaction at once and locks the posting wallet to pay it the coinbase.
//!
//! Sidecar writes are best effort: a failure is
//! logged and never fails the call.

use std::collections::HashMap;
use std::os::raw::c_char;

use grin_core::consensus::{INPUT_WEIGHT, KERNEL_WEIGHT, OUTPUT_WEIGHT};
use grin_core::core::Weighting;
use grin_core::global;
use grin_keychain::ExtKeychain;
use grin_util::secp::key::SecretKey;
use grin_util::ToHex;
use grin_wallet_impls::{HttpSlateSender, SlateSender};
use grin_wallet_libwallet::api_impl::{foreign, owner};
use grin_wallet_libwallet::{
    Context, Error as LibwalletError, InitTxArgs, IssueInvoiceTxArgs, OutputStatus, Slate,
    SlateState, SlatepackAddress, StoredProofInfo, TxLogEntry, TxLogEntryType, WalletBackend,
};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::address::parse_address;
use crate::config::FfiNodeClient;
use crate::error::{
    json_u64, read_opt_nonempty, read_opt_str, read_str, to_json, GrinError, GrinErrorCode,
    GrinFfiResult, MAX_HEIGHT,
};
use crate::handle::{get_session, WalletSession};
use crate::sidecar::{Sidecar, TxSidecarEntry};
use crate::slatepack::{
    address_string, decode_with_wallet, kernel_excess_hex, parse_slatepack_address, require_state,
    slate_error, slate_fee, state_name,
};

type Backend = WalletBackend<FfiNodeClient, ExtKeychain>;

/// Address index used for our own slatepack address, payment proofs and
/// decryption. libwallet only uses index 0 for payment proofs.
const ADDRESS_INDEX: u32 = 0;

/// libwallet's default when the caller gives no `min_confirms`.
const DEFAULT_MIN_CONFIRMS: u64 = 10;

/// Directory libwallet keeps transactions in, inside `wallet_data`
/// (`TX_SAVE_DIR` in libwallet's private backend module). Locking outputs
/// already writes the unsigned transaction there; finalizing overwrites it.
const STORED_TX_DIR: &str = "saved_txs";

/// Largest `ttl_blocks` accepted, about 1,900 years of one-minute blocks.
/// libwallet adds it to the chain height without an overflow check.
const MAX_TTL_BLOCKS: u64 = 1_000_000_000;

/// Largest amount accepted, in nanogrin (2^63 - 1, the same limit the Dart
/// package applies). Grin's supply has no cap, so this is only an overflow
/// guard: libwallet adds the fee to the amount without an overflow check,
/// and any real amount is far below it.
const MAX_AMOUNT: u64 = u64::MAX / 2;

/// Refuses an amount of 0 or above `MAX_AMOUNT`.
fn check_amount(amount: u64) -> Result<(), GrinError> {
    if amount == 0 {
        return Err(GrinError::invalid_argument(
            "amount must be greater than zero",
        ));
    }
    if amount > MAX_AMOUNT {
        return Err(GrinError::invalid_argument(format!(
            "amount must be at most {MAX_AMOUNT} nanogrin, got {amount}"
        )));
    }
    Ok(())
}

/// Refuses a given `ttl_blocks` of 0 or above `MAX_TTL_BLOCKS`.
fn check_ttl_blocks(ttl_blocks: Option<u64>) -> Result<(), GrinError> {
    match ttl_blocks {
        Some(0) => Err(GrinError::invalid_argument(
            "ttl_blocks must be greater than zero",
        )),
        Some(t) if t > MAX_TTL_BLOCKS => Err(GrinError::invalid_argument(format!(
            "ttl_blocks must be at most {MAX_TTL_BLOCKS}, got {t}"
        ))),
        _ => Ok(()),
    }
}

/// Runs `f` with the wallet mutex held and the keychain mask at hand.
fn with_backend<T>(
    session: &WalletSession,
    f: impl FnOnce(&mut Backend, Option<&SecretKey>) -> Result<T, GrinError>,
) -> Result<T, GrinError> {
    let mask = session.mask();
    let mut w = session.wallet.lock();
    let backend = w.lc_provider()?.wallet_inst()?;
    f(backend, mask.as_ref())
}

fn parse_args<T: DeserializeOwned>(ptr: *const c_char, name: &str) -> Result<T, GrinError> {
    Ok(serde_json::from_str(read_str(&ptr, name)?)?)
}

/// Adds the keys of `extra` to an error's details, keeping any key that is
/// already there.
fn add_details(mut e: GrinError, extra: serde_json::Value) -> GrinError {
    use serde_json::Value;
    match e.details.as_mut() {
        Some(Value::Object(have)) => {
            if let Value::Object(more) = extra {
                for (k, v) in more {
                    have.entry(k).or_insert(v);
                }
            }
        }
        Some(_) => {}
        None => e.details = Some(extra),
    }
    e
}

/// Adds `{"slate_id"}` to an error raised after the wallet recorded the
/// transaction, so the caller can still cancel or repost it.
fn with_slate_id(e: GrinError, slate_id: &Uuid) -> GrinError {
    add_details(e, serde_json::json!({ "slate_id": slate_id.to_string() }))
}

/// This wallet's log entries for a slate id.
fn entries_for_slate(w: &mut Backend, slate_id: &Uuid) -> Result<Vec<TxLogEntry>, GrinError> {
    Ok(w.tx_log_iter()?
        .filter_map(Result::ok)
        .filter(|t| t.tx_slate_id.as_ref() == Some(slate_id))
        .collect())
}

/// The transaction context stored for a slate id, if there is one.
fn stored_context(w: &mut Backend, mask: Option<&SecretKey>, slate_id: &Uuid) -> Option<Context> {
    w.get_private_context(mask, slate_id.as_bytes()).ok()
}

/// Deletes the context of a transaction that recorded nothing else. Best
/// effort: a context left behind holds no funds.
fn forget_context(w: &mut Backend, mask: Option<&SecretKey>, slate_id: &Uuid) {
    let done = w.batch(mask).and_then(|mut batch| {
        batch.delete_private_context(slate_id.as_bytes())?;
        batch.commit()
    });
    if let Err(e) = done {
        log::warn!("could not delete an unused transaction context: {e}");
    }
}

fn is_invoice_state(state: &Option<SlateState>) -> bool {
    matches!(
        state,
        Some(SlateState::Invoice1 | SlateState::Invoice2 | SlateState::Invoice3)
    )
}

/// Refuses an S2 whose slate id this wallet uses for something other than a
/// send it started. libwallet finds the context by slate id alone, so
/// without this an S2 could be finalized against the context of an invoice.
/// A send has a TxSent entry, or (late-locked) no entry and a context that
/// still holds the send arguments. An id the wallet knows nothing about
/// passes; libwallet reports that one as not found.
fn check_send_role(
    w: &mut Backend,
    mask: Option<&SecretKey>,
    slate_id: &Uuid,
) -> Result<(), GrinError> {
    let wrong = || {
        slate_error("this wallet has no send waiting for this slate; its id belongs to another kind of transaction")
    };
    let entries = entries_for_slate(w, slate_id)?;
    if let Some(sent) = entries.iter().find(|t| t.tx_type == TxLogEntryType::TxSent) {
        return if is_invoice_state(&sent.tx_slate_state) {
            Err(wrong())
        } else {
            Ok(())
        };
    }
    match stored_context(w, mask, slate_id) {
        Some(context) if context.late_lock_args.is_none() => Err(wrong()),
        _ => Ok(()),
    }
}

/// Refuses an I2 whose slate id is not an invoice this wallet issued (a
/// TxReceived entry in an invoice state). The invoice path finalizes
/// without a payment proof check, so a send's context must never reach it.
/// An id the wallet knows nothing about passes; libwallet reports that one
/// as not found.
fn check_invoice_role(
    w: &mut Backend,
    mask: Option<&SecretKey>,
    slate_id: &Uuid,
) -> Result<(), GrinError> {
    let entries = entries_for_slate(w, slate_id)?;
    if entries
        .iter()
        .any(|t| t.tx_type == TxLogEntryType::TxReceived && is_invoice_state(&t.tx_slate_state))
    {
        return Ok(());
    }
    if stored_context(w, mask, slate_id).is_some() {
        return Err(slate_error(
            "this slate is not an invoice this wallet issued; its id belongs to another kind of transaction",
        ));
    }
    Ok(())
}

/// Checks that this wallet can pay an invoice with this slate id: it must
/// not know the id at all, or know it only as its own unpaid invoice (paying
/// itself). libwallet would otherwise merge the payment into whatever
/// context the id already has. Returns whether the invoice is its own.
fn check_payable(
    w: &mut Backend,
    mask: Option<&SecretKey>,
    slate_id: &Uuid,
) -> Result<bool, GrinError> {
    let taken = || {
        GrinError::new(
            GrinErrorCode::Transaction,
            "this wallet already has a transaction with this slate id",
        )
    };
    let entries = entries_for_slate(w, slate_id)?;
    if entries.is_empty() {
        return if stored_context(w, mask, slate_id).is_some() {
            Err(taken())
        } else {
            Ok(false)
        };
    }
    let own_unpaid = entries.iter().all(|t| {
        t.tx_type == TxLogEntryType::TxReceived
            && t.tx_slate_state == Some(SlateState::Invoice1)
            && !t.confirmed
    });
    if own_unpaid {
        Ok(true)
    } else {
        Err(taken())
    }
}

/// Refuses to lock a send whose selected inputs are no longer free. The
/// synchronous send selects its inputs, releases the wallet for the round
/// trip and locks afterwards, and libwallet locks whatever the context
/// names without looking at the outputs again.
fn check_inputs_free(
    w: &mut Backend,
    mask: Option<&SecretKey>,
    slate_id: &Uuid,
) -> Result<(), GrinError> {
    let context = w.get_private_context(mask, slate_id.as_bytes())?;
    let free = context.input_ids.iter().all(|(id, mmr_index, _)| {
        w.get(id, mmr_index)
            .is_ok_and(|o| matches!(o.status, OutputStatus::Unspent | OutputStatus::Unconfirmed))
    });
    if free {
        Ok(())
    } else {
        Err(GrinError::new(
            GrinErrorCode::Transaction,
            "the wallet's outputs changed while the recipient was answering; nothing was locked",
        ))
    }
}

/// Gives up a synchronous send whose finalization failed. The recipient's
/// answer cannot be asked for again, so keeping the inputs locked would
/// only leave the caller a transaction to cancel. Nothing was broadcast and
/// the wallet lock is held, so the send is cancelled from stored state:
/// the error then carries `{"slate_id", "released": true}`. If the cancel
/// fails the inputs stay locked and the error carries the slate id alone.
/// A late-locked send that failed before locking has no entry; its context
/// is deleted and the error carries no slate id.
fn release_send(
    w: &mut Backend,
    mask: Option<&SecretKey>,
    slate_id: &Uuid,
    e: GrinError,
) -> GrinError {
    let sent = match entries_for_slate(w, slate_id) {
        Ok(entries) => entries
            .into_iter()
            .find(|t| t.tx_type == TxLogEntryType::TxSent),
        Err(_) => return with_slate_id(e, slate_id),
    };
    let Some(sent) = sent else {
        forget_context(w, mask, slate_id);
        return e;
    };
    match owner::cancel_tx_stored(w, mask, Some(sent.id), None) {
        Ok(()) => add_details(
            e,
            serde_json::json!({ "slate_id": slate_id.to_string(), "released": true }),
        ),
        Err(cancel) => {
            log::warn!("could not release a failed send: {cancel}");
            with_slate_id(e, slate_id)
        }
    }
}

/// Refuses a slate from a counterparty whose amount or TTL is beyond what
/// this API reports (2^63 - 1): the history would otherwise hold a value
/// its JSON readers cannot represent.
fn check_foreign_bounds(slate: &Slate) -> Result<(), GrinError> {
    if slate.amount > MAX_AMOUNT {
        return Err(slate_error(format!(
            "the slate's amount {} is out of range",
            slate.amount
        )));
    }
    if slate.ttl_cutoff_height > MAX_HEIGHT {
        return Err(slate_error(format!(
            "the slate's TTL cutoff height {} is out of range",
            slate.ttl_cutoff_height
        )));
    }
    Ok(())
}

/// Best-effort sidecar update.
fn remember(
    session: &WalletSession,
    slate_id: Uuid,
    armored: Option<String>,
    counterparty: Option<String>,
) {
    let entry = TxSidecarEntry {
        armored_slatepack: armored,
        counterparty_address: counterparty,
    };
    if let Err(e) = Sidecar::upsert(&session.data_dir, slate_id, entry) {
        log::warn!("Sidecar write failed: {e}");
    }
}

/// Amount a log entry moved, the way libwallet computes it for payment
/// proofs: received amount, or sent amount without the fee.
fn logged_amount(entry: &TxLogEntry) -> u64 {
    if entry.amount_credited >= entry.amount_debited {
        entry.amount_credited - entry.amount_debited
    } else {
        let fee = entry.fee.map(|f| f.fee()).unwrap_or(0);
        (entry.amount_debited - entry.amount_credited).saturating_sub(fee)
    }
}

/// Checks a slate a counterparty returned against what this wallet issued,
/// before anything is signed. The kernel must still be plain: this wallet
/// only issues plain kernels, and signing a HeightLocked or NRD one the
/// other side slipped in would lock the funds behind a height this wallet
/// never chose. The TTL must be the one this wallet set, where it is known
/// (`issued_ttl` is None when it is not, as for an invoice the payer sets
/// it on). libwallet restores the amount and fee from the stored context
/// itself, so those need no check here.
fn check_returned_slate(returned: &Slate, issued_ttl: Option<u64>) -> Result<(), GrinError> {
    if returned.kernel_features != 0 || returned.kernel_features_args.is_some() {
        return Err(slate_error(format!(
            "the returned slate changed the kernel features to {}; only a plain kernel is accepted",
            returned.kernel_features
        )));
    }
    if let Some(ttl) = issued_ttl {
        if returned.ttl_cutoff_height != ttl {
            return Err(slate_error(format!(
                "the returned slate changed the TTL cutoff height from {ttl} to {}",
                returned.ttl_cutoff_height
            )));
        }
    }
    Ok(())
}

/// Checks the payment proof a recipient returned on an S2 against the one
/// this wallet asked for in the S1. With a proof requested, the S2 must carry
/// one for exactly the requested address, signed, with this wallet's sender
/// address; without one, the S2 must carry none. The Slatepack flow gets
/// this from libwallet because it locks with the S1; the synchronous send
/// locks with the S2, so it has to check first.
fn check_returned_proof(s1: &Slate, s2: &Slate) -> Result<(), GrinError> {
    let refused = |what: &str| GrinError::new(GrinErrorCode::Transaction, what.to_owned());
    match (&s1.payment_proof, &s2.payment_proof) {
        (None, None) => Ok(()),
        (None, Some(_)) => Err(refused(
            "the recipient added a payment proof that was not requested",
        )),
        (Some(_), None) => Err(refused("the recipient dropped the requested payment proof")),
        (Some(asked), Some(got)) => {
            if got.receiver_address != asked.receiver_address {
                return Err(refused(
                    "the recipient answered with a payment proof for an address other than the one requested",
                ));
            }
            if got.sender_address != asked.sender_address {
                return Err(refused(
                    "the recipient changed the sender address of the payment proof",
                ));
            }
            if got.receiver_signature.is_none() {
                return Err(refused(
                    "the recipient did not sign the requested payment proof",
                ));
            }
            Ok(())
        }
    }
}

/// TTL this wallet issued the send with: the TxSent entry's cutoff height
/// (0 when it set none), or None when no entry exists yet (a late-locked
/// send is only recorded at finalization).
fn issued_ttl_for_slate(w: &mut Backend, slate_id: &Uuid) -> Result<Option<u64>, GrinError> {
    Ok(w.tx_log_iter()?
        .filter_map(Result::ok)
        .find(|t| t.tx_slate_id.as_ref() == Some(slate_id) && t.tx_type == TxLogEntryType::TxSent)
        .map(|t| t.ttl_cutoff_height.unwrap_or(0)))
}

/// Amount of this wallet's log entry for `slate_id`, 0 if there is none.
fn amount_for_slate(w: &mut Backend, slate_id: &Uuid) -> Result<u64, GrinError> {
    Ok(w.tx_log_iter()?
        .filter_map(Result::ok)
        .find(|t| t.tx_slate_id.as_ref() == Some(slate_id))
        .map(|t| logged_amount(&t))
        .unwrap_or(0))
}

/// Broadcasts a finalized slate through the wallet's node client, with the
/// wallet mutex released. A failure carries `{"slate_id", "finalized":
/// true}`: the transaction is complete and stored, and can be reposted.
fn post_slate(session: &WalletSession, slate: &Slate, fluff: bool) -> Result<(), GrinError> {
    let tx = slate.tx_or_err()?;
    let client = session.node_client()?;
    owner::post_tx(&client, tx, fluff).map_err(|e| {
        GrinError::new(
            GrinErrorCode::Node,
            format!("the transaction is finalized but could not be broadcast: {e}"),
        )
        .with_details(serde_json::json!({
            "slate_id": slate.id.to_string(),
            "finalized": true,
        }))
    })
}

/// Reads `tx_id` (negative means absent) and `slate_id` (NULL or empty
/// means absent). At least one must be given.
pub(crate) fn tx_selector(
    tx_id: i64,
    slate_id: *const c_char,
) -> Result<(Option<u32>, Option<Uuid>), GrinError> {
    let id = if tx_id < 0 {
        None
    } else {
        Some(
            u32::try_from(tx_id)
                .map_err(|_| GrinError::invalid_argument("tx_id is larger than a u32"))?,
        )
    };
    let slate = read_opt_nonempty(&slate_id, "slate_id")?
        .map(|s| {
            Uuid::parse_str(s)
                .map_err(|_| GrinError::invalid_argument("slate_id is not a valid UUID"))
        })
        .transpose()?;
    if id.is_none() && slate.is_none() {
        return Err(GrinError::invalid_argument(
            "give a tx_id of 0 or more, or a slate_id",
        ));
    }
    Ok((id, slate))
}

/// A Slatepack this wallet produced (S1, S2, I1 or I2).
#[derive(Serialize)]
struct SlatepackOut {
    slate_id: String,
    state: &'static str,
    armored_slatepack: String,
    amount: u64,
    fee: u64,
    sender: Option<String>,
    recipients: Vec<String>,
    is_encrypted: bool,
}

/// Armors `slate` with our address as sender, encrypted to `recipients`
/// when there are any. `amount` and `fee` describe the transaction; slates
/// on the return journey carry 0 for both, so the caller passes them.
fn pack_out(
    session: &WalletSession,
    slate: &Slate,
    amount: u64,
    fee: u64,
    recipients: Vec<SlatepackAddress>,
) -> Result<SlatepackOut, GrinError> {
    let mask = session.mask();
    let sender =
        owner::get_slatepack_address(session.wallet.clone(), mask.as_ref(), ADDRESS_INDEX)?;
    let armored = owner::create_slatepack_message(
        session.wallet.clone(),
        mask.as_ref(),
        slate,
        Some(ADDRESS_INDEX),
        recipients.clone(),
    )?;
    Ok(SlatepackOut {
        slate_id: slate.id.to_string(),
        state: state_name(&slate.state),
        armored_slatepack: armored,
        amount,
        fee,
        sender: Some(address_string(&sender)?),
        recipients: recipients
            .iter()
            .map(address_string)
            .collect::<Result<_, _>>()?,
        is_encrypted: !recipients.is_empty(),
    })
}

/// Result of finalizing (S3 or I3).
#[derive(Serialize)]
struct FinalizedOut {
    slate_id: String,
    state: &'static str,
    amount: u64,
    fee: u64,
    kernel_excess: Option<String>,
    posted: bool,
    armored_slatepack: String,
}

/// Armors the finalized slate (plain, no sender), records it in the sidecar
/// and broadcasts it when asked.
fn finish_finalized(
    session: &WalletSession,
    slate: &Slate,
    amount: u64,
    counterparty: Option<String>,
    broadcast: bool,
    fluff: bool,
) -> Result<FinalizedOut, GrinError> {
    let mask = session.mask();
    let armored =
        owner::create_slatepack_message(session.wallet.clone(), mask.as_ref(), slate, None, vec![])
            .map_err(|e| with_slate_id(e.into(), &slate.id))?;
    remember(session, slate.id, Some(armored.clone()), counterparty);
    if broadcast {
        post_slate(session, slate, fluff)?;
    }
    Ok(FinalizedOut {
        slate_id: slate.id.to_string(),
        state: state_name(&slate.state),
        amount,
        fee: slate_fee(slate),
        kernel_excess: kernel_excess_hex(slate),
        posted: broadcast,
        armored_slatepack: armored,
    })
}

#[derive(Serialize)]
struct EstimateOut {
    fee: u64,
    /// Net amount the recipient gets.
    amount: u64,
    /// Same as `amount`; the name the header comment uses.
    net_amount: u64,
    /// `amount` plus `fee`.
    total: u64,
    inputs_count: u32,
    change_outputs: u32,
}

/// libwallet's fee is `(inputs * INPUT_WEIGHT + outputs * OUTPUT_WEIGHT +
/// KERNEL_WEIGHT) * accept_fee_base` (grin_core `libtx::tx_fee`), so with
/// the output count known the input count follows from the fee. Must run on
/// the thread that computed the fee, which picked the same fee base.
fn inputs_from_fee(fee: u64, outputs: u64) -> Option<u32> {
    let base = global::get_accept_fee_base();
    if base == 0 || !fee.is_multiple_of(base) {
        return None;
    }
    let rest = (fee / base).checked_sub(outputs.checked_mul(OUTPUT_WEIGHT)? + KERNEL_WEIGHT)?;
    if !rest.is_multiple_of(INPUT_WEIGHT) {
        return None;
    }
    u32::try_from(rest / INPUT_WEIGHT).ok()
}

/// What the fee says about the number of inputs.
#[derive(Debug, PartialEq, Eq)]
enum InputsFromFee {
    Known(u32),
    /// No change output, and the fee fits both ways libwallet can price it.
    OneOf {
        one_output: u32,
        with_change: u32,
    },
    Unknown,
}

/// libwallet's `select_coins_and_fee` prices `1 + num_change_outputs`
/// outputs whenever its first selection does not pay exactly, and keeps that
/// fee even when the change then comes out at exactly zero (no change output
/// is made). So with change the outputs priced are known, but without change
/// the fee may cover one output or `1 + num_change_outputs`. When only one
/// reading gives at least one input that one is right (the usual case: with
/// fewer than 22 inputs the change reading would be negative); otherwise
/// the caller has to ask libwallet again.
fn estimate_inputs(fee: u64, change_outputs: u32, num_change_outputs: u32) -> InputsFromFee {
    let at_least_one = |n: Option<u32>| n.filter(|&n| n > 0);
    if change_outputs > 0 {
        return at_least_one(inputs_from_fee(fee, 1 + u64::from(change_outputs)))
            .map_or(InputsFromFee::Unknown, InputsFromFee::Known);
    }
    let one_output = at_least_one(inputs_from_fee(fee, 1));
    let with_change = at_least_one(inputs_from_fee(fee, 1 + u64::from(num_change_outputs)));
    match (one_output, with_change) {
        (Some(one_output), Some(with_change)) => InputsFromFee::OneOf {
            one_output,
            with_change,
        },
        (Some(n), None) | (None, Some(n)) => InputsFromFee::Known(n),
        (None, None) => InputsFromFee::Unknown,
    }
}

/// Returns `{"fee", "net_amount", "inputs_count"}` or InsufficientFunds.
#[no_mangle]
pub extern "C" fn grin_tx_estimate_fee(
    handle: u64,
    amount: u64,
    min_confirms: u64,
    selection_strategy_is_all: bool,
    amount_includes_fee: bool,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        check_amount(amount)?;
        let args = InitTxArgs {
            amount,
            amount_includes_fee: Some(amount_includes_fee),
            minimum_confirmations: min_confirms,
            selection_strategy_is_use_all: selection_strategy_is_all,
            estimate_only: Some(true),
            ..Default::default()
        };
        let num_change_outputs = args.num_change_outputs;
        // One wallet mutex hold, so a second estimate (below) sees the same
        // outputs as the first.
        let (fee, net, total, inputs_count, change_outputs) = with_backend(&session, |w, mask| {
            let slate = owner::init_send_tx(w, mask, args.clone(), false)?;
            // With estimate_only libwallet adds no inputs to the slate and
            // reports the value of the selected inputs as `amount`.
            let fee = slate.fee_fields.fee();
            let inputs_value = slate.amount;
            let (net, total) = if amount_includes_fee {
                let net = amount.checked_sub(fee).ok_or_else(|| {
                    GrinError::new(GrinErrorCode::Transaction, "amount is too small to include the fee")
                })?;
                (net, amount)
            } else {
                let total = amount
                    .checked_add(fee)
                    .ok_or_else(|| GrinError::invalid_argument("amount plus fee overflows"))?;
                (amount, total)
            };
            let change_outputs = if inputs_value == total { 0 } else { num_change_outputs };
            let inputs_count = match estimate_inputs(fee, change_outputs, num_change_outputs) {
                InputsFromFee::Known(n) => n,
                InputsFromFee::OneOf { one_output, with_change } => {
                    // Price one more change output. If libwallet's first
                    // selection paid exactly, it never priced change, so the
                    // same selection gives the same fee. If it priced change,
                    // the fee moves, or the extra output needs more funds
                    // than the wallet has.
                    let mut more = args.clone();
                    more.num_change_outputs = num_change_outputs.saturating_add(1);
                    more.refresh_outputs_from_node = false;
                    match owner::init_send_tx(w, mask, more, false) {
                        Ok(again) if again.fee_fields.fee() == fee => one_output,
                        Ok(_) | Err(LibwalletError::NotEnoughFunds { .. }) => with_change,
                        Err(e) => return Err(e.into()),
                    }
                }
                InputsFromFee::Unknown => {
                    return Err(GrinError::internal(
                        "the fee does not match libwallet's fee formula",
                    ))
                }
            };
            Ok((fee, net, total, inputs_count, change_outputs))
        })?;
        to_json(&EstimateOut {
            fee,
            amount: net,
            net_amount: net,
            total,
            inputs_count,
            change_outputs,
        })
    }
}

#[derive(Serialize)]
struct ProofInfoOut {
    receiver_address: String,
    sender_address: String,
    receiver_signature_present: bool,
    sender_signature_present: bool,
}

#[derive(Serialize)]
struct TxOut {
    id: u32,
    slate_id: Option<String>,
    slate_state: Option<&'static str>,
    #[serde(rename = "type")]
    tx_type: &'static str,
    creation_ts: String,
    confirmation_ts: Option<String>,
    confirmed: bool,
    confirmed_height: Option<u64>,
    num_inputs: usize,
    num_outputs: usize,
    amount_credited: u64,
    amount_debited: u64,
    fee: Option<u64>,
    ttl_cutoff_height: Option<u64>,
    kernel_excess: Option<String>,
    kernel_lookup_min_height: Option<u64>,
    has_stored_tx: bool,
    payment_proof: Option<ProofInfoOut>,
    counterparty_address: Option<String>,
    armored_slatepack: Option<String>,
    reverted_after_secs: Option<u64>,
}

#[derive(Serialize)]
struct TxsOut {
    refreshed_from_node: bool,
    txs: Vec<TxOut>,
}

fn tx_type_name(t: &TxLogEntryType) -> &'static str {
    match t {
        TxLogEntryType::ConfirmedCoinbase => "ConfirmedCoinbase",
        TxLogEntryType::TxReceived => "TxReceived",
        TxLogEntryType::TxSent => "TxSent",
        TxLogEntryType::TxReceivedCancelled => "TxReceivedCancelled",
        TxLogEntryType::TxSentCancelled => "TxSentCancelled",
        TxLogEntryType::TxReverted => "TxReverted",
    }
}

/// Builds the proof summary. The public keys become slatepack addresses
/// with the HRP of the thread's chain type, which `get_session` set to the
/// wallet's.
fn proof_info(p: &StoredProofInfo) -> Result<ProofInfoOut, GrinError> {
    Ok(ProofInfoOut {
        receiver_address: address_string(&SlatepackAddress::new(&p.receiver_address))?,
        sender_address: address_string(&SlatepackAddress::new(&p.sender_address))?,
        receiver_signature_present: p.receiver_signature.is_some(),
        sender_signature_present: p.sender_signature.is_some(),
    })
}

/// The height each transaction confirmed at, from the outputs it created
/// for this wallet: libwallet records a height on every output of ours once
/// it is seen on chain, and `tx_log_entry` ties the output to a transaction.
///
/// libwallet points an output's `tx_log_entry` at the spending transaction
/// when it locks the output as an input, so a spent or locked output's
/// height is its creation height, not the height of the transaction it now
/// names. Only unspent outputs are counted. A transaction left with no
/// unspent output of ours (a send without change, or one whose outputs have
/// all been spent since) gets no height.
fn confirmed_heights(session: &WalletSession) -> Result<HashMap<u32, u64>, GrinError> {
    let mask = session.mask();
    let (_, outputs) = owner::retrieve_outputs(
        session.wallet.clone(),
        mask.as_ref(),
        &None,
        true,
        false,
        None,
    )?;
    let mut heights = HashMap::new();
    for m in outputs {
        let o = m.output;
        if o.height == 0 || o.status != OutputStatus::Unspent {
            continue;
        }
        if let Some(id) = o.tx_log_entry {
            let h = heights.entry(id).or_insert(0);
            *h = (*h).max(o.height);
        }
    }
    Ok(heights)
}

fn tx_out(
    session: &WalletSession,
    sidecar: &Sidecar,
    heights: &HashMap<u32, u64>,
    t: TxLogEntry,
) -> Result<TxOut, GrinError> {
    let side = t.tx_slate_id.as_ref().and_then(|id| sidecar.get(id));
    let payment_proof = t.payment_proof.as_ref().map(proof_info).transpose()?;
    let outgoing = matches!(
        t.tx_type,
        TxLogEntryType::TxSent | TxLogEntryType::TxSentCancelled
    );
    let counterparty_address = match &payment_proof {
        Some(p) if outgoing => Some(p.receiver_address.clone()),
        Some(p) => Some(p.sender_address.clone()),
        None => side.and_then(|s| s.counterparty_address.clone()),
    };
    // The file exists from the moment outputs are locked, but only a
    // finalized transaction can be reposted.
    let finalized = matches!(
        t.tx_slate_state,
        Some(SlateState::Standard3 | SlateState::Invoice3)
    );
    let has_stored_tx = finalized
        && t.stored_tx
            .as_deref()
            .is_some_and(|f| session.data_dir.join(STORED_TX_DIR).join(f).is_file());
    Ok(TxOut {
        id: t.id,
        slate_id: t.tx_slate_id.map(|u| u.to_string()),
        slate_state: t.tx_slate_state.as_ref().map(state_name),
        tx_type: tx_type_name(&t.tx_type),
        creation_ts: t.creation_ts.to_rfc3339(),
        confirmation_ts: t.confirmation_ts.map(|ts| ts.to_rfc3339()),
        confirmed: t.confirmed,
        confirmed_height: if t.confirmed {
            heights.get(&t.id).copied().map(json_u64)
        } else {
            None
        },
        num_inputs: t.num_inputs,
        num_outputs: t.num_outputs,
        amount_credited: json_u64(t.amount_credited),
        amount_debited: json_u64(t.amount_debited),
        fee: t.fee.map(|f| json_u64(f.fee())),
        ttl_cutoff_height: t.ttl_cutoff_height.map(json_u64),
        kernel_excess: t.kernel_excess.map(|c| c.0.to_hex()),
        kernel_lookup_min_height: t.kernel_lookup_min_height.map(json_u64),
        has_stored_tx,
        payment_proof,
        counterparty_address,
        armored_slatepack: side.and_then(|s| s.armored_slatepack.clone()),
        reverted_after_secs: t.reverted_after.map(|d| d.as_secs()),
    })
}

/// Lists transactions joined with the sidecar metadata.
#[no_mangle]
pub extern "C" fn grin_txs_get(handle: u64, refresh_from_node: bool) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        if refresh_from_node {
            session.require_network()?;
        }
        let mask = session.mask();
        let (refreshed, txs) = owner::retrieve_txs(
            session.wallet.clone(),
            mask.as_ref(),
            &None,
            refresh_from_node,
            None,
            None,
            None,
        )?;
        let sidecar = Sidecar::load(&session.data_dir);
        let heights = confirmed_heights(&session)?;
        let txs = txs
            .into_iter()
            .map(|t| tx_out(&session, &sidecar, &heights, t))
            .collect::<Result<Vec<_>, _>>()?;
        to_json(&TxsOut {
            refreshed_from_node: refreshed,
            txs,
        })
    }
}

/// `args_json` of `grin_tx_init_send`. Unknown keys (including the v3-era
/// `message`) are ignored.
#[derive(Deserialize)]
struct SendArgs {
    amount: u64,
    // Every optional key is an Option so that null means the default, as
    // ffi-json 9.1 promises (serde's default only covers a missing key).
    #[serde(default)]
    min_confirms: Option<u64>,
    #[serde(default)]
    selection_strategy_is_all: Option<bool>,
    #[serde(default)]
    amount_includes_fee: Option<bool>,
    #[serde(default)]
    recipient_address: Option<String>,
    #[serde(default)]
    ttl_blocks: Option<u64>,
    #[serde(default)]
    late_lock: Option<bool>,
}

impl SendArgs {
    fn late_lock(&self) -> bool {
        self.late_lock.unwrap_or(false)
    }

    fn min_confirms(&self) -> u64 {
        self.min_confirms.unwrap_or(DEFAULT_MIN_CONFIRMS)
    }

    /// The recipient's slatepack address, if given and not empty.
    fn recipient(&self) -> Result<Option<SlatepackAddress>, GrinError> {
        self.recipient_address
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(parse_slatepack_address)
            .transpose()
    }

    /// Checks the amount and `ttl_blocks`. Callers run it before anything
    /// is built or locked.
    fn check(&self) -> Result<(), GrinError> {
        check_amount(self.amount)?;
        check_ttl_blocks(self.ttl_blocks)
    }

    fn init_tx_args(
        &self,
        proof_address: Option<SlatepackAddress>,
    ) -> Result<InitTxArgs, GrinError> {
        self.check()?;
        Ok(InitTxArgs {
            amount: self.amount,
            amount_includes_fee: Some(self.amount_includes_fee.unwrap_or(false)),
            minimum_confirmations: self.min_confirms(),
            selection_strategy_is_use_all: self.selection_strategy_is_all.unwrap_or(false),
            ttl_blocks: self.ttl_blocks,
            payment_proof_recipient_address: proof_address,
            late_lock: Some(self.late_lock()),
            ..Default::default()
        })
    }
}

/// Builds and locks an S1 and returns it as a Slatepack.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_init_send(handle: u64, args_json: *const c_char) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let args: SendArgs = parse_args(args_json, "args_json")?;
        args.check()?;
        let recipient = args.recipient()?;
        let tx_args = args.init_tx_args(recipient.clone())?;
        let late_lock = args.late_lock();
        let slate = with_backend(&session, |w, mask| {
            let slate = owner::init_send_tx(w, mask, tx_args, false)?;
            // With late locking libwallet selects and locks inputs at
            // finalization instead.
            if !late_lock {
                owner::tx_lock_outputs(w, mask, &slate)?;
            }
            Ok(slate)
        })?;
        let counterparty = recipient.as_ref().map(address_string).transpose()?;
        let out = pack_out(
            &session,
            &slate,
            slate.amount,
            slate_fee(&slate),
            recipient.into_iter().collect(),
        )
        .map_err(|e| with_slate_id(e, &slate.id))?;
        remember(&session, slate.id, Some(out.armored_slatepack.clone()), counterparty);
        to_json(&out)
    }
}

/// `args_json` of `grin_tx_send_http`.
#[derive(Deserialize)]
struct SendHttpArgs {
    #[serde(flatten)]
    send: SendArgs,
    recipient_url_or_address: String,
    #[serde(default)]
    fluff: Option<bool>,
    #[serde(default)]
    post: Option<bool>,
}

#[derive(Serialize)]
struct SendHttpOut {
    slate_id: String,
    state: &'static str,
    amount: u64,
    fee: u64,
    kernel_excess: Option<String>,
    posted: bool,
}

/// Synchronous send to a slatepack address (over Tor) or an http(s) URL.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_send_http(handle: u64, args_json: *const c_char) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let args: SendHttpArgs = parse_args(args_json, "args_json")?;
        args.send.check()?;
        let target = parse_address(&args.recipient_url_or_address)?;
        let explicit = args.send.recipient()?;
        // A slatepack or onion target is itself a slatepack key. The payment
        // proof has to come from that key, so a different recipient_address
        // is refused here, before anything is built or locked; otherwise
        // the proof check would fail at finalization with the inputs locked.
        let target_key = match target.kind {
            "slatepack" | "onion" => Some(parse_slatepack_address(
                target.slatepack_address.as_deref().unwrap_or_default(),
            )?),
            _ => None,
        };
        if let (Some(t), Some(e)) = (&target_key, &explicit) {
            if t.pub_key != e.pub_key {
                return Err(GrinError::invalid_argument(format!(
                    "recipient_address differs from the {} address being sent to",
                    target.kind
                )));
            }
        }
        // A slatepack target always asks for a proof; an onion or URL target
        // only when recipient_address is given.
        let proof_address = if target.kind == "slatepack" { target_key } else { explicit };
        let (proxy, timeout) = {
            let node = session.node_settings();
            (node.socks_proxy, node.timeout)
        };
        // Slatepack and onion targets both resolve to a .onion URL, which
        // only a Tor SOCKS proxy can reach.
        if target.kind != "http" && proxy.is_none() {
            return Err(GrinError::invalid_argument(
                "sending to a slatepack or onion address needs a SOCKS proxy (Tor) in the wallet's network settings",
            ));
        }
        let counterparty = match &target.slatepack_address {
            Some(a) if target.kind == "slatepack" => a.clone(),
            _ => target.url.clone(),
        };
        let mut sender = match proxy {
            Some(p) => HttpSlateSender::with_socks_proxy(&target.url, p, timeout),
            None => HttpSlateSender::new(&target.url, timeout),
        }
        .map_err(|e| GrinError::new(GrinErrorCode::InvalidAddress, e.to_string()))?;
        let tx_args = args.send.init_tx_args(proof_address)?;
        let late_lock = args.send.late_lock();

        let s1 = with_backend(&session, |w, mask| {
            Ok(owner::init_send_tx(w, mask, tx_args, false)?)
        })?;
        // No wallet lock during the round trip, and nothing is locked yet.
        // An S2 that changed the kernel, the TTL or the payment proof is
        // refused here.
        let exchanged = (|| {
            let s2 = sender.send_tx(&s1, false).map_err(|e| {
                GrinError::new(
                    GrinErrorCode::Http,
                    format!("the recipient wallet did not take the transaction: {e}"),
                )
            })?;
            if s2.id != s1.id || s2.state != SlateState::Standard2 {
                return Err(GrinError::new(
                    GrinErrorCode::Http,
                    format!(
                        "the recipient wallet answered with an unexpected slate ({} {})",
                        s2.id,
                        state_name(&s2.state)
                    ),
                ));
            }
            check_returned_slate(&s2, Some(s1.ttl_cutoff_height))?;
            check_returned_proof(&s1, &s2)?;
            Ok(s2)
        })();
        let s2 = match exchanged {
            Ok(s2) => s2,
            Err(e) => {
                // The send recorded only its context so far.
                let _ = with_backend(&session, |w, mask| {
                    forget_context(w, mask, &s1.id);
                    Ok(())
                });
                return Err(e);
            }
        };
        let s3 = with_backend(&session, |w, mask| {
            if !late_lock {
                // The wallet was free during the round trip, so another
                // call may have taken the inputs this send selected.
                let locked = match check_inputs_free(w, mask, &s1.id) {
                    Ok(()) => owner::tx_lock_outputs(w, mask, &s2).map_err(GrinError::from),
                    Err(e) => Err(e),
                };
                if let Err(e) = locked {
                    // Locking is one database batch: nothing was recorded.
                    forget_context(w, mask, &s1.id);
                    return Err(e);
                }
            }
            owner::finalize_tx(w, mask, &s2).map_err(|e| release_send(w, mask, &s1.id, e.into()))
        })?;
        remember(&session, s3.id, None, Some(counterparty));
        let post = args.post.unwrap_or(true);
        if post {
            post_slate(&session, &s3, args.fluff.unwrap_or(false))?;
        }
        to_json(&SendHttpOut {
            slate_id: s3.id.to_string(),
            state: state_name(&s3.state),
            amount: s1.amount,
            fee: slate_fee(&s1),
            kernel_excess: kernel_excess_hex(&s3),
            posted: post,
        })
    }
}

/// Receives an S1 Slatepack and returns the S2 Slatepack.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_receive_slatepack(
    handle: u64,
    armored_s1: *const c_char,
    message: *const c_char,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let armored = read_str(&armored_s1, "armored_s1")?;
        // Slate v4 has no message field; read only to check the argument.
        let _ = read_opt_str(&message, "message")?;
        let decoded = decode_with_wallet(&session, armored, ADDRESS_INDEX)?;
        let s1 = &decoded.slate;
        require_state(s1, SlateState::Standard1)?;
        check_foreign_bounds(s1)?;
        let s2 = with_backend(&session, |w, mask| {
            Ok(foreign::receive_tx(w, mask, s1, None, false)?)
        })?;
        let counterparty = decoded.sender.as_ref().map(address_string).transpose()?;
        // Encrypt the reply to the sender when the S1 named one.
        let out = pack_out(
            &session,
            &s2,
            s1.amount,
            slate_fee(s1),
            decoded.sender.clone().into_iter().collect(),
        )
        .map_err(|e| with_slate_id(e, &s2.id))?;
        remember(&session, s2.id, Some(out.armored_slatepack.clone()), counterparty);
        to_json(&out)
    }
}

/// Finalizes an S2 Slatepack into S3, optionally broadcasting it.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_finalize_slatepack(
    handle: u64,
    armored_s2: *const c_char,
    broadcast: bool,
    fluff: bool,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        if broadcast {
            session.require_network()?;
        }
        let armored = read_str(&armored_s2, "armored_s2")?;
        let decoded = decode_with_wallet(&session, armored, ADDRESS_INDEX)?;
        require_state(&decoded.slate, SlateState::Standard2)?;
        // This wallet recorded the transaction when it made the S1, so
        // every failure from here on carries the slate id.
        let slate_id = decoded.slate.id;
        let (s3, amount) = with_backend(&session, |w, mask| {
            check_send_role(w, mask, &slate_id)?;
            check_foreign_bounds(&decoded.slate)?;
            let issued_ttl = issued_ttl_for_slate(w, &slate_id)?;
            check_returned_slate(&decoded.slate, issued_ttl)?;
            let s3 = owner::finalize_tx(w, mask, &decoded.slate)?;
            let amount = amount_for_slate(w, &s3.id)?;
            Ok((s3, amount))
        })
        .map_err(|e| with_slate_id(e, &slate_id))?;
        let counterparty = decoded
            .sender
            .as_ref()
            .map(address_string)
            .transpose()
            .map_err(|e| with_slate_id(e, &slate_id))?;
        to_json(&finish_finalized(&session, &s3, amount, counterparty, broadcast, fluff)?)
    }
}

/// `args_json` of `grin_tx_issue_invoice`.
#[derive(Deserialize)]
struct InvoiceArgs {
    amount: u64,
    #[serde(default)]
    dest_acct_name: Option<String>,
    #[serde(default)]
    recipient_address: Option<String>,
}

impl InvoiceArgs {
    fn check(&self) -> Result<(), GrinError> {
        check_amount(self.amount)
    }
}

/// Issues an I1 invoice Slatepack.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_issue_invoice(
    handle: u64,
    args_json: *const c_char,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let args: InvoiceArgs = parse_args(args_json, "args_json")?;
        args.check()?;
        let payer = args
            .recipient_address
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(parse_slatepack_address)
            .transpose()?;
        let invoice_args = IssueInvoiceTxArgs {
            dest_acct_name: args.dest_acct_name.filter(|s| !s.is_empty()),
            amount: args.amount,
            target_slate_version: None,
        };
        let i1 = with_backend(&session, |w, mask| {
            Ok(owner::issue_invoice_tx(w, mask, invoice_args, false)?)
        })?;
        let counterparty = payer.as_ref().map(address_string).transpose()?;
        let out = pack_out(&session, &i1, i1.amount, slate_fee(&i1), payer.into_iter().collect())
            .map_err(|e| with_slate_id(e, &i1.id))?;
        remember(&session, i1.id, Some(out.armored_slatepack.clone()), counterparty);
        to_json(&out)
    }
}

/// `args_json` of `grin_tx_process_invoice`.
#[derive(Deserialize)]
struct PayInvoiceArgs {
    #[serde(default)]
    min_confirms: Option<u64>,
    #[serde(default)]
    selection_strategy_is_all: Option<bool>,
    #[serde(default)]
    ttl_blocks: Option<u64>,
    /// Nanogrin the payer agreed to pay. When set, an I1 asking for any
    /// other amount is refused before anything is recorded or locked.
    #[serde(default)]
    expected_amount: Option<u64>,
}

impl PayInvoiceArgs {
    fn check(&self) -> Result<(), GrinError> {
        check_ttl_blocks(self.ttl_blocks)
    }

    /// Compares the invoice amount with `expected_amount`, if given.
    fn check_amount(&self, invoice_amount: u64) -> Result<(), GrinError> {
        match self.expected_amount {
            Some(expected) if expected != invoice_amount => Err(GrinError::new(
                GrinErrorCode::Transaction,
                format!(
                    "the invoice asks for {invoice_amount} nanogrin, not the expected {expected}"
                ),
            )
            .with_details(serde_json::json!({
                "invoice_amount": invoice_amount,
                "expected_amount": expected,
            }))),
            _ => Ok(()),
        }
    }
}

/// Pays an I1 invoice, locks the inputs and returns the I2 Slatepack.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_process_invoice(
    handle: u64,
    armored_i1: *const c_char,
    args_json: *const c_char,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let armored = read_str(&armored_i1, "armored_i1")?;
        let args: PayInvoiceArgs = parse_args(args_json, "args_json")?;
        args.check()?;
        let decoded = decode_with_wallet(&session, armored, ADDRESS_INDEX)?;
        let i1 = &decoded.slate;
        require_state(i1, SlateState::Invoice1)?;
        args.check_amount(i1.amount)?;
        // The amount comes from the invoicer, and libwallet adds the fee to
        // it unchecked, as for a send.
        if i1.amount > MAX_AMOUNT {
            return Err(GrinError::invalid_argument(format!(
                "the invoice amount must be at most {MAX_AMOUNT} nanogrin, got {}",
                i1.amount
            )));
        }
        let tx_args = InitTxArgs {
            amount: i1.amount,
            minimum_confirmations: args.min_confirms.unwrap_or(DEFAULT_MIN_CONFIRMS),
            selection_strategy_is_use_all: args.selection_strategy_is_all.unwrap_or(false),
            ttl_blocks: args.ttl_blocks,
            ..Default::default()
        };
        check_foreign_bounds(i1)?;
        // A HeightLocked or NRD kernel would hold the payment back until a
        // height the invoicer picked.
        if i1.kernel_features != 0 || i1.kernel_features_args.is_some() {
            return Err(slate_error(format!(
                "the invoice asks for kernel features {}; only a plain kernel is paid",
                i1.kernel_features
            )));
        }
        let i2 = with_backend(&session, |w, mask| {
            let own_invoice = check_payable(w, mask, &i1.id)?;
            let i2 = owner::process_invoice_tx(w, mask, i1, tx_args, false)?;
            // process_invoice_tx selects inputs and saves the context but
            // does not lock. Locking is one database batch, so a failure
            // recorded nothing: the context goes too, unless it is also
            // the context of this wallet's own invoice.
            if let Err(e) = owner::tx_lock_outputs(w, mask, &i2) {
                if own_invoice {
                    return Err(with_slate_id(e.into(), &i2.id));
                }
                forget_context(w, mask, &i2.id);
                return Err(e.into());
            }
            Ok(i2)
        })?;
        let counterparty = decoded
            .sender
            .as_ref()
            .map(address_string)
            .transpose()
            .map_err(|e| with_slate_id(e, &i2.id))?;
        let out = pack_out(
            &session,
            &i2,
            i1.amount,
            slate_fee(&i2),
            decoded.sender.clone().into_iter().collect(),
        )
        .map_err(|e| with_slate_id(e, &i2.id))?;
        remember(&session, i2.id, Some(out.armored_slatepack.clone()), counterparty);
        to_json(&out)
    }
}

/// Finalizes an I2 Slatepack into I3, optionally broadcasting it.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_finalize_invoice(
    handle: u64,
    armored_i2: *const c_char,
    broadcast: bool,
    fluff: bool,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        if broadcast {
            session.require_network()?;
        }
        let armored = read_str(&armored_i2, "armored_i2")?;
        let decoded = decode_with_wallet(&session, armored, ADDRESS_INDEX)?;
        require_state(&decoded.slate, SlateState::Invoice2)?;
        // This wallet recorded the invoice when it issued the I1, so every
        // failure from here on carries the slate id.
        let slate_id = decoded.slate.id;
        let (i3, amount) = with_backend(&session, |w, mask| {
            // The payer may set a TTL on an invoice, so only the kernel is
            // checked. Broadcasting happens below, with the wallet mutex
            // released.
            check_invoice_role(w, mask, &slate_id)?;
            check_foreign_bounds(&decoded.slate)?;
            check_returned_slate(&decoded.slate, None)?;
            let i3 = foreign::finalize_tx(w, mask, &decoded.slate, false)?;
            let amount = amount_for_slate(w, &i3.id)?;
            Ok((i3, amount))
        })
        .map_err(|e| with_slate_id(e, &slate_id))?;
        let counterparty = decoded
            .sender
            .as_ref()
            .map(address_string)
            .transpose()
            .map_err(|e| with_slate_id(e, &slate_id))?;
        to_json(&finish_finalized(&session, &i3, amount, counterparty, broadcast, fluff)?)
    }
}

/// The log entry `owner::get_stored_tx` resolves: the entry with `tx_id`
/// when it has a slate id, otherwise the first one with `slate_id`.
fn repost_entry(
    w: &mut Backend,
    tx_id: Option<u32>,
    slate_id: Option<&Uuid>,
) -> Result<Option<TxLogEntry>, GrinError> {
    let entries: Vec<TxLogEntry> = w.tx_log_iter()?.filter_map(Result::ok).collect();
    if let Some(id) = tx_id {
        if let Some(t) = entries
            .iter()
            .find(|t| t.id == id && t.tx_slate_id.is_some())
        {
            return Ok(Some(t.clone()));
        }
    }
    Ok(slate_id.and_then(|sid| {
        entries
            .into_iter()
            .find(|t| t.tx_slate_id.as_ref() == Some(sid))
    }))
}

/// Re-broadcasts a finalized, unconfirmed transaction.
// (Plain comment: doc comments here are copied into include/grin_ffi.h.)
// A cancelled or confirmed transaction is refused with Transaction.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_repost(
    handle: u64,
    tx_id: i64,
    slate_id: *const c_char,
    fluff: bool,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let (tx_id, slate_id) = tx_selector(tx_id, slate_id)?;
        let slate = with_backend(&session, |w, _mask| {
            if let Some(entry) = repost_entry(w, tx_id, slate_id.as_ref())? {
                if matches!(
                    entry.tx_type,
                    TxLogEntryType::TxSentCancelled | TxLogEntryType::TxReceivedCancelled
                ) {
                    return Err(GrinError::new(
                        GrinErrorCode::Transaction,
                        format!(
                            "transaction {} was cancelled; a cancelled transaction cannot be reposted",
                            entry.id
                        ),
                    ));
                }
                if entry.confirmed {
                    return Err(GrinError::new(
                        GrinErrorCode::Transaction,
                        format!("transaction {} is confirmed; there is nothing to repost", entry.id),
                    ));
                }
            }
            match owner::get_stored_tx(w, tx_id, slate_id.as_ref()) {
                Ok(Some(slate)) => Ok(slate),
                // StoredTx: no log entry or slate id matched. IO: the
                // transaction was never finalized, so no file was saved.
                Ok(None) | Err(LibwalletError::StoredTx(_)) | Err(LibwalletError::IO(_)) => {
                    Err(GrinError::new(
                        GrinErrorCode::NotFound,
                        "no finalized transaction is stored for this id",
                    ))
                }
                Err(e) => Err(e.into()),
            }
        })?;
        // libwallet stores the unsigned transaction as soon as outputs are
        // locked, so a stored file alone does not mean it can be posted.
        slate.tx_or_err()?.validate(Weighting::AsTransaction).map_err(|_| {
            GrinError::new(
                GrinErrorCode::NotFound,
                "the stored transaction is not finalized yet",
            )
        })?;
        post_slate(&session, &slate, fluff)?;
        to_json(&serde_json::json!({ "posted": true }))
    }
}

/// Cancels a transaction by id or slate id and unlocks its inputs.
// # Safety
// Every pointer argument must be NULL or point to a NUL-terminated string
// that stays valid and unchanged until the call returns.
#[no_mangle]
pub unsafe extern "C" fn grin_tx_cancel(
    handle: u64,
    tx_id: i64,
    slate_id: *const c_char,
) -> GrinFfiResult {
    ffi_guard! {
        let session = get_session(handle)?;
        session.require_network()?;
        let (tx_id, slate_id) = tx_selector(tx_id, slate_id)?;
        // A late-locked send has no log entry until it is finalized, only a
        // context that holds its arguments. Cancelling it deletes that
        // context, after which its S2 can no longer be finalized.
        if let (None, Some(id)) = (tx_id, slate_id.as_ref()) {
            let dropped = with_backend(&session, |w, mask| {
                if !entries_for_slate(w, id)?.is_empty() {
                    return Ok(false);
                }
                match stored_context(w, mask, id) {
                    Some(context) if context.late_lock_args.is_some() => {
                        let mut batch = w.batch(mask)?;
                        batch.delete_private_context(id.as_bytes())?;
                        batch.commit()?;
                        Ok(true)
                    }
                    _ => Ok(false),
                }
            })?;
            if dropped {
                if let Err(e) = Sidecar::remove(&session.data_dir, id) {
                    log::warn!("Sidecar write failed: {e}");
                }
                return to_json(&serde_json::json!({ "cancelled": true }));
            }
        }
        let mask = session.mask();
        owner::cancel_tx(session.wallet.clone(), mask.as_ref(), &None, tx_id, slate_id)?;
        to_json(&serde_json::json!({ "cancelled": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use grin_core::global::ChainTypes;
    use grin_core::libtx::tx_fee;
    use grin_wallet_libwallet::{SlateVersion, VersionedSlate};
    use serde_json::{json, Value};
    use std::ffi::CString;

    #[test]
    fn inputs_follow_from_the_fee() {
        global::set_local_chain_type(ChainTypes::AutomatedTesting);
        for inputs in [1usize, 2, 7, 120] {
            for outputs in [1usize, 2] {
                let fee = tx_fee(inputs, outputs, 1);
                assert_eq!(
                    inputs_from_fee(fee, outputs as u64),
                    Some(inputs as u32),
                    "{inputs} inputs, {outputs} outputs"
                );
            }
        }
        assert_eq!(inputs_from_fee(1, 1), None);
        assert_eq!(inputs_from_fee(0, 2), None);
    }

    #[test]
    fn inputs_when_change_comes_out_at_zero() {
        global::set_local_chain_type(ChainTypes::AutomatedTesting);
        // With change the priced outputs are known.
        assert_eq!(
            estimate_inputs(tx_fee(3, 2, 1), 1, 1),
            InputsFromFee::Known(3)
        );
        // No change and few inputs: priced with one output.
        assert_eq!(
            estimate_inputs(tx_fee(1, 1, 1), 0, 1),
            InputsFromFee::Known(1)
        );
        assert_eq!(
            estimate_inputs(tx_fee(21, 1, 1), 0, 1),
            InputsFromFee::Known(21)
        );
        // No change, but the fee priced a change output that came out at
        // zero: reading it as one output would give 22 inputs, not 1.
        assert_eq!(
            estimate_inputs(tx_fee(1, 2, 1), 0, 1),
            InputsFromFee::OneOf {
                one_output: 22,
                with_change: 1
            }
        );
        assert_eq!(estimate_inputs(1, 0, 1), InputsFromFee::Unknown);
    }

    #[test]
    fn selector_rules() {
        assert_eq!(
            tx_selector(-1, std::ptr::null()).unwrap_err().code,
            GrinErrorCode::InvalidArgument
        );
        let empty = CString::new(" ").unwrap();
        assert_eq!(
            tx_selector(-5, empty.as_ptr()).unwrap_err().code,
            GrinErrorCode::InvalidArgument
        );
        assert_eq!(
            tx_selector(i64::from(u32::MAX) + 1, std::ptr::null())
                .unwrap_err()
                .code,
            GrinErrorCode::InvalidArgument
        );
        let bad = CString::new("not-a-uuid").unwrap();
        assert_eq!(
            tx_selector(-1, bad.as_ptr()).unwrap_err().code,
            GrinErrorCode::InvalidArgument
        );
        assert_eq!(tx_selector(3, std::ptr::null()).unwrap(), (Some(3), None));
        let id = Uuid::new_v4();
        let s = CString::new(id.to_string()).unwrap();
        assert_eq!(tx_selector(-1, s.as_ptr()).unwrap(), (None, Some(id)));
    }

    #[test]
    fn send_args_defaults_and_checks() {
        let a: SendArgs = serde_json::from_str(r#"{"amount": 5, "message": "hi"}"#).unwrap();
        assert_eq!(a.min_confirms(), DEFAULT_MIN_CONFIRMS);
        // null means the default for every optional key.
        let a: SendArgs = serde_json::from_str(
            r#"{"amount": 5, "min_confirms": null, "selection_strategy_is_all": null,
                "amount_includes_fee": null, "recipient_address": null, "ttl_blocks": null,
                "late_lock": null}"#,
        )
        .unwrap();
        assert_eq!(a.min_confirms(), DEFAULT_MIN_CONFIRMS);
        assert_eq!(
            a.init_tx_args(None).unwrap().minimum_confirmations,
            DEFAULT_MIN_CONFIRMS
        );
        let p: PayInvoiceArgs = serde_json::from_str(
            r#"{"min_confirms": null, "selection_strategy_is_all": null, "ttl_blocks": null}"#,
        )
        .unwrap();
        assert!(p.min_confirms.is_none());
        let h: SendHttpArgs = serde_json::from_str(
            r#"{"amount": 1, "min_confirms": null, "recipient_url_or_address": "http://x",
                "fluff": null, "post": null}"#,
        )
        .unwrap();
        assert_eq!(h.send.min_confirms(), DEFAULT_MIN_CONFIRMS);
        let t = a.init_tx_args(None).unwrap();
        assert!(!t.selection_strategy_is_use_all);
        assert_eq!(t.amount_includes_fee, Some(false));
        assert_eq!(t.late_lock, Some(false));
        let a: SendArgs = serde_json::from_str(r#"{"amount": 0}"#).unwrap();
        assert_eq!(
            a.init_tx_args(None).unwrap_err().code,
            GrinErrorCode::InvalidArgument
        );
        let a: SendArgs = serde_json::from_str(r#"{"amount": 1, "ttl_blocks": 0}"#).unwrap();
        assert!(a.init_tx_args(None).is_err());
        assert!(serde_json::from_str::<SendArgs>(r#"{"min_confirms": 1}"#).is_err());
        let h: SendHttpArgs = serde_json::from_str(
            r#"{"amount": 7, "min_confirms": 2, "recipient_url_or_address": "http://x", "late_lock": null}"#,
        )
        .unwrap();
        assert_eq!(h.send.amount, 7);
        assert_eq!(h.send.min_confirms(), 2);
        assert!(h.post.is_none());
    }

    #[test]
    fn amount_and_ttl_bounds() {
        let invalid = |r: Result<(), GrinError>| r.unwrap_err().code;
        let send = |json: Value| serde_json::from_value::<SendArgs>(json).unwrap();

        // Largest values pass.
        let a = send(json!({"amount": MAX_AMOUNT, "ttl_blocks": MAX_TTL_BLOCKS}));
        a.check().unwrap();
        let t = a.init_tx_args(None).unwrap();
        assert_eq!(t.amount, MAX_AMOUNT);
        assert_eq!(t.ttl_blocks, Some(MAX_TTL_BLOCKS));
        send(json!({"amount": 1})).check().unwrap();

        for bad in [
            json!({"amount": MAX_AMOUNT + 1}),
            json!({"amount": u64::MAX}),
            json!({"amount": 1, "ttl_blocks": MAX_TTL_BLOCKS + 1}),
            json!({"amount": 1, "ttl_blocks": u64::MAX}),
            json!({"amount": 1, "ttl_blocks": 0}),
        ] {
            let a = send(bad.clone());
            assert_eq!(invalid(a.check()), GrinErrorCode::InvalidArgument, "{bad}");
            assert!(a.init_tx_args(None).is_err(), "{bad}");

            // grin_tx_send_http takes the same keys.
            let mut http = bad.clone();
            http["recipient_url_or_address"] = json!("http://x");
            let h: SendHttpArgs = serde_json::from_value(http).unwrap();
            assert_eq!(
                invalid(h.send.check()),
                GrinErrorCode::InvalidArgument,
                "{bad}"
            );
        }

        let invoice = |amount: u64| {
            serde_json::from_value::<InvoiceArgs>(json!({ "amount": amount }))
                .unwrap()
                .check()
        };
        invoice(MAX_AMOUNT).unwrap();
        assert_eq!(
            invalid(invoice(MAX_AMOUNT + 1)),
            GrinErrorCode::InvalidArgument
        );
        assert_eq!(invalid(invoice(u64::MAX)), GrinErrorCode::InvalidArgument);
        assert_eq!(invalid(invoice(0)), GrinErrorCode::InvalidArgument);

        let pay = |ttl: Value| {
            serde_json::from_value::<PayInvoiceArgs>(json!({ "ttl_blocks": ttl }))
                .unwrap()
                .check()
        };
        pay(Value::Null).unwrap();
        pay(json!(MAX_TTL_BLOCKS)).unwrap();
        assert_eq!(
            invalid(pay(json!(MAX_TTL_BLOCKS + 1))),
            GrinErrorCode::InvalidArgument
        );
        assert_eq!(
            invalid(pay(json!(u64::MAX))),
            GrinErrorCode::InvalidArgument
        );
        assert_eq!(invalid(pay(json!(0))), GrinErrorCode::InvalidArgument);
    }

    /// A V4 slate from JSON, the way a counterparty's wallet would send it.
    fn slate_from(fields: Value) -> Slate {
        let v4 = VersionedSlate::into_version(Slate::blank(2, false), SlateVersion::V4).unwrap();
        let mut j = serde_json::to_value(&v4).unwrap();
        for (k, v) in fields.as_object().unwrap() {
            j[k] = v.clone();
        }
        Slate::deserialize_upgrade(&j.to_string()).unwrap()
    }

    const ADDR_A: &str = "tgrin17zq8t8lz8fwu9xrs4lxnvfareuxcw5qz0875nl870ctyahhtapcqza5hqd";
    const ADDR_B: &str = "tgrin1w0fvmdwtnd23enavfv457eedr2tj3gqp9sx4ghxlm997hcdrgutqyaz0ma";
    const ADDR_C: &str = "tgrin16przlf9axsw8ag6k584uzgr999av9zjhf82f8eqec022n96atdlqvfna76";

    fn key_hex(addr: &str) -> String {
        SlatepackAddress::try_from(addr)
            .unwrap()
            .pub_key
            .to_bytes()
            .to_hex()
    }

    #[test]
    fn returned_slates_are_checked() {
        global::set_local_chain_type(ChainTypes::AutomatedTesting);
        let same = slate_from(json!({"ttl": 500}));
        check_returned_slate(&same, Some(500)).unwrap();
        check_returned_slate(&same, None).unwrap();
        let no_ttl = slate_from(json!({}));
        assert_eq!(
            check_returned_slate(&no_ttl, Some(500)).unwrap_err().code,
            GrinErrorCode::Slate
        );
        check_returned_slate(&no_ttl, None).unwrap();
        let locked = slate_from(json!({"ttl": 500, "feat": 2, "feat_args": {"lock_hgt": 9}}));
        assert_eq!(
            check_returned_slate(&locked, Some(500)).unwrap_err().code,
            GrinErrorCode::Slate
        );
        assert_eq!(
            check_returned_slate(&locked, None).unwrap_err().code,
            GrinErrorCode::Slate
        );
        let nrd = slate_from(json!({"feat": 3, "feat_args": {"lock_hgt": 1}}));
        assert_eq!(
            check_returned_slate(&nrd, None).unwrap_err().code,
            GrinErrorCode::Slate
        );
    }

    #[test]
    fn returned_proofs_are_checked() {
        global::set_local_chain_type(ChainTypes::AutomatedTesting);
        let refused = |s1: &Slate, s2: &Slate| check_returned_proof(s1, s2).unwrap_err().code;
        let none = slate_from(json!({}));
        check_returned_proof(&none, &none).unwrap();

        let asked =
            slate_from(json!({"proof": {"saddr": key_hex(ADDR_A), "raddr": key_hex(ADDR_B)}}));
        // Not signed yet.
        assert_eq!(refused(&asked, &asked), GrinErrorCode::Transaction);
        let sig = "ab".repeat(64);
        let signed = slate_from(
            json!({"proof": {"saddr": key_hex(ADDR_A), "raddr": key_hex(ADDR_B), "rsig": sig}}),
        );
        check_returned_proof(&asked, &signed).unwrap();
        let other_receiver = slate_from(
            json!({"proof": {"saddr": key_hex(ADDR_A), "raddr": key_hex(ADDR_C), "rsig": sig}}),
        );
        assert_eq!(refused(&asked, &other_receiver), GrinErrorCode::Transaction);
        let other_sender = slate_from(
            json!({"proof": {"saddr": key_hex(ADDR_C), "raddr": key_hex(ADDR_B), "rsig": sig}}),
        );
        assert_eq!(refused(&asked, &other_sender), GrinErrorCode::Transaction);
        assert_eq!(refused(&asked, &none), GrinErrorCode::Transaction);
        assert_eq!(refused(&none, &signed), GrinErrorCode::Transaction);
    }

    #[test]
    fn amounts_from_log_entries() {
        use grin_keychain::Keychain;
        let id = ExtKeychain::derive_key_id(2, 0, 0, 0, 0);
        let mut t = TxLogEntry::new(id, TxLogEntryType::TxSent, 1);
        t.amount_debited = 100;
        t.amount_credited = 30;
        t.fee = grin_core::core::FeeFields::new(0, 5).ok();
        assert_eq!(logged_amount(&t), 65);
        t.amount_debited = 0;
        assert_eq!(logged_amount(&t), 30);
    }
}
