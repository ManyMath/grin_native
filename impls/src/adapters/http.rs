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

use crate::client_utils::{Client, ClientError};
use crate::libwallet::slate_versions::{SlateVersion, VersionedSlate};
use crate::libwallet::{Error, Slate};
use crate::SlateSender;
use serde::Serialize;
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::time::Duration;

#[derive(Clone)]
pub struct HttpSlateSender {
	base_url: String,
	socks_proxy_addr: Option<SocketAddr>,
	request_timeout: Duration,
}

impl HttpSlateSender {
	/// Create a direct HTTP/HTTPS slate sender, returning Err if scheme is not "http" or "https"
	pub fn new(base_url: &str, request_timeout: Duration) -> Result<HttpSlateSender, Error> {
		if !base_url.starts_with("http") && !base_url.starts_with("https") {
			Err(Error::GenericError("Scheme must be http".to_string()))
		} else {
			Ok(HttpSlateSender {
				base_url: base_url.to_owned(),
				socks_proxy_addr: None,
				request_timeout,
			})
		}
	}

	/// Create an HTTP/HTTPS slate sender routed through a SOCKS5h proxy (e.g. external Tor daemon)
	pub fn with_socks_proxy(
		base_url: &str,
		socks_proxy_addr: SocketAddr,
		request_timeout: Duration,
	) -> Result<HttpSlateSender, Error> {
		let mut sender = Self::new(base_url, request_timeout)?;
		sender.socks_proxy_addr = Some(socks_proxy_addr);
		Ok(sender)
	}

	/// Check version of the listening wallet
	pub fn check_other_version(&mut self, url: &str) -> Result<SlateVersion, Error> {
		self.check_other_version_with(url, true, |u, req| self.post(u, req))
	}

	pub(crate) fn check_other_version_with<F>(
		&self,
		url: &str,
		report_404_upgrade: bool,
		post_fn: F,
	) -> Result<SlateVersion, Error>
	where
		F: FnOnce(&str, Value) -> Result<String, ClientError>,
	{
		let req = json!({
			"jsonrpc": "2.0",
			"method": "check_version",
			"id": 1,
			"params": []
		});

		let res: String = post_fn(url, req).map_err(|e| {
			let mut report = format!("Performing version check (is recipient listening?): {}", e);
			let err_string = format!("{}", e);
			if report_404_upgrade && err_string.contains("404") {
				// Report that the other version of the wallet is out of date
				report = "Other wallet is incompatible and requires an upgrade. \
				          Please urge the other wallet owner to upgrade and try the transaction again."
					.to_string();
				error!("{}", report);
			}
			Error::ClientCallback(report)
		})?;

		let res: Value = serde_json::from_str(&res)
			.map_err(|_| Error::ClientCallback(format!("Can not parse response {:?}", res)))?;
		trace!("Response: {}", res);
		if res["error"] != json!(null) {
			let report = format!(
				"Posting transaction slate: Error: {}, Message: {}",
				res["error"]["code"], res["error"]["message"]
			);
			error!("{}", report);
			return Err(Error::ClientCallback(report));
		}

		let resp_value = res["result"]["Ok"].clone();
		trace!("resp_value: {}", resp_value.clone());
		let foreign_api_version: u16 =
			serde_json::from_value(resp_value["foreign_api_version"].clone())
				.map_err(|_| Error::ClientCallback(format!("Can not parse response {:?}", res)))?;
		let supported_slate_versions: Vec<String> =
			serde_json::from_value(resp_value["supported_slate_versions"].clone())
				.map_err(|_| Error::ClientCallback(format!("Can not parse response {:?}", res)))?;

		// trivial tests for now, but will be expanded later
		if foreign_api_version < 2 {
			let report = "Other wallet reports unrecognized API format.".to_string();
			error!("{}", report);
			return Err(Error::ClientCallback(report));
		}

		if supported_slate_versions.contains(&"V4".to_owned()) {
			return Ok(SlateVersion::V4);
		}

		let report = "Unable to negotiate slate format with other wallet.".to_string();
		error!("{}", report);
		Err(Error::ClientCallback(report))
	}

