// Copyright 2021 The Grin Developers
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! A transaction cancelled by one side and then mined anyway
#[macro_use]
extern crate log;
extern crate grin_wallet_controller as wallet;
extern crate grin_wallet_impls as impls;

use grin_core as core;
use grin_wallet_libwallet as libwallet;

use impls::test_framework::{self, LocalWalletClient};
use libwallet::{InitTxArgs, IssueInvoiceTxArgs, SlateState, TxLogEntryType};
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

#[macro_use]
mod common;
use common::{clean_output_dir, create_wallet_proxy, setup};

fn cancelled_invoice_payment_confirmed_impl(
	test_dir: &'static str,
) -> Result<(), libwallet::Error> {
	let mut wallet_proxy = create_wallet_proxy(test_dir);
	let chain = wallet_proxy.chain.clone();
	let stopper = wallet_proxy.running.clone();

	create_wallet_and_add!(
		client1,
		wallet1,
		mask1_i,
		test_dir,
		"wallet1",
		None,
		&mut wallet_proxy,
		true,
		api1
	);
	let mask1 = (&mask1_i).as_ref();
	create_wallet_and_add!(
		client2,
		wallet2,
		mask2_i,
		test_dir,
		"wallet2",
		None,
		&mut wallet_proxy,
		true,
		api2
	);
	let mask2 = (&mask2_i).as_ref();

	thread::spawn(move || {
		if let Err(e) = wallet_proxy.run() {
			error!("Wallet Proxy error: {}", e);
		}
	});

	let reward = core::consensus::REWARD;
	let _ = test_framework::award_blocks_to_wallet(&chain, wallet1.clone(), mask1, 10, false);

	// Wallet 2 asks wallet 1 for a payment.
	let args = IssueInvoiceTxArgs {
		amount: reward / 2,
		..Default::default()
	};
	let mut slate = api2.issue_invoice_tx(mask2, args)?;

	// Wallet 1 pays, then cancels its side.
	let args = InitTxArgs {
		src_acct_name: None,
		amount: slate.amount,
		minimum_confirmations: 2,
		max_outputs: 500,
		num_change_outputs: 1,
		selection_strategy_is_use_all: false,
		..Default::default()
	};
	slate = api1.process_invoice_tx(mask1, &slate, args)?;
	api1.tx_lock_outputs(mask1, &slate)?;
	api1.cancel_tx(mask1, None, Some(slate.id))?;
	let (_, txs) = api1.retrieve_txs(mask1, false, None, Some(slate.id), None)?;
	assert_eq!(txs[0].tx_type, TxLogEntryType::TxSentCancelled);

	// Wallet 2 still holds the signed payment, finalizes and posts it.
	slate = api2.finalize_tx(mask2, &slate)?;
	assert_eq!(slate.state, SlateState::Invoice3);
	api2.post_tx(mask2, &slate, false)?;
	let _ = test_framework::award_blocks_to_wallet(&chain, wallet1.clone(), mask1, 3, false);

	// The payment was mined.
	let (refreshed, txs) = api2.retrieve_txs(mask2, true, None, Some(slate.id), None)?;
	assert!(refreshed);
	assert!(txs.iter().any(|t| t.confirmed));

	// An ordinary refresh must see that the cancelled payment's inputs were
	// spent, and agree with a full scan.
	let (refreshed, after_refresh) = api1.retrieve_summary_info(mask1, true, 1)?;
	assert!(refreshed);
	let (_, again) = api1.retrieve_summary_info(mask1, true, 1)?;
	api1.scan(mask1, None, false)?;
	let (_, after_scan) = api1.retrieve_summary_info(mask1, true, 1)?;
	assert_eq!(after_refresh.total, after_scan.total);
	assert_eq!(again.total, after_scan.total);
	assert_eq!(
		after_refresh.amount_currently_spendable,
		after_scan.amount_currently_spendable
	);
	assert!(after_refresh.total < 13 * reward - reward / 2);

	// The entry records the payment that happened.
	let (_, txs) = api1.retrieve_txs(mask1, false, None, Some(slate.id), None)?;
	assert_eq!(txs[0].tx_type, TxLogEntryType::TxSent);
	assert!(txs[0].confirmed);

	stopper.store(false, Ordering::Relaxed);
	thread::sleep(Duration::from_millis(200));
	Ok(())
}

#[test]
fn cancelled_invoice_payment_confirmed() -> Result<(), libwallet::Error> {
	let test_dir = "test_output/cancelled_invoice_payment_confirmed";
	setup(test_dir);
	cancelled_invoice_payment_confirmed_impl(test_dir)?;
	clean_output_dir(test_dir);
	Ok(())
}
