// Copyright 2021 The Grin Developers
//
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

use crate::blake2;
use core::num::NonZeroU32;
use rand::{thread_rng, Rng};
use serde_json;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
use std::path::MAIN_SEPARATOR;

use ring::aead;
use ring::pbkdf2;
use zeroize::Zeroize;

use crate::keychain::{mnemonic, Keychain};
use crate::lifecycle::default::fmt_path;
use crate::util::{self, ToHex};
use crate::Error;

pub const SEED_FILE: &str = "wallet.seed";

/// Temporary file a new seed file is written to before it replaces
/// [`SEED_FILE`].
const SEED_TMP_FILE: &str = "wallet.seed.tmp";

/// PBKDF2-HMAC-SHA512 iterations for newly written seed files.
pub const SEED_KDF_ITERATIONS: u32 = 210_000;

/// Iterations used by seed files that do not record a count.
const LEGACY_SEED_KDF_ITERATIONS: u32 = 100;

/// Upper bound on a recorded count, so a damaged or hostile file cannot make
/// opening the wallet take arbitrarily long.
const MAX_SEED_KDF_ITERATIONS: u32 = 10_000_000;

/// Salt length for newly written seed files.
const SEED_SALT_BYTES: usize = 16;

/// Creates `path` for writing, readable and writable only by its owner where
/// the platform supports it.
fn create_private_file(path: &Path) -> std::io::Result<File> {
	let mut opts = OpenOptions::new();
	opts.write(true).create(true).truncate(true);
	#[cfg(unix)]
	{
		use std::os::unix::fs::OpenOptionsExt;
		opts.mode(0o600);
	}
	opts.open(path)
}

/// Writes `enc_seed` as the seed file of `data_file_dir`.
///
/// The content goes to a temporary file that is synced and then renamed over
/// the seed file, so a failure at any point leaves either the old seed file
/// or the complete new one.
fn write_seed_file(data_file_dir: &str, enc_seed: &EncryptedWalletSeed) -> Result<(), Error> {
	let dir = fmt_path(data_file_dir.to_string());
	let seed_path = Path::new(&dir).join(SEED_FILE);
	let tmp_path = Path::new(&dir).join(SEED_TMP_FILE);
	let json = serde_json::to_string_pretty(enc_seed).map_err(|_| Error::Format)?;

	let write_tmp = || -> std::io::Result<()> {
		let mut file = create_private_file(&tmp_path)?;
		file.write_all(json.as_bytes())?;
		file.sync_all()
	};
	if let Err(e) = write_tmp() {
		let _ = fs::remove_file(&tmp_path);
		error!("Could not write {}: {}", tmp_path.display(), e);
		return Err(Error::IO);
	}
	if let Err(e) = fs::rename(&tmp_path, &seed_path) {
		let _ = fs::remove_file(&tmp_path);
		error!("Could not replace {}: {}", seed_path.display(), e);
		return Err(Error::IO);
	}
	// Make the rename itself durable. Not supported on every platform.
	#[cfg(unix)]
	{
		if let Ok(d) = File::open(&dir) {
			let _ = d.sync_all();
		}
	}
	Ok(())
}

fn read_encrypted_seed(seed_file_path: &str) -> Result<EncryptedWalletSeed, Error> {
	let mut file = File::open(seed_file_path).map_err(|_| Error::IO)?;
	let mut buffer = String::new();
	file.read_to_string(&mut buffer).map_err(|_| Error::IO)?;
	serde_json::from_str(&buffer).map_err(|_| Error::Format)
}

#[derive(Clone, PartialEq)]
pub struct WalletSeed(Vec<u8>);

impl Drop for WalletSeed {
	fn drop(&mut self) {
		self.0.zeroize();
	}
}

impl std::fmt::Debug for WalletSeed {
	// Never prints the seed bytes.
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		write!(f, "WalletSeed({} bytes)", self.0.len())
	}
}

impl WalletSeed {
	pub fn from_bytes(bytes: &[u8]) -> WalletSeed {
		WalletSeed(bytes.to_vec())
	}

	pub(super) fn is_empty(&self) -> bool {
		self.0.is_empty()
	}

