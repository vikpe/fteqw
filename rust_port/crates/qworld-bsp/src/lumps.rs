//! BSP lump indices.

/// Lump index in the BSP directory. Each lump has a specific
/// data type — see id Software's BSP spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(usize)]
pub enum Lump {
    Entities = 0,
    Planes = 1,
    Textures = 2,
    Vertexes = 3,
    Visibility = 4,
    Nodes = 5,
    Texinfo = 6,
    Faces = 7,
    Lighting = 8,
    Clipnodes = 9,
    Leafs = 10,
    Marksurfaces = 11,
    Edges = 12,
    Surfedges = 13,
    Models = 14,
}

impl Lump {
    pub const COUNT: usize = 15;

    pub const ALL: [Lump; Self::COUNT] = [
        Lump::Entities,
        Lump::Planes,
        Lump::Textures,
        Lump::Vertexes,
        Lump::Visibility,
        Lump::Nodes,
        Lump::Texinfo,
        Lump::Faces,
        Lump::Lighting,
        Lump::Clipnodes,
        Lump::Leafs,
        Lump::Marksurfaces,
        Lump::Edges,
        Lump::Surfedges,
        Lump::Models,
    ];
}
