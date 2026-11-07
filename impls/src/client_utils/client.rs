// Copyright 2018 The Grin Developers
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

//! High level JSON/HTTP client API

use crate::util::to_base64;
use lazy_static::lazy_static;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE, USER_AGENT};
use reqwest::{ClientBuilder, Method, Proxy, RequestBuilder};
use serde::{Deserialize, Serialize};
use serde_json;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::{Builder, Handle, Runtime};

/// Largest response body accepted from a node or a payment recipient.
/// The largest legitimate replies, output batches during a scan, are a few
/// MiB.
const MAX_RESPONSE_BYTES: usize = 32 * 1024 * 1024;

/// Reads a response body as UTF-8, failing once it exceeds `limit` bytes
/// rather than buffering whatever the server sends.
async fn read_body(mut resp: reqwest::Response, limit: usize) -> Result<String, Error> {
	let too_large = || Error::ResponseError(format!("Response larger than {} bytes", limit));
	if let Some(len) = resp.content_length() {
		if len > limit as u64 {
			return Err(too_large());
		}
	}
	let mut body = Vec::new();
	while let Some(chunk) = resp
		.chunk()
		.await
		.map_err(|e| Error::ResponseError(format!("Cannot read response: {}", e)))?
	{
		if body.len() + chunk.len() > limit {
			return Err(too_large());
		}
		body.extend_from_slice(&chunk);
	}
	String::from_utf8(body).map_err(|_| Error::ResponseError("Response is not UTF-8".into()))
}

// Global Tokio runtime.
lazy_static! {
	pub static ref RUNTIME: Arc<Runtime> =
		Arc::new(Builder::new_multi_thread().enable_all().build().unwrap());
}

#[derive(Clone, Eq, thiserror::Error, PartialEq, Debug)]
pub enum Error {
	#[error("Internal error: {0}")]
	Internal(String),
	#[error("Bad arguments: {0}")]
	_Argument(String),
	#[error("Not found.")]
	_NotFound,
	#[error("Request error: {0}")]
	RequestError(String),
	#[error("ResponseError error: {0}")]
	ResponseError(String),
}

#[derive(Clone)]
pub struct Client {
	client: reqwest::Client,
}

impl Client {
	/// New client
	pub fn new(request_timeout: Duration) -> Result<Self, Error> {
		Self::build(None, request_timeout)
	}

	pub fn with_proxy(
		socks_proxy_addr: SocketAddr,
		scheme: &'static str,
		request_timeout: Duration,
	) -> Result<Self, Error> {
		Self::build(Some((socks_proxy_addr, scheme)), request_timeout)
	}

	// reqwest's rustls-no-provider feature still links rustls-platform-verifier, but
	// handing it a built ClientConfig means the platform verifier is never constructed.
	// That matters on Android, where the verifier needs JNI setup we can't do from an FFI
	// library. Keep tls_backend_preconfigured here.
	#[allow(unused_mut)]
	fn configure_tls(mut builder: ClientBuilder) -> Result<ClientBuilder, Error> {
		#[cfg(all(feature = "rustls", not(feature = "native-tls")))]
		{
			let mut root_store = rustls::RootCertStore::empty();
			root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
			let mut tls_config = rustls::ClientConfig::builder_with_provider(Arc::new(
				rustls::crypto::ring::default_provider(),
			))
			.with_safe_default_protocol_versions()
			.map_err(|e| Error::Internal(format!("Unable to configure TLS: {}", e)))?
			.with_root_certificates(root_store)
			.with_no_client_auth();
			tls_config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
			builder = builder.tls_backend_preconfigured(tls_config);
		}
		Ok(builder)
	}