	pub fn from_mnemonic(word_list: util::ZeroingString) -> Result<WalletSeed, Error> {
		let res = mnemonic::to_entropy(&word_list);
		match res {
			Ok(s) => Ok(WalletSeed::from_bytes(&s)),
			Err(mnemonic::Error::BadWord(_)) => {
				Err(Error::Mnemonic("invalid bip39 word".to_owned()))
			}
			Err(e) => Err(Error::Mnemonic(format!("{}", e))),
		}
	}

	pub fn _from_hex(hex: &str) -> Result<WalletSeed, Error> {
		let bytes = util::from_hex(&hex.to_string())
			.map_err(|_| Error::GenericError("Invalid hex".to_owned()))?;
		Ok(WalletSeed::from_bytes(&bytes))
	}

	pub fn _to_hex(&self) -> String {
		self.0.to_vec().to_hex()
	}

	pub fn to_mnemonic(&self) -> Result<String, Error> {
		let result = mnemonic::from_entropy(&self.0);
		match result {
			Ok(r) => Ok(r),
			Err(e) => Err(Error::Mnemonic(format!("{}", e))),
		}
	}

	pub fn _derive_keychain_old(old_wallet_seed: [u8; 32], password: &str) -> Vec<u8> {
		let seed = blake2::blake2b::blake2b(64, password.as_bytes(), &old_wallet_seed);
		seed.as_bytes().to_vec()
	}

	pub fn derive_keychain<K: Keychain>(&self, is_testnet: bool) -> Result<K, Error> {
		let result = K::from_seed(&self.0, is_testnet)?;
		Ok(result)
	}

	pub fn init_new(
		entropy_size: usize,
		test_mode: bool,
		password: Option<util::ZeroingString>,
	) -> Result<WalletSeed, Error> {
		let mut seed: Vec<u8> = vec![];
		let mut rng = thread_rng();
		if !test_mode {
			for _ in 0..entropy_size {
				seed.push(rng.gen());
			}
		} else {
			// Hash password and use for test seed so we have a way of keeping test wallets unique
			// but predictable
			seed = blake2::blake2b::blake2b(32, b"", password.unwrap().as_bytes())
				.as_bytes()
				.to_vec();
		}
		let _ = mnemonic::from_entropy(seed.as_slice())
			.map(util::ZeroingString::from)
			.map_err(|e| Error::Mnemonic(format!("{}", e)))?;
		Ok(WalletSeed(seed))
	}

	pub fn seed_file_exists(data_file_dir: &str) -> Result<bool, Error> {
		let seed_file_path = &format!(
			"{}{}{}",
			fmt_path(data_file_dir.to_string()),
			MAIN_SEPARATOR,
			SEED_FILE,
		);
		debug!("Seed file path: {}", seed_file_path);
		if Path::new(seed_file_path).exists() {
			Ok(true)
		} else {
			Ok(false)
		}
	}

