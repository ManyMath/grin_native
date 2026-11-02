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

use crate::adapters::http::HttpSlateSender;
use crate::client_utils::ClientError;
use crate::libwallet::slate_versions::SlateVersion;
use crate::libwallet::{Error, Slate};
use crate::tor::arti::{start_tor_client, tor_post};
use crate::tor::bridge::TorBridge;
use crate::tor::config as tor_config;
use crate::tor::process::TorProcess;
use crate::tor::proxy::TorProxy;
use crate::SlateSender;
use grin_wallet_config::TorConfig;
use serde::Serialize;
use std::collections::HashMap;
use std::convert::TryFrom;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct TorSlateSender {
	base_url: String,
	config: TorConfig,
	tor_process: Arc<Option<TorProcess>>,
}

impl TorSlateSender {
	/// Create, return Err if scheme is not "http"
	pub fn new(base_url: &str, config: TorConfig) -> Result<TorSlateSender, Error> {
		if !base_url.starts_with("http") && !base_url.starts_with("https") {
			Err(Error::GenericError("Scheme must be http".to_string()))
		} else {
			let tor = if config.use_integrated.unwrap_or(false) {
				start_tor_client(config.clone())?;
				None
			} else {
				let tor_dir = {
					let mut path = PathBuf::from(&config.send_config_dir);
					path.push("tor");
					path.push("sender");
					path
				};
				let p = Self::launch_tor_process(&config, &tor_dir)?;
				Some(p)
			};
			Ok(TorSlateSender {
				base_url: base_url.to_owned(),
				config,
				tor_process: Arc::new(tor),
			})
		}
	}

	/// Launch external Tor process.
	fn launch_tor_process(config: &TorConfig, tor_dir: &PathBuf) -> Result<TorProcess, Error> {
		let mut tor = TorProcess::new();
		let socks_proxy_addr = SocketAddr::V4(
			config
				.socks_proxy_addr
				.parse()
				.map_err(|e| Error::TorConfig(format!("{:?}", e)))?,
		);
		info!("Starting TOR Process for send at {:?}", socks_proxy_addr);

		let mut hm_tor_bridge: HashMap<String, String> = HashMap::new();
		if config.bridge.bridge_line.is_some() {
			let bridge_struct = TorBridge::try_from(config.bridge.clone())
				.map_err(|e| Error::TorConfig(format!("{:?}", e)))?;
			hm_tor_bridge = bridge_struct
				.to_hashmap()
				.map_err(|e| Error::TorConfig(format!("{:?}", e)))?;
		}

		let mut hm_tor_proxy: HashMap<String, String> = HashMap::new();
		if config.proxy.transport.is_some() || config.proxy.allowed_port.is_some() {
			let proxy = TorProxy::try_from(config.proxy.clone())
				.map_err(|e| Error::TorConfig(format!("{:?}", e)))?;
			hm_tor_proxy = proxy
				.to_hashmap()
				.map_err(|e| Error::TorConfig(format!("{:?}", e)))?;
		}

		tor_config::output_tor_sender_config(
			tor_dir.to_str().unwrap(),
			socks_proxy_addr.to_string().as_str(),
			hm_tor_bridge,
			hm_tor_proxy,
		)
		.map_err(|e| Error::TorConfig(format!("{:?}", e)))?;
		// Start TOR process
		let mut path = tor_dir.clone();
		path.push("torrc");
		tor.torrc_path(path.to_str().unwrap())
			.working_dir(tor_dir.to_str().unwrap())
			.timeout(config.bootstrap_timeout().as_secs())
			.completion_percent(100)
			.launch()
			.map_err(|e| Error::TorProcess(format!("{:?}", e)))?;
		Ok(tor)
	}

	/// Check version of the listening wallet
	pub fn check_other_version(&mut self, url: &str) -> Result<SlateVersion, Error> {
		let http = HttpSlateSender::new(&self.base_url, self.config.request_timeout())?;
		http.check_other_version_with(
			url,
			!self.config.use_integrated.unwrap_or(false),
			|u, req| self.post(u, req),
		)
	}

	fn post<IN>(&self, url: &str, input: IN) -> Result<String, ClientError>
	where
		IN: Serialize,
	{
		let res = if self.tor_process.is_some() {
			let socks_proxy_addr =
				SocketAddr::V4(self.config.socks_proxy_addr.parse().map_err(|_| {
					ClientError::Internal("Socks proxy address is not set".to_string())
				})?);
			let timeout = self.config.request_timeout();
			let http = HttpSlateSender::with_socks_proxy(&self.base_url, socks_proxy_addr, timeout)
				.map_err(|_| ClientError::Internal("Unable to create http client".into()))?;
			http.post(url, input)?
		} else {
			tor_post(&self.config, &input, url)
				.map_err(|e| ClientError::RequestError(format!("{:?}", e)))?
		};
		Ok(res)
	}
}

impl SlateSender for TorSlateSender {
	fn send_tx(&mut self, slate: &Slate, finalize: bool) -> Result<Slate, Error> {
		let http = HttpSlateSender::new(&self.base_url, self.config.request_timeout())?;
		http.send_tx_with(
			slate,
			finalize,
			!self.config.use_integrated.unwrap_or(false),
			|u, req| self.post(u, req),
		)
	}
}
