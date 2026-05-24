//! wasm-bindgen surface for slipgate to drive the engine from JS.
//!
//! The JS side (slipgate's `apps/website/...`) loads this wasm and
//! calls into the exported functions to: load a map, play a demo,
//! capture a screenshot, etc.
//!
//! This mirrors the role of FTE's `engine/web/ftejslib.js` glue
//! (~58 APIs there) — but slimmer, since we only need what slipgate
//! actually calls.
//!
//! Status: surface stubs only. Real wiring waits until the engine
//! orchestrator can render a frame.

use wasm_bindgen::prelude::*;

#[wasm_bindgen(start)]
pub fn init() {
    console_error_panic_hook::set_once();
    tracing_wasm::set_as_global_default();
    tracing::info!("qworld-web initialized");
}

/// Opaque handle to an Engine instance.
#[wasm_bindgen]
pub struct Engine {
    _inner: qworld_engine::Engine,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

#[wasm_bindgen]
impl Engine {
    #[wasm_bindgen(constructor)]
    #[must_use] 
    pub fn new() -> Self {
        Self {
            _inner: qworld_engine::Engine::new(),
        }
    }

    /// Load a map from BSP bytes (slipgate fetches the file and
    /// hands the `Uint8Array` in).
    pub fn load_map(&mut self, _bsp_bytes: Vec<u8>) -> Result<(), JsError> {
        Err(JsError::new("not yet implemented"))
    }

    /// Set the camera angle (pitch, yaw, roll in degrees).
    pub fn set_angle(&mut self, _pitch: f32, _yaw: f32, _roll: f32) {
        // TODO
    }

    /// Capture a single frame as RGBA8 bytes. Slipgate converts to
    /// a PNG client-side via canvas, or uploads for video assembly.
    pub fn screenshot(&mut self, _width: u32, _height: u32) -> Result<Vec<u8>, JsError> {
        Err(JsError::new("not yet implemented"))
    }
}