	pub fn backup_seed(data_file_dir: &str) -> Result<String, Error> {
		let seed_file_name = &format!("{}{}{}", data_file_dir, MAIN_SEPARATOR, SEED_FILE,);

		let mut path = Path::new(seed_file_name).to_path_buf();
		path.pop();
		let mut backup_seed_file_name =
			format!("{}{}{}.bak", data_file_dir, MAIN_SEPARATOR, SEED_FILE);
		let mut i = 1;
		while Path::new(&backup_seed_file_name).exists() {
			backup_seed_file_name =
				format!("{}{}{}.bak.{}", data_file_dir, MAIN_SEPARATOR, SEED_FILE, i);
			i += 1;
		}
		path.push(backup_seed_file_name.clone());
		// Copy rather than move, so the seed file stays in place until a
		// complete replacement is renamed over it.
		if fs::copy(seed_file_name, backup_seed_file_name.as_str()).is_err() {
			let _ = fs::remove_file(&backup_seed_file_name);
			return Err(Error::GenericError("Can't back up wallet seed file".to_owned()).into());
		}
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			let _ = fs::set_permissions(&backup_seed_file_name, fs::Permissions::from_mode(0o600));
		}
		warn!("{} backed up as {}", seed_file_name, backup_seed_file_name);
		Ok(backup_seed_file_name)
	}

	pub fn recover_from_phrase(
		data_file_dir: &str,
		word_list: util::ZeroingString,
		password: util::ZeroingString,
	) -> Result<(), Error> {
		let seed_file_path = &format!(
			"{}{}{}",
			fmt_path(data_file_dir.to_string()),
			MAIN_SEPARATOR,
			SEED_FILE,
		);
		debug!("data file dir: {}", data_file_dir);
		if let Ok(true) = WalletSeed::seed_file_exists(data_file_dir) {
			debug!("seed file exists");
			WalletSeed::backup_seed(data_file_dir)?;
		}
		if !Path::new(&data_file_dir).exists() {
			return Err(Error::WalletDoesntExist(
				data_file_dir.to_owned(),
				"To create a new wallet from a recovery phrase, use 'grin-wallet init -r'"
					.to_owned(),
			)
			.into());
		}
		let seed = WalletSeed::from_mnemonic(word_list)?;
		let enc_seed = EncryptedWalletSeed::from_seed(&seed, password)?;
		debug!("Writing seed file at: {}", seed_file_path);
		write_seed_file(data_file_dir, &enc_seed)?;
		warn!("Seed created from word list");
		Ok(())
	}

	pub fn init_file(
		data_file_dir: &str,
		entropy_size: usize,
		recovery_phrase: Option<util::ZeroingString>,
		password: util::ZeroingString,
		test_mode: bool,
	) -> Result<WalletSeed, Error> {
		// create directory if it doesn't exist
		fs::create_dir_all(data_file_dir).map_err(|_| Error::IO)?;

		let seed_file_path = &format!(
			"{}{}{}",
			fmt_path(data_file_dir.to_string()),
			MAIN_SEPARATOR,
			SEED_FILE,
		);
		let data_file_dir = fmt_path(data_file_dir.to_string());
		warn!("Generating wallet seed file at: {}", seed_file_path);
		let exists = WalletSeed::seed_file_exists(&data_file_dir)?;
		if exists && !test_mode {
			let msg = format!("Wallet seed already exists at: {}", data_file_dir);
			error!("{}", msg);
			return Err(Error::WalletSeedExists(msg));
		}

		let seed = match recovery_phrase {
			Some(p) => WalletSeed::from_mnemonic(p)?,
			None => WalletSeed::init_new(entropy_size, test_mode, Some(password.clone()))?,
		};

		let enc_seed = EncryptedWalletSeed::from_seed(&seed, password)?;
		debug!("Writing seed file at: {}", seed_file_path);
		write_seed_file(&data_file_dir, &enc_seed)?;
		Ok(seed)
	}

	/// Re-encrypts the seed file of `data_file_dir` with `password`, using
	/// the current key derivation parameters, and checks the result before
	/// returning. The file is replaced atomically.
	pub fn rewrite_file(
		data_file_dir: &str,
		seed: &WalletSeed,
		password: util::ZeroingString,
	) -> Result<(), Error> {
		let enc_seed = EncryptedWalletSeed::from_seed(seed, password.clone())?;
		if enc_seed.decrypt(&password)? != *seed {
			return Err(Error::Encryption);
		}
		write_seed_file(data_file_dir, &enc_seed)?;
		if WalletSeed::from_file(data_file_dir, password)? != *seed {
			return Err(Error::Encryption);
		}
		Ok(())
	}

	/// Rewrites the seed file with the current key derivation parameters if
	/// it uses weaker ones. Returns whether it was rewritten.
	pub fn upgrade_file(data_file_dir: &str, password: util::ZeroingString) -> Result<bool, Error> {
		let seed_file_path = &format!(
			"{}{}{}",
			fmt_path(data_file_dir.to_string()),
			MAIN_SEPARATOR,
			SEED_FILE,
		);
		let enc_seed = read_encrypted_seed(seed_file_path)?;
		if enc_seed.kdf_iterations()? >= SEED_KDF_ITERATIONS {
			return Ok(false);
		}
		let seed = enc_seed.decrypt(&password)?;
		WalletSeed::rewrite_file(data_file_dir, &seed, password)?;
		Ok(true)
	}

	pub fn from_file(
		data_file_dir: &str,
		password: util::ZeroingString,
	) -> Result<WalletSeed, Error> {
		// create directory if it doesn't exist
		fs::create_dir_all(data_file_dir).map_err(|_| Error::IO)?;

		let seed_file_path = &format!(
			"{}{}{}",
			fmt_path(data_file_dir.to_string()),
			MAIN_SEPARATOR,
			SEED_FILE,
		);

		debug!("Using wallet seed file at: {}", seed_file_path);

		if Path::new(seed_file_path).exists() {
			let enc_seed = read_encrypted_seed(seed_file_path)?;
			let wallet_seed = enc_seed.decrypt(&password)?;
			Ok(wallet_seed)
		} else {
			error!(
				"wallet seed file {} could not be opened (grin-wallet init). \
				 Run \"grin-wallet init\" to initialize a new wallet.",
				seed_file_path
			);
			Err(Error::WalletSeedDoesntExist)
		}
	}

	pub fn delete_seed_file(data_file_dir: &str) -> Result<(), Error> {
		let seed_file_path = &format!(
			"{}{}{}",
			fmt_path(data_file_dir.to_string()),
			MAIN_SEPARATOR,
			SEED_FILE,
		);
		if Path::new(seed_file_path).exists() {
			debug!("Deleting wallet seed file at: {}", seed_file_path);
			fs::remove_file(seed_file_path).map_err(|_| Error::IO)?;
		}
		Ok(())
	}
}

