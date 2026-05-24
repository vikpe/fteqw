//! Shared types and primitives used across all qworld crates.
//!
//! Kept dependency-free except for `glam` (vectors/matrices) and
//! `thiserror` (error types).

pub use glam::{Mat4, Vec2, Vec3, Vec4};

pub mod color;
pub mod ids;

/// A Quake "world unit". 1 unit = 1 inch in id1 maps.
pub type WorldUnit = f32;

/// 3D position in world space.
pub type WorldPos = Vec3;

/// Euler angles: pitch, yaw, roll (degrees, Quake convention).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Angles {
    pub pitch: f32,
    pub yaw: f32,
    pub roll: f32,
}

impl Angles {
    pub const ZERO: Self = Self {
        pitch: 0.0,
        yaw: 0.0,
        roll: 0.0,
    };

    #[must_use] 
    pub fn new(pitch: f32, yaw: f32, roll: f32) -> Self {
        Self { pitch, yaw, roll }
    }
}

/// Axis-aligned bounding box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bbox {
    pub min: Vec3,
    pub max: Vec3,
}

impl Bbox {
    #[must_use] 
    pub fn new(min: Vec3, max: Vec3) -> Self {
        Self { min, max }
    }

    #[must_use] 
    pub fn size(&self) -> Vec3 {
        self.max - self.min
    }

    #[must_use] 
    pub fn center(&self) -> Vec3 {
        (self.min + self.max) * 0.5
    }
}
