//! Q3-style shader/material script parser.
//!
//! FTE inherits Q3's text-based material system: `.shader` files in
//! `scripts/` define multi-pass materials with stages, blends,
//! `tcMod`/`tcGen`/`rgbGen`/`alphaFunc`/etc. directives.
//!
//! Used by modern QW content packs and KTX-style server-defined
//! materials. Reference: parent repo's `specs/example.shader`.
//!
//! Stub — full parser is a non-trivial week of work. We sketch the
//! data model so downstream code can compile against it.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ShaderError {
    #[error("parse error: {0}")]
    Parse(String),
}

#[derive(Debug, Clone, Default)]
pub struct Shader {
    pub name: String,
    pub stages: Vec<ShaderStage>,
    pub cull: CullMode,
    pub nopicmip: bool,
    pub nomipmaps: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub enum CullMode {
    #[default]
    Front,
    Back,
    None,
}

#[derive(Debug, Clone, Default)]
pub struct ShaderStage {
    pub map: Option<String>,
    pub blend: Option<(BlendFactor, BlendFactor)>,
    pub alpha_func: Option<AlphaFunc>,
    pub tc_gen: Option<TcGen>,
    pub rgb_gen: Option<RgbGen>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BlendFactor {
    Zero,
    One,
    SrcColor,
    OneMinusSrcColor,
    SrcAlpha,
    OneMinusSrcAlpha,
    DstColor,
    OneMinusDstColor,
    DstAlpha,
    OneMinusDstAlpha,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AlphaFunc {
    Gt0,
    Lt128,
    Ge128,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TcGen {
    Base,
    Lightmap,
    Environment,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RgbGen {
    Identity,
    IdentityLighting,
    Vertex,
    ExactVertex,
    Wave,
}

pub fn parse(_src: &str) -> Result<Vec<Shader>, ShaderError> {
    todo!("Q3 shader parser")
}