/// Derives the seed encryption key from a password.
fn seed_key(password: &[u8], salt: &[u8], iterations: u32) -> Result<[u8; 32], Error> {
	let iterations = NonZeroU32::new(iterations).ok_or(Error::Format)?;
	let mut key = [0; 32];
	pbkdf2::derive(
		pbkdf2::PBKDF2_HMAC_SHA512,
		iterations,
		salt,
		password,
		&mut key,
	);
	Ok(key)
}

/// Encrypted wallet seed, for storing on disk and decrypting
/// with provided password

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct EncryptedWalletSeed {
	encrypted_seed: String,
	/// Salt, not so useful in single case but include anyhow for situations
	/// where someone wants to store many of these
	pub salt: String,
	/// Nonce
	pub nonce: String,
	/// PBKDF2-HMAC-SHA512 iterations. Files written before this field
	/// existed use 100.
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub kdf_iterations: Option<u32>,
}

impl EncryptedWalletSeed {
	/// Create a new encrypted seed from the given seed + password
	pub fn from_seed(
		seed: &WalletSeed,
		password: util::ZeroingString,
	) -> Result<EncryptedWalletSeed, Error> {
		EncryptedWalletSeed::from_seed_with(seed, password, SEED_KDF_ITERATIONS)
	}

	fn from_seed_with(
		seed: &WalletSeed,
		password: util::ZeroingString,
		iterations: u32,
	) -> Result<EncryptedWalletSeed, Error> {
		let salt: [u8; SEED_SALT_BYTES] = thread_rng().gen();
		let nonce: [u8; 12] = thread_rng().gen();
		let key = seed_key(password.as_bytes(), &salt, iterations)?;
		let content = seed.0.to_vec();
		let mut enc_bytes = content;
		/*let suffix_len = aead::CHACHA20_POLY1305.tag_len();
		for _ in 0..suffix_len {
			enc_bytes.push(0);
		}*/
		let unbound_key = aead::UnboundKey::new(&aead::CHACHA20_POLY1305, &key).unwrap();
		let sealing_key: aead::LessSafeKey = aead::LessSafeKey::new(unbound_key);
		let aad = aead::Aad::from(&[]);
		let res = sealing_key.seal_in_place_append_tag(
			aead::Nonce::assume_unique_for_key(nonce),
			aad,
			&mut enc_bytes,
		);
		if let Err(_) = res {
			return Err(Error::Encryption);
		}

		Ok(EncryptedWalletSeed {
			encrypted_seed: enc_bytes.to_hex(),
			salt: salt.to_hex(),
			nonce: nonce.to_hex(),
			kdf_iterations: Some(iterations),
		})
	}

	/// The iteration count this seed was encrypted with.
	pub fn kdf_iterations(&self) -> Result<u32, Error> {
		match self.kdf_iterations {
			None => Ok(LEGACY_SEED_KDF_ITERATIONS),
			Some(n) if n >= 1 && n <= MAX_SEED_KDF_ITERATIONS => Ok(n),
			Some(_) => Err(Error::Format),
		}
	}

