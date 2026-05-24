//! In-process Quake server.
//!
//! Used for the local map-preview / screenshot use cases. The
//! server:
//! 1. Loads a BSP.
//! 2. Spawns the world entity + finds an `info_player_start` (or
//!    deathmatch variant) for the camera placement.
//! 3. Accepts a loopback "client" connection.
//! 4. Runs physics + sends entity updates each frame.
//!
//! Without QC (intentionally skipped — see README), spawning is done
//! natively: we read the entity string from the BSP and place the
//! camera at the first `info_player_*`. No monsters, no items, no
//! gameplay — just a viewable world.

use glam::Vec3;
use qworld_bsp::{entity::EntityBlock, Bsp};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("bsp error: {0}")]
    Bsp(#[from] qworld_bsp::BspError),

    #[error("no info_player_start (or deathmatch variant) found")]
    NoSpawnPoint,
}

pub struct LocalServer {
    pub bsp: Bsp,
    pub spawn_origin: Vec3,
    pub spawn_yaw: f32,
    pub entities: Vec<EntityBlock>,
}

impl LocalServer {
    pub fn spawn_on_map(bsp: Bsp) -> Result<Self, ServerError> {
        let entities_str = bsp.entities_str()?.to_string();
        let entities = qworld_bsp::entity::parse_entities(&entities_str)?;
        let (spawn_origin, spawn_yaw) = pick_spawn(&entities).ok_or(ServerError::NoSpawnPoint)?;
        Ok(Self {
            bsp,
            spawn_origin,
            spawn_yaw,
            entities,
        })
    }
}

fn pick_spawn(entities: &[EntityBlock]) -> Option<(Vec3, f32)> {
    const PREFER: &[&str] = &[
        "info_player_deathmatch",
        "info_player_start",
        "info_player_coop",
    ];
    for want in PREFER {
        for e in entities {
            if e.classname() == Some(want)
                && let Some([x, y, z]) = e.origin()
            {
                return Some((Vec3::new(x, y, z), e.angle().unwrap_or(0.0)));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use qworld_bsp::entity::parse_entities;

    #[test]
    fn picks_deathmatch_spawn_over_singleplayer() {
        let src = r#"
        { "classname" "info_player_start" "origin" "0 0 0" "angle" "0" }
        { "classname" "info_player_deathmatch" "origin" "100 200 50" "angle" "90" }
        "#;
        let ents = parse_entities(src).unwrap();
        let (origin, yaw) = pick_spawn(&ents).unwrap();
        assert_eq!(origin, Vec3::new(100.0, 200.0, 50.0));
        assert_eq!(yaw, 90.0);
    }

    #[test]
    fn falls_back_to_singleplayer() {
        let src = r#"{ "classname" "info_player_start" "origin" "5 6 7" }"#;
        let ents = parse_entities(src).unwrap();
        let (origin, yaw) = pick_spawn(&ents).unwrap();
        assert_eq!(origin, Vec3::new(5.0, 6.0, 7.0));
        assert_eq!(yaw, 0.0);
    }

    #[test]
    fn returns_none_when_empty() {
        assert!(pick_spawn(&[]).is_none());
    }
}