	fn build(proxy: Option<(SocketAddr, &str)>, request_timeout: Duration) -> Result<Self, Error> {
		let mut headers = HeaderMap::new();
		headers.insert(USER_AGENT, HeaderValue::from_static("grin-client"));
		headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
		headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

		// A JSON-RPC endpoint has no reason to redirect. Following one would
		// let a node or a payment recipient send the wallet's request (its
		// output commitments, a slate) to any origin the device can reach.
		let mut builder = Self::configure_tls(
			ClientBuilder::new()
				.timeout(request_timeout)
				.redirect(reqwest::redirect::Policy::none())
				.default_headers(headers),
		)?;

		if let Some(p) = proxy {
			let (addr, scheme) = p;
			let proxy = Proxy::all(&format!("{}{}:{}", scheme, addr.ip(), addr.port()))
				.map_err(|e| Error::Internal(format!("Unable to create proxy: {}", e)))?;
			builder = builder.proxy(proxy);
		}

		let client = builder
			.build()
			.map_err(|e| Error::Internal(format!("Unable to build client: {}", e)))?;

		Ok(Client { client })
	}

	/// Helper function to easily issue a HTTP GET request against a given URL that
	/// returns a JSON object. Handles request building, JSON deserialization and
	/// response code checking.
	pub fn _get<'a, T>(&self, url: &'a str, api_secret: Option<String>) -> Result<T, Error>
	where
		for<'de> T: Deserialize<'de>,
	{
		self.handle_request(self.build_request(url, Method::GET, api_secret, None)?)
	}

	/// Helper function to easily issue an async HTTP GET request against a given
	/// URL that returns a future. Handles request building, JSON deserialization
	/// and response code checking.
	pub async fn _get_async<'a, T>(
		&self,
		url: &'a str,
		api_secret: Option<String>,
	) -> Result<T, Error>
	where
		for<'de> T: Deserialize<'de> + Send + 'static,
	{
		self.handle_request_async(self.build_request(url, Method::GET, api_secret, None)?)
			.await
	}

	/// Helper function to easily issue a HTTP GET request
	/// on a given URL that returns nothing. Handles request
	/// building and response code checking.
	pub fn _get_no_ret(&self, url: &str, api_secret: Option<String>) -> Result<(), Error> {
		let req = self.build_request(url, Method::GET, api_secret, None)?;
		self.send_request(req)?;
		Ok(())
	}

	/// Helper function to easily issue a HTTP POST request with the provided JSON
	/// object as body on a given URL that returns a JSON object. Handles request
	/// building, JSON serialization and deserialization, and response code
	/// checking.
	pub fn post<IN, OUT>(
		&self,
		url: &str,
		api_secret: Option<String>,
		input: &IN,
	) -> Result<OUT, Error>
	where
		IN: Serialize,
		for<'de> OUT: Deserialize<'de>,
	{
		let req = self.create_post_request(url, api_secret, input)?;
		self.handle_request(req)
	}

	/// Helper function to easily issue an async HTTP POST request with the
	/// provided JSON object as body on a given URL that returns a future. Handles
	/// request building, JSON serialization and deserialization, and response code
	/// checking.
	pub async fn post_async<IN, OUT>(
		&self,
		url: &str,
		input: &IN,
		api_secret: Option<String>,
	) -> Result<OUT, Error>
	where
		IN: Serialize,
		OUT: Send + 'static,
		for<'de> OUT: Deserialize<'de>,
	{
		self.handle_request_async(self.create_post_request(url, api_secret, input)?)
			.await
	}

	/// Helper function to easily issue a HTTP POST request with the provided JSON
	/// object as body on a given URL that returns nothing. Handles request
	/// building, JSON serialization, and response code
	/// checking.
	pub fn _post_no_ret<IN>(
		&self,
		url: &str,
		api_secret: Option<String>,
		input: &IN,
	) -> Result<(), Error>
	where
		IN: Serialize,
	{
		let req = self.create_post_request(url, api_secret, input)?;
		self.send_request(req)?;
		Ok(())
	}

	/// Helper function to easily issue an async HTTP POST request with the
	/// provided JSON object as body on a given URL that returns a future. Handles
	/// request building, JSON serialization and deserialization, and response code
	/// checking.
	pub async fn _post_no_ret_async<IN>(
		&self,
		url: &str,
		api_secret: Option<String>,
		input: &IN,
	) -> Result<(), Error>
	where
		IN: Serialize,
	{
		self.send_request_async(self.create_post_request(url, api_secret, input)?)
			.await?;
		Ok(())
	}

	fn build_request(
		&self,
		url: &str,
		method: Method,
		api_secret: Option<String>,
		body: Option<String>,
	) -> Result<RequestBuilder, Error> {
		let mut builder = self.client.request(method, url);
		if let Some(api_secret) = api_secret {
			let basic_auth = format!("Basic {}", to_base64(&format!("grin:{}", api_secret)));
			builder = builder.header(AUTHORIZATION, basic_auth);
		}

		if let Some(body) = body {
			builder = builder.body(body);
		}

		Ok(builder)
	}

	pub fn create_post_request<IN>(
		&self,
		url: &str,
		api_secret: Option<String>,
		input: &IN,
	) -> Result<RequestBuilder, Error>
	where
		IN: Serialize,
	{
		let json = serde_json::to_string(input)
			.map_err(|e| Error::Internal(format!("Could not serialize data to JSON: {}", e)))?;
		self.build_request(url, Method::POST, api_secret, Some(json))
	}

	fn handle_request<T>(&self, req: RequestBuilder) -> Result<T, Error>
	where
		for<'de> T: Deserialize<'de>,
	{
		let data = self.send_request(req)?;
		serde_json::from_str(&data)
			.map_err(|e| Error::ResponseError(format!("Cannot parse response: {}", e)))
	}

	async fn handle_request_async<T>(&self, req: RequestBuilder) -> Result<T, Error>
	where
		for<'de> T: Deserialize<'de> + Send + 'static,
	{
		let data = self.send_request_async(req).await?;
		let ser = serde_json::from_str(&data)
			.map_err(|e| Error::ResponseError(format!("Cannot parse response: {}", e)))?;
		Ok(ser)
	}

	async fn send_request_async(&self, req: RequestBuilder) -> Result<String, Error> {
		let resp = req
			.send()
			.await
			.map_err(|e| Error::RequestError(format!("Cannot make request: {}", e)))?;
		let status = resp.status();
		if status.is_redirection() || status.is_client_error() || status.is_server_error() {
			return Err(Error::ResponseError(format!("HTTP {}", status)));
		}
		read_body(resp, MAX_RESPONSE_BYTES).await
	}

	pub fn send_request(&self, req: RequestBuilder) -> Result<String, Error> {
		// This client is currently used both outside and inside the tokio runtime
		// context. In the latter case we are not allowed to do a blocking call to
		// our global runtime, which unfortunately means we have to spawn a new thread
		if Handle::try_current().is_ok() {
			let rt = RUNTIME.clone();
			let client = self.clone();
			let chain_type = crate::core::global::CHAIN_TYPE.with(|c| c.get());
			std::thread::spawn(move || {
				if let Some(ct) = chain_type {
					crate::core::global::set_local_chain_type(ct);
				}
				rt.block_on(async { client.send_request_async(req).await })
			})
			.join()
			.unwrap()
		} else {
			RUNTIME.block_on(self.send_request_async(req))
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
	use tokio::net::TcpListener;

	#[tokio::test]
	async fn http_status() {
		let client = Client {
			client: Client::configure_tls(
				ClientBuilder::new()
					.no_proxy()
					.redirect(reqwest::redirect::Policy::none())
					.timeout(Duration::from_secs(5)),
			)
			.unwrap()
			.build()
			.unwrap(),
		};
		for (status, body, expected) in [
			("200 OK", "{}", Ok(serde_json::json!({}))),
			(
				"401 Unauthorized",
				"<html>Unauthorized</html>",
				Err(Error::ResponseError("HTTP 401 Unauthorized".into())),
			),
			(
				"307 Temporary Redirect",
				"",
				Err(Error::ResponseError("HTTP 307 Temporary Redirect".into())),
			),
		] {
			let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
			let url = format!("http://{}", listener.local_addr().unwrap());
			let server = tokio::spawn(async move {
				let (mut stream, _) = listener.accept().await.unwrap();
				let mut headers = BufReader::new(&mut stream).lines();
				while let Some(line) = headers.next_line().await.unwrap() {
					if line.is_empty() {
						break;
					}
				}
				let response = format!(
					"HTTP/1.1 {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
					status,
					body.len(),
					body
				);
				stream.write_all(response.as_bytes()).await.unwrap();
			});
			assert_eq!(
				client._get_async::<serde_json::Value>(&url, None).await,
				expected
			);
			server.await.unwrap();
		}
	}

	/// Serves one response made of `head` followed by `body_len` spaces.
	async fn serve_once(head: String, body_len: usize) -> String {
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let url = format!("http://{}", listener.local_addr().unwrap());
		tokio::spawn(async move {
			let (mut stream, _) = listener.accept().await.unwrap();
			let mut headers = BufReader::new(&mut stream).lines();
			while let Some(line) = headers.next_line().await.unwrap() {
				if line.is_empty() {
					break;
				}
			}
			let _ = stream.write_all(head.as_bytes()).await;
			let block = vec![b' '; 4096];
			let mut left = body_len;
			while left > 0 {
				let n = left.min(block.len());
				if stream.write_all(&block[..n]).await.is_err() {
					return;
				}
				left -= n;
			}
		});
		url
	}

	async fn body_of(url: &str, limit: usize) -> Result<String, Error> {
		let resp = Client::configure_tls(reqwest::Client::builder().no_proxy())
			.unwrap()
			.build()
			.unwrap()
			.get(url)
			.send()
			.await
			.unwrap();
		read_body(resp, limit).await
	}

	#[tokio::test]
	async fn response_size_limit() {
		let limit = 64 * 1024;

		// Declared length over the limit.
		let url = serve_once(
			format!(
				"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
				limit + 1
			),
			limit + 1,
		)
		.await;
		assert!(body_of(&url, limit).await.is_err());

		// No declared length; the body runs past the limit.
		let url = serve_once(
			"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_string(),
			limit * 4,
		)
		.await;
		assert!(body_of(&url, limit).await.is_err());

		// Exactly the limit is accepted.
		let url = serve_once(
			format!(
				"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
				limit
			),
			limit,
		)
		.await;
		assert_eq!(body_of(&url, limit).await.unwrap().len(), limit);
	}

	/// A redirect is reported as an error and never followed: the target
	/// must not see a request, with or without the proxy-free client.
	#[tokio::test]
	async fn redirects_are_not_followed() {
		let client = Client::new(Duration::from_secs(5)).unwrap();
		let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let target_url = format!("http://{}", target.local_addr().unwrap());
		let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
		let hits2 = hits.clone();
		tokio::spawn(async move {
			while let Ok((mut stream, _)) = target.accept().await {
				hits2.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
				let _ = stream
					.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
					.await;
			}
		});
		for status in [
			"301 Moved Permanently",
			"302 Found",
			"307 Temporary Redirect",
			"308 Permanent Redirect",
		] {
			let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
			let url = format!("http://{}", listener.local_addr().unwrap());
			let location = target_url.clone();
			let server = tokio::spawn(async move {
				let (mut stream, _) = listener.accept().await.unwrap();
				let mut headers = BufReader::new(&mut stream).lines();
				while let Some(line) = headers.next_line().await.unwrap() {
					if line.is_empty() {
						break;
					}
				}
				let response = format!(
					"HTTP/1.1 {}\r\nLocation: {}/v2/foreign\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
					status, location
				);
				stream.write_all(response.as_bytes()).await.unwrap();
			});
			let res = client
				.post_async::<_, serde_json::Value>(&url, &serde_json::json!({"a": 1}), None)
				.await;
			assert_eq!(
				res,
				Err(Error::ResponseError(format!("HTTP {}", status))),
				"{}",
				status
			);
			server.await.unwrap();
		}
		assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 0);
	}
}
