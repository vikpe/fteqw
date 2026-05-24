//! Entity-string parser.
//!
//! The Entities lump is a text blob containing one or more entity
//! blocks like:
//! ```text
//! {
//! "classname" "worldspawn"
//! "wad" "gfx/base.wad"
//! }
//! {
//! "classname" "info_player_start"
//! "origin" "480 -352 88"
//! "angle" "90"
//! }
//! ```
//!
//! We need this for the local-server use case: find
//! `info_player_start` / `info_player_deathmatch` to know where to
//! spawn the preview camera.

use std::collections::HashMap;

use crate::BspError;

#[derive(Debug, Clone, Default)]
pub struct EntityBlock {
    pub kv: HashMap<String, String>,
}

impl EntityBlock {
    #[must_use] 
    pub fn classname(&self) -> Option<&str> {
        self.kv.get("classname").map(std::string::String::as_str)
    }

    /// Parse "x y z" into 3 floats (Quake convention: x y z).
    #[must_use] 
    pub fn origin(&self) -> Option<[f32; 3]> {
        let s = self.kv.get("origin")?;
        let mut parts = s.split_whitespace();
        Some([
            parts.next()?.parse().ok()?,
            parts.next()?.parse().ok()?,
            parts.next()?.parse().ok()?,
        ])
    }

    /// "angle" is yaw degrees. -1/-2 are up/down in vanilla Quake.
    #[must_use] 
    pub fn angle(&self) -> Option<f32> {
        self.kv.get("angle")?.parse().ok()
    }
}

pub fn parse_entities(src: &str) -> Result<Vec<EntityBlock>, BspError> {
    let mut blocks = Vec::new();
    let mut chars = src.chars().peekable();
    loop {
        skip_ws(&mut chars);
        match chars.peek() {
            None => break,
            Some('{') => {
                chars.next();
                let block = parse_block(&mut chars)?;
                blocks.push(block);
            }
            Some(c) => {
                return Err(BspError::EntityParse(format!("expected '{{', got {c:?}")));
            }
        }
    }
    Ok(blocks)
}

fn parse_block<I>(chars: &mut std::iter::Peekable<I>) -> Result<EntityBlock, BspError>
where
    I: Iterator<Item = char>,
{
    let mut block = EntityBlock::default();
    loop {
        skip_ws(chars);
        match chars.peek() {
            Some('}') => {
                chars.next();
                return Ok(block);
            }
            Some('"') => {
                let key = parse_string(chars)?;
                skip_ws(chars);
                let value = parse_string(chars)?;
                block.kv.insert(key, value);
            }
            Some(c) => {
                return Err(BspError::EntityParse(format!(
                    "unexpected char in block: {c:?}"
                )));
            }
            None => return Err(BspError::EntityParse("unexpected eof in block".into())),
        }
    }
}

fn parse_string<I>(chars: &mut std::iter::Peekable<I>) -> Result<String, BspError>
where
    I: Iterator<Item = char>,
{
    if chars.next() != Some('"') {
        return Err(BspError::EntityParse("expected opening quote".into()));
    }
    let mut s = String::new();
    for c in chars.by_ref() {
        if c == '"' {
            return Ok(s);
        }
        s.push(c);
    }
    Err(BspError::EntityParse("unterminated string".into()))
}

fn skip_ws<I: Iterator<Item = char>>(chars: &mut std::iter::Peekable<I>) {
    while matches!(chars.peek(), Some(c) if c.is_whitespace()) {
        chars.next();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_block() {
        let src = r#"
        {
        "classname" "worldspawn"
        "wad" "gfx/base.wad"
        }
        {
        "classname" "info_player_start"
        "origin" "480 -352 88"
        "angle" "90"
        }
        "#;
        let blocks = parse_entities(src).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].classname(), Some("worldspawn"));
        assert_eq!(blocks[1].classname(), Some("info_player_start"));
        assert_eq!(blocks[1].origin(), Some([480.0, -352.0, 88.0]));
        assert_eq!(blocks[1].angle(), Some(90.0));
    }

    #[test]
    fn errors_on_unterminated_string() {
        let src = r#"{ "classname" "worldspawn"#;
        assert!(parse_entities(src).is_err());
    }
}