	/// Decrypt seed
	pub fn decrypt(&self, password: &str) -> Result<WalletSeed, Error> {
		let mut encrypted_seed = match util::from_hex(&self.encrypted_seed.clone()) {
			Ok(s) => s,
			Err(_) => return Err(Error::Encryption),
		};
		let salt = match util::from_hex(&self.salt.clone()) {
			Ok(s) => s,
			Err(_) => return Err(Error::Encryption),
		};
		let nonce = match util::from_hex(&self.nonce.clone()) {
			Ok(s) => s,
			Err(_) => return Err(Error::Encryption),
		};
		let key = seed_key(password.as_bytes(), &salt, self.kdf_iterations()?)?;

		if nonce.len() != 12 {
			return Err(Error::Encryption);
		}
		let mut n = [0u8; 12];
		n.copy_from_slice(&nonce[0..12]);
		let unbound_key = aead::UnboundKey::new(&aead::CHACHA20_POLY1305, &key).unwrap();
		let opening_key: aead::LessSafeKey = aead::LessSafeKey::new(unbound_key);
		let aad = aead::Aad::from(&[]);
		let res = opening_key.open_in_place(
			aead::Nonce::assume_unique_for_key(n),
			aad,
			&mut encrypted_seed,
		);
		if let Err(_) = res {
			return Err(Error::Encryption);
		}
		for _ in 0..aead::AES_256_GCM.tag_len() {
			encrypted_seed.pop();
		}

		let seed = WalletSeed::from_bytes(&encrypted_seed);
		encrypted_seed.zeroize();
		Ok(seed)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::util::ZeroingString;
	#[test]
	fn wallet_seed_encrypt() {
		// Wrong entropy size.
		let wrong_entropy_size = WalletSeed::init_new(31, false, None).err();
		assert!(wrong_entropy_size.is_some());

		let password = ZeroingString::from("passwoid");
		let wallet_seed = WalletSeed::init_new(32, false, None).unwrap();
		let mut enc_wallet_seed =
			EncryptedWalletSeed::from_seed(&wallet_seed, password.clone()).unwrap();
		println!("EWS: {:?}", enc_wallet_seed);
		let decrypted_wallet_seed = enc_wallet_seed.decrypt(&password).unwrap();
		assert_eq!(wallet_seed, decrypted_wallet_seed);

		// Wrong password
		let decrypted_wallet_seed = enc_wallet_seed.decrypt("");
		assert!(decrypted_wallet_seed.is_err());

		// Wrong nonce
		enc_wallet_seed.nonce = "wrongnonce".to_owned();
		let decrypted_wallet_seed = enc_wallet_seed.decrypt(&password);
		assert!(decrypted_wallet_seed.is_err());

		// Nonce of the wrong length
		enc_wallet_seed.nonce = "00".to_owned();
		let decrypted_wallet_seed = enc_wallet_seed.decrypt(&password);
		assert!(decrypted_wallet_seed.is_err());
	}

	struct TempDir(std::path::PathBuf);

	impl TempDir {
		fn new(name: &str) -> TempDir {
			let mut p = std::env::temp_dir();
			let n: u64 = thread_rng().gen();
			p.push(format!("{}-{}-{:x}", name, std::process::id(), n));
			fs::create_dir_all(&p).unwrap();
			TempDir(p)
		}

		fn path(&self) -> &str {
			self.0.to_str().unwrap()
		}

		fn file(&self, name: &str) -> std::path::PathBuf {
			self.0.join(name)
		}
	}

	impl Drop for TempDir {
		fn drop(&mut self) {
			let _ = fs::remove_dir_all(&self.0);
		}
	}

	/// Writes a seed file the way versions before `kdf_iterations` did.
	fn write_legacy_seed(dir: &TempDir, seed: &WalletSeed, password: &ZeroingString) {
		let mut enc =
			EncryptedWalletSeed::from_seed_with(seed, password.clone(), LEGACY_SEED_KDF_ITERATIONS)
				.unwrap();
		enc.kdf_iterations = None;
		let json = serde_json::to_string_pretty(&enc).unwrap();
		assert!(!json.contains("kdf_iterations"));
		fs::write(dir.file(SEED_FILE), json).unwrap();
	}

	fn stored_iterations(dir: &TempDir) -> u32 {
		read_encrypted_seed(dir.file(SEED_FILE).to_str().unwrap())
			.unwrap()
			.kdf_iterations()
			.unwrap()
	}

	#[test]
	fn new_seed_file_records_iterations() {
		let dir = TempDir::new("seed-new");
		let password = ZeroingString::from("passwoid");
		let seed = WalletSeed::init_file(dir.path(), 32, None, password.clone(), false).unwrap();
		assert_eq!(stored_iterations(&dir), SEED_KDF_ITERATIONS);
		assert_eq!(WalletSeed::from_file(dir.path(), password).unwrap(), seed);
		assert!(!dir.file(SEED_TMP_FILE).exists());
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			let mode = fs::metadata(dir.file(SEED_FILE))
				.unwrap()
				.permissions()
				.mode();
			assert_eq!(mode & 0o777, 0o600);
		}
	}