	pub fn post<IN>(&self, url: &str, input: IN) -> Result<String, ClientError>
	where
		IN: Serialize,
	{
		let client = match self.socks_proxy_addr {
			Some(socks_proxy_addr) => {
				Client::with_proxy(socks_proxy_addr, "socks5h://", self.request_timeout)
			}
			None => Client::new(self.request_timeout),
		}
		.map_err(|_| ClientError::Internal("Unable to create http client".into()))?;
		let req = client.create_post_request(url, None, &input)?;
		client.send_request(req)
	}

	pub(crate) fn send_tx_with<F>(
		&self,
		slate: &Slate,
		finalize: bool,
		report_404_upgrade: bool,
		mut post_fn: F,
	) -> Result<Slate, Error>
	where
		F: FnMut(&str, Value) -> Result<String, ClientError>,
	{
		let trailing = match self.base_url.ends_with('/') {
			true => "",
			false => "/",
		};
		let url_str = format!("{}{}v2/foreign", self.base_url, trailing);

		let slate_send =
			match self
				.check_other_version_with(&url_str, report_404_upgrade, |u, req| post_fn(u, req))?
			{
				SlateVersion::V4 => VersionedSlate::into_version(slate.clone(), SlateVersion::V4)?,
			};
		// Note: not using easy-jsonrpc as don't want the dependencies in this crate
		let req = match finalize {
			false => json!({
				"jsonrpc": "2.0",
				"method": "receive_tx",
				"id": 1,
				"params": [
							slate_send,
							null,
							null
						]
			}),
			true => json!({
				"jsonrpc": "2.0",
				"method": "finalize_tx",
				"id": 1,
				"params": [
							slate_send
						]
			}),
		};

		trace!("Sending receive_tx request: {}", req);

		let res: String = post_fn(&url_str, req).map_err(|e| {
			let report = format!(
				"Sending transaction slate to other wallet (is recipient listening?): {}",
				e
			);
			Error::ClientCallback(report)
		})?;

		let res: Value = serde_json::from_str(&res)
			.map_err(|_| Error::ClientCallback(format!("Can not parse response {:?}", res)))?;
		trace!("Response: {}", res);
		if res["error"] != json!(null) {
			let report = format!(
				"Posting transaction slate: Error: {}, Message: {}",
				res["error"]["code"], res["error"]["message"]
			);
			error!("{}", report);
			return Err(Error::ClientCallback(report));
		}

		let slate_value = res["result"]["Ok"].clone();

		trace!("slate_value: {}", slate_value);
		if let Ok(slate_value) = serde_json::to_string(&slate_value) {
			let slate = Slate::deserialize_upgrade(&slate_value).map_err(|e| {
				error!("Error deserializing response slate: {}", e);
				Error::SlateDeser
			})?;
			Ok(slate)
		} else {
			error!("Error deserializing response slate: {}", slate_value);
			Err(Error::SlateDeser)
		}
	}
}

