//! Engine orchestration.
//!
//! Threads the subsystems together:
//! - Asset loading via `qworld-fs` (PAK/PK3) + format crates
//! - World rendering via `qworld-render`
//! - Local server for previews via `qworld-server`
//! - Demo playback via `qworld-demo`
//! - Live network play via `qworld-net`
//!
//! The CLI and web binaries are thin drivers over `Engine`.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("fs error: {0}")]
    Fs(#[from] qworld_fs::FsError),

    #[error("bsp error: {0}")]
    Bsp(#[from] qworld_bsp::BspError),

    #[error("server error: {0}")]
    Server(#[from] qworld_server::ServerError),

    #[error("render error: {0}")]
    Render(#[from] qworld_render::RenderError),
}

/// Public engine handle.
///
/// Holds an optional `LocalServer` (set after a successful
/// `load_map`). Renderer + network state TBD.
#[derive(Default)]
pub struct Engine {
    pub server: Option<qworld_server::LocalServer>,
}

impl Engine {
    #[must_use] 
    pub fn new() -> Self {
        Self::default()
    }

    /// Parse a BSP and spawn a local server on it. Sets
    /// `self.server` on success.
    pub fn load_map(&mut self, bsp_bytes: Vec<u8>) -> Result<(), EngineError> {
        let bsp = qworld_bsp::Bsp::from_bytes(bsp_bytes)?;
        let server = qworld_server::LocalServer::spawn_on_map(bsp)?;
        tracing::info!(
            "spawned on map; origin={:?} yaw={}",
            server.spawn_origin,
            server.spawn_yaw
        );
        self.server = Some(server);
        Ok(())
    }

    /// Camera position for the current spawn (None if no map loaded).
    #[must_use] 
    pub fn camera_origin(&self) -> Option<glam::Vec3> {
        self.server.as_ref().map(|s| s.spawn_origin)
    }

    /// Camera yaw for the current spawn (None if no map loaded).
    #[must_use] 
    pub fn camera_yaw(&self) -> Option<f32> {
        self.server.as_ref().map(|s| s.spawn_yaw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_bsp_with_entities(entities: &str) -> Vec<u8> {
        let mut entities_with_nul = entities.as_bytes().to_vec();
        entities_with_nul.push(0);

        let mut file = Vec::new();
        file.extend_from_slice(&qworld_bsp::BSP_VERSION_Q1.to_le_bytes());
        let dir_pos = file.len();
        file.extend(std::iter::repeat_n(0u8, qworld_bsp::Lump::COUNT * 8));

        // Append entities lump at end
        let off = file.len() as u32;
        let len = entities_with_nul.len() as u32;
        file.extend_from_slice(&entities_with_nul);

        // Patch lump 0 (Entities)
        let p = dir_pos;
        file[p..p + 4].copy_from_slice(&off.to_le_bytes());
        file[p + 4..p + 8].copy_from_slice(&len.to_le_bytes());
        file
    }

    #[test]
    fn load_map_spawns_server() {
        let bsp_bytes = fake_bsp_with_entities(
            r#"{ "classname" "info_player_deathmatch" "origin" "10 20 30" "angle" "45" }"#,
        );
        let mut engine = Engine::new();
        engine.load_map(bsp_bytes).unwrap();
        assert_eq!(engine.camera_origin(), Some(glam::Vec3::new(10.0, 20.0, 30.0)));
        assert_eq!(engine.camera_yaw(), Some(45.0));
    }

    #[test]
    fn load_map_fails_without_spawn() {
        let bsp_bytes = fake_bsp_with_entities(r#"{ "classname" "worldspawn" }"#);
        let mut engine = Engine::new();
        let err = engine.load_map(bsp_bytes).unwrap_err();
        assert!(matches!(err, EngineError::Server(_)));
    }
}