	#[test]
	fn legacy_seed_file_opens_and_upgrades() {
		let dir = TempDir::new("seed-legacy");
		let password = ZeroingString::from("passwoid");
		let seed = WalletSeed::init_new(32, false, None).unwrap();
		write_legacy_seed(&dir, &seed, &password);
		assert_eq!(stored_iterations(&dir), LEGACY_SEED_KDF_ITERATIONS);
		assert_eq!(
			WalletSeed::from_file(dir.path(), password.clone()).unwrap(),
			seed
		);

		assert!(WalletSeed::upgrade_file(dir.path(), password.clone()).unwrap());
		assert_eq!(stored_iterations(&dir), SEED_KDF_ITERATIONS);
		assert_eq!(
			WalletSeed::from_file(dir.path(), password.clone()).unwrap(),
			seed
		);
		assert!(!WalletSeed::upgrade_file(dir.path(), password).unwrap());
	}

	#[test]
	fn upgrade_with_wrong_password_leaves_file() {
		let dir = TempDir::new("seed-wrongpw");
		let password = ZeroingString::from("passwoid");
		let seed = WalletSeed::init_new(32, false, None).unwrap();
		write_legacy_seed(&dir, &seed, &password);
		let before = fs::read(dir.file(SEED_FILE)).unwrap();
		assert!(WalletSeed::upgrade_file(dir.path(), ZeroingString::from("nope")).is_err());
		assert_eq!(fs::read(dir.file(SEED_FILE)).unwrap(), before);
	}

	#[test]
	fn failed_rewrite_keeps_old_seed_file() {
		let dir = TempDir::new("seed-fail");
		let old = ZeroingString::from("old");
		let seed = WalletSeed::init_file(dir.path(), 32, None, old.clone(), false).unwrap();
		let before = fs::read(dir.file(SEED_FILE)).unwrap();
		// A directory where the temporary file goes makes the write fail.
		fs::create_dir(dir.file(SEED_TMP_FILE)).unwrap();
		assert!(WalletSeed::rewrite_file(dir.path(), &seed, ZeroingString::from("new")).is_err());
		assert_eq!(fs::read(dir.file(SEED_FILE)).unwrap(), before);
		assert_eq!(WalletSeed::from_file(dir.path(), old).unwrap(), seed);
	}

	#[test]
	fn rewrite_changes_password() {
		let dir = TempDir::new("seed-rewrite");
		let old = ZeroingString::from("old");
		let new = ZeroingString::from("new");
		let seed = WalletSeed::init_file(dir.path(), 32, None, old.clone(), false).unwrap();
		WalletSeed::rewrite_file(dir.path(), &seed, new.clone()).unwrap();
		assert!(WalletSeed::from_file(dir.path(), old).is_err());
		assert_eq!(WalletSeed::from_file(dir.path(), new).unwrap(), seed);
		assert!(!dir.file(SEED_TMP_FILE).exists());
	}

	#[test]
	fn out_of_range_iterations_are_rejected() {
		let seed = WalletSeed::init_new(32, false, None).unwrap();
		let password = ZeroingString::from("passwoid");
		let mut enc = EncryptedWalletSeed::from_seed(&seed, password.clone()).unwrap();
		enc.kdf_iterations = Some(0);
		assert!(enc.decrypt(&password).is_err());
		enc.kdf_iterations = Some(MAX_SEED_KDF_ITERATIONS + 1);
		assert!(enc.decrypt(&password).is_err());
	}
}