impl SlateSender for HttpSlateSender {
	fn send_tx(&mut self, slate: &Slate, finalize: bool) -> Result<Slate, Error> {
		self.send_tx_with(slate, finalize, true, |u, req| self.post(u, req))
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::core::global::{self, ChainTypes};
	use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
	use tokio::net::TcpListener;
	use tokio::task::JoinHandle;

	const VERSION_OK: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"Ok":{"foreign_api_version":2,"supported_slate_versions":["V4"]}}}"#;

	/// Serves one scripted (status, body) response per connection, returns
	/// the (request line, body) pairs it saw
	async fn mock_server(
		script: Vec<(&'static str, String)>,
	) -> (String, JoinHandle<Vec<(String, String)>>) {
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let url = format!("http://{}", listener.local_addr().unwrap());
		let server = tokio::spawn(async move {
			let mut seen = vec![];
			for (status, body) in script {
				let (mut stream, _) = listener.accept().await.unwrap();
				let mut reader = BufReader::new(&mut stream);
				let mut request_line = String::new();
				reader.read_line(&mut request_line).await.unwrap();
				let mut content_length = 0;
				loop {
					let mut line = String::new();
					reader.read_line(&mut line).await.unwrap();
					let line = line.trim_end();
					if line.is_empty() {
						break;
					}
					if let Some((name, value)) = line.split_once(':') {
						if name.eq_ignore_ascii_case("content-length") {
							content_length = value.trim().parse().unwrap();
						}
					}
				}
				let mut req_body = vec![0u8; content_length];
				reader.read_exact(&mut req_body).await.unwrap();
				seen.push((
					request_line.trim_end().to_string(),
					String::from_utf8(req_body).unwrap(),
				));
				let response = format!(
					"HTTP/1.1 {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
					status,
					body.len(),
					body
				);
				stream.write_all(response.as_bytes()).await.unwrap();
			}
			seen
		});
		(url, server)
	}

	fn sender(url: &str) -> HttpSlateSender {
		HttpSlateSender::new(url, Duration::from_secs(5)).unwrap()
	}

	#[test]
	fn rejects_bad_scheme() {
		assert!(HttpSlateSender::new("ftp://x", Duration::from_secs(5)).is_err());
	}

	#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
	async fn check_version_ok() {
		global::set_local_chain_type(ChainTypes::AutomatedTesting);
		let (url, server) = mock_server(vec![("200 OK", VERSION_OK.to_string())]).await;
		let res = sender(&url).check_other_version(&format!("{}/v2/foreign", url));
		assert!(matches!(res, Ok(SlateVersion::V4)), "{:?}", res);
		let seen = server.await.unwrap();
		assert_eq!(seen.len(), 1);
		assert!(seen[0].1.contains("\"method\":\"check_version\""));
	}

	#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
	async fn send_tx_receive_round_trip() {
		global::set_local_chain_type(ChainTypes::AutomatedTesting);
		let slate = Slate::blank(2, false);
		let returned = serde_json::to_value(
			VersionedSlate::into_version(slate.clone(), SlateVersion::V4).unwrap(),
		)
		.unwrap();
		let reply = json!({"jsonrpc": "2.0", "id": 1, "result": {"Ok": returned}});
		let (url, server) = mock_server(vec![
			("200 OK", VERSION_OK.to_string()),
			("200 OK", reply.to_string()),
		])
		.await;
		let res = sender(&url).send_tx(&slate, false);
		let seen = server.await.unwrap();
		let got = res.expect("send_tx failed");
		assert_eq!(got.id, slate.id);
		assert_eq!(seen.len(), 2);
		assert!(seen[0].0.starts_with("POST /v2/foreign "), "{}", seen[0].0);
		assert!(seen[1].0.starts_with("POST /v2/foreign "), "{}", seen[1].0);
		assert!(
			seen[1].1.contains("\"method\":\"receive_tx\""),
			"{}",
			seen[1].1
		);
	}

	#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
	async fn check_version_404_requires_upgrade() {
		global::set_local_chain_type(ChainTypes::AutomatedTesting);
		let (url, server) = mock_server(vec![("404 Not Found", String::new())]).await;
		let res = sender(&url).send_tx(&Slate::blank(2, false), false);
		server.await.unwrap();
		match res {
			Err(Error::ClientCallback(msg)) => {
				assert!(msg.contains("requires an upgrade"), "{}", msg)
			}
			other => panic!("unexpected result: {:?}", other),
		}
	}

	#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
	async fn check_version_rpc_error() {
		global::set_local_chain_type(ChainTypes::AutomatedTesting);
		let body =
			r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#;
		let (url, server) = mock_server(vec![("200 OK", body.to_string())]).await;
		let res = sender(&url).check_other_version(&format!("{}/v2/foreign", url));
		server.await.unwrap();
		match res {
			Err(Error::ClientCallback(msg)) => assert!(msg.contains("Method not found"), "{}", msg),
			other => panic!("unexpected result: {:?}", other),
		}
	}
}
