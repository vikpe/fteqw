//! `QuakeWorld` and `NetQuake` network protocols.
//!
//! Layers (bottom-up):
//! 1. **Transport** — UDP on native; WebSocket-to-UDP relay on web.
//! 2. **Netchan** — reliable/unreliable channel multiplexing.
//! 3. **Connectionless** — out-of-band setup packets (challenge,
//!    connect, getinfo).
//! 4. **Game messages** — `svc_*` / `clc_*` typed messages from/to
//!    the connected server.
//!
//! This crate provides the protocol *codec*; socket I/O lives in
//! `qworld-engine` (driven by native `std::net` or web wasm-bindgen).

pub mod netchan;
pub mod protocol;
pub mod svc;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum NetError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("binrw error: {0}")]
    BinRw(#[from] binrw::Error),

    #[error("malformed packet: {0}")]
    Malformed(String),

    #[error("unknown svc code: {0}")]
    UnknownSvc(u8),
}
