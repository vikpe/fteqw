//! QW svc_* server-to-client message dispatch.
//!
//! Re-exports the common set from `qworld-demo::svc` since demos
//! replay the same byte stream. QW-only additions (`svc_updatestat`
//! float variant, etc.) layer here.

pub use qworld_core as core;

/// Decoded svc message. Most variants are stubs until the renderer
/// consumes them; we just need the *shape* to thread through the
/// netchan -> engine pipeline.
#[derive(Debug, Clone)]
pub enum SvcMessage {
    Nop,
    Disconnect,
    Print(String),
    CenterPrint(String),
    StuffText(String),
    ServerData {
        protocol: u32,
        servercount: u32,
        gamedir: String,
    },
    SetAngle {
        angles: [f32; 3],
    },
    Sound,         // payload elided
    SpawnBaseline, // payload elided
    UpdateEnts,    // payload elided
    Other(u8),     // unhandled code, kept for tracing
}
