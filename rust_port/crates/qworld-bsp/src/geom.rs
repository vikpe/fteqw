//! Geometry lump decoders: vertexes, edges, surfedges, faces.
//!
//! Q1 BSP face decoding: each face references a contiguous range in
//! the surfedges lump. Each surfedge is a signed index into the
//! edges lump (negative means "use edge with vertices swapped").
//! Each edge is a pair of vertex indices.
//!
//! V29 stores edge/face indices as 16-bit; BSP2 widens them to 32-bit
//! so larger maps fit. In-memory types are always BSP2-shaped (u32);
//! V29 widens on read.

use byteorder::{LittleEndian, ReadBytesExt};
use glam::Vec3;
use std::io::{Cursor, Read};

use crate::{Bsp, BspError, BspVersion, Lump};

/// Per-edge size in bytes for the V29 format (two u16s).
const EDGE_BYTES_V29: usize = 4;
/// Per-edge size in bytes for the BSP2 format (two u32s).
const EDGE_BYTES_BSP2: usize = 8;
/// Per-face size in bytes for V29.
const FACE_BYTES_V29: usize = 20;
/// Per-face size in bytes for BSP2.
const FACE_BYTES_BSP2: usize = 28;

/// Decode the Vertexes lump: array of 3 f32 (xyz) per vertex.
/// Identical layout in V29 and BSP2.
pub fn decode_vertexes(bsp: &Bsp) -> Result<Vec<Vec3>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Vertexes);
    if !bytes.len().is_multiple_of(12) {
        return Err(BspError::EntityParse(format!(
            "vertex lump size {} not divisible by 12",
            bytes.len()
        )));
    }
    let count = bytes.len() / 12;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let x = cur.read_f32::<LittleEndian>()?;
        let y = cur.read_f32::<LittleEndian>()?;
        let z = cur.read_f32::<LittleEndian>()?;
        out.push(Vec3::new(x, y, z));
    }
    Ok(out)
}

/// An edge connects two vertex indices. Always stored as u32 in
/// memory; V29 widens from u16 on read.
#[derive(Debug, Clone, Copy)]
pub struct Edge(pub u32, pub u32);

pub fn decode_edges(bsp: &Bsp) -> Result<Vec<Edge>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Edges);
    match bsp.version() {
        BspVersion::V29 => decode_edges_with(bytes, EDGE_BYTES_V29, |cur| {
            let v0 = u32::from(cur.read_u16::<LittleEndian>()?);
            let v1 = u32::from(cur.read_u16::<LittleEndian>()?);
            Ok(Edge(v0, v1))
        }),
        BspVersion::Bsp2 => decode_edges_with(bytes, EDGE_BYTES_BSP2, |cur| {
            let v0 = cur.read_u32::<LittleEndian>()?;
            let v1 = cur.read_u32::<LittleEndian>()?;
            Ok(Edge(v0, v1))
        }),
    }
}

fn decode_edges_with(
    bytes: &[u8],
    record_size: usize,
    mut read_one: impl FnMut(&mut Cursor<&[u8]>) -> Result<Edge, BspError>,
) -> Result<Vec<Edge>, BspError> {
    if !bytes.len().is_multiple_of(record_size) {
        return Err(BspError::EntityParse(format!(
            "edge lump size {} not divisible by {record_size}",
            bytes.len()
        )));
    }
    let count = bytes.len() / record_size;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        out.push(read_one(&mut cur)?);
    }
    Ok(out)
}

/// Signed edge index into the Edges lump. Same width (i32) in both
/// versions.
pub fn decode_surfedges(bsp: &Bsp) -> Result<Vec<i32>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Surfedges);
    if !bytes.len().is_multiple_of(4) {
        return Err(BspError::EntityParse(format!(
            "surfedge lump size {} not divisible by 4",
            bytes.len()
        )));
    }
    let count = bytes.len() / 4;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        out.push(cur.read_i32::<LittleEndian>()?);
    }
    Ok(out)
}

/// A face is a (planar) polygon referenced by a contiguous slice of
/// surfedges. Always stored as the BSP2 (32-bit) shape in memory;
/// V29 widens its u16 fields on read.
#[derive(Debug, Clone)]
pub struct Face {
    pub plane: u32,
    pub side: u32,
    pub first_edge: i32,
    pub num_edges: u32,
    pub texinfo: u32,
    pub styles: [u8; 4],
    pub lightofs: i32,
}

pub fn decode_faces(bsp: &Bsp) -> Result<Vec<Face>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Faces);
    match bsp.version() {
        BspVersion::V29 => decode_faces_with(bytes, FACE_BYTES_V29, |cur| {
            let plane = u32::from(cur.read_u16::<LittleEndian>()?);
            let side = u32::from(cur.read_u16::<LittleEndian>()?);
            let first_edge = cur.read_i32::<LittleEndian>()?;
            let num_edges = u32::from(cur.read_u16::<LittleEndian>()?);
            let texinfo = u32::from(cur.read_u16::<LittleEndian>()?);
            let mut styles = [0u8; 4];
            cur.read_exact(&mut styles)?;
            let lightofs = cur.read_i32::<LittleEndian>()?;
            Ok(Face { plane, side, first_edge, num_edges, texinfo, styles, lightofs })
        }),
        BspVersion::Bsp2 => decode_faces_with(bytes, FACE_BYTES_BSP2, |cur| {
            let plane = cur.read_u32::<LittleEndian>()?;
            let side = cur.read_u32::<LittleEndian>()?;
            let first_edge = cur.read_i32::<LittleEndian>()?;
            let num_edges = cur.read_u32::<LittleEndian>()?;
            let texinfo = cur.read_u32::<LittleEndian>()?;
            let mut styles = [0u8; 4];
            cur.read_exact(&mut styles)?;
            let lightofs = cur.read_i32::<LittleEndian>()?;
            Ok(Face { plane, side, first_edge, num_edges, texinfo, styles, lightofs })
        }),
    }
}

fn decode_faces_with(
    bytes: &[u8],
    record_size: usize,
    mut read_one: impl FnMut(&mut Cursor<&[u8]>) -> Result<Face, BspError>,
) -> Result<Vec<Face>, BspError> {
    if !bytes.len().is_multiple_of(record_size) {
        return Err(BspError::EntityParse(format!(
            "face lump size {} not divisible by {record_size}",
            bytes.len()
        )));
    }
    let count = bytes.len() / record_size;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        out.push(read_one(&mut cur)?);
    }
    Ok(out)
}

/// Resolve one face into a list of vertex *positions* (a fan
/// polygon). The renderer can triangulate as needed.
#[must_use]
pub fn face_vertices(
    face: &Face,
    surfedges: &[i32],
    edges: &[Edge],
    vertexes: &[Vec3],
) -> Vec<Vec3> {
    let mut out = Vec::with_capacity(face.num_edges as usize);
    let start = face.first_edge as usize;
    let end = start + face.num_edges as usize;
    for &se in &surfedges[start..end] {
        let edge_idx = se.unsigned_abs() as usize;
        if edge_idx >= edges.len() {
            continue;
        }
        let edge = edges[edge_idx];
        // Negative surfedge means use vertex 1 first.
        let v = if se >= 0 { edge.0 } else { edge.1 };
        if let Some(pos) = vertexes.get(v as usize) {
            out.push(*pos);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::{BSP_MAGIC_BSP2, BSP_MAGIC_V29, NUM_LUMPS};

    /// Build a quad-shaped BSP using the given format. Allows the
    /// edge + face bytes to be supplied externally so V29 and BSP2
    /// fixtures share the same outer framing.
    fn make_quad_bsp(magic: u32, edges_bytes: &[u8], face_bytes: &[u8]) -> Bsp {
        let vertexes: [[f32; 3]; 4] =
            [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]];
        let surfedges: [i32; 4] = [0, 1, 2, 3];

        let mut verts_bytes = Vec::new();
        for v in &vertexes {
            for c in v {
                verts_bytes.extend_from_slice(&c.to_le_bytes());
            }
        }
        let mut surfedge_bytes = Vec::new();
        for s in &surfedges {
            surfedge_bytes.extend_from_slice(&s.to_le_bytes());
        }

        let mut file = Vec::new();
        file.extend_from_slice(&magic.to_le_bytes());
        let dir_pos = file.len();
        file.extend(std::iter::repeat_n(0u8, NUM_LUMPS * 8));

        let mut offsets = [(0u32, 0u32); NUM_LUMPS];
        let put = |file: &mut Vec<u8>, data: &[u8]| -> (u32, u32) {
            let off = file.len() as u32;
            file.extend_from_slice(data);
            (off, data.len() as u32)
        };
        offsets[Lump::Entities as usize] = put(&mut file, b"");
        offsets[Lump::Vertexes as usize] = put(&mut file, &verts_bytes);
        offsets[Lump::Edges as usize] = put(&mut file, edges_bytes);
        offsets[Lump::Surfedges as usize] = put(&mut file, &surfedge_bytes);
        offsets[Lump::Faces as usize] = put(&mut file, face_bytes);

        for (i, (off, len)) in offsets.iter().enumerate() {
            let p = dir_pos + i * 8;
            file[p..p + 4].copy_from_slice(&off.to_le_bytes());
            file[p + 4..p + 8].copy_from_slice(&len.to_le_bytes());
        }
        Bsp::from_bytes(file).unwrap()
    }

    fn v29_edge_bytes(pairs: &[(u16, u16)]) -> Vec<u8> {
        let mut out = Vec::new();
        for e in pairs {
            out.extend_from_slice(&e.0.to_le_bytes());
            out.extend_from_slice(&e.1.to_le_bytes());
        }
        out
    }

    fn bsp2_edge_bytes(pairs: &[(u32, u32)]) -> Vec<u8> {
        let mut out = Vec::new();
        for e in pairs {
            out.extend_from_slice(&e.0.to_le_bytes());
            out.extend_from_slice(&e.1.to_le_bytes());
        }
        out
    }

    fn v29_face_bytes(
        plane: u16,
        side: u16,
        first_edge: i32,
        num_edges: u16,
        texinfo: u16,
    ) -> Vec<u8> {
        let mut b = Vec::with_capacity(FACE_BYTES_V29);
        b.extend_from_slice(&plane.to_le_bytes());
        b.extend_from_slice(&side.to_le_bytes());
        b.extend_from_slice(&first_edge.to_le_bytes());
        b.extend_from_slice(&num_edges.to_le_bytes());
        b.extend_from_slice(&texinfo.to_le_bytes());
        b.extend_from_slice(&[0u8; 4]);
        b.extend_from_slice(&(-1i32).to_le_bytes()); // lightofs = -1 (no lightmap)
        b
    }

    fn bsp2_face_bytes(
        plane: u32,
        side: u32,
        first_edge: i32,
        num_edges: u32,
        texinfo: u32,
    ) -> Vec<u8> {
        let mut b = Vec::with_capacity(FACE_BYTES_BSP2);
        b.extend_from_slice(&plane.to_le_bytes());
        b.extend_from_slice(&side.to_le_bytes());
        b.extend_from_slice(&first_edge.to_le_bytes());
        b.extend_from_slice(&num_edges.to_le_bytes());
        b.extend_from_slice(&texinfo.to_le_bytes());
        b.extend_from_slice(&[0u8; 4]);
        b.extend_from_slice(&(-1i32).to_le_bytes());
        b
    }

    #[test]
    fn decodes_v29_quad_geometry() {
        let edges = v29_edge_bytes(&[(0, 1), (1, 2), (2, 3), (3, 0)]);
        let face = v29_face_bytes(0, 0, 0, 4, 0);
        let bsp = make_quad_bsp(BSP_MAGIC_V29, &edges, &face);
        assert_eq!(bsp.version(), BspVersion::V29);

        let verts = decode_vertexes(&bsp).unwrap();
        let edges = decode_edges(&bsp).unwrap();
        let surfedges = decode_surfedges(&bsp).unwrap();
        let faces = decode_faces(&bsp).unwrap();
        assert_eq!(edges.len(), 4);
        assert_eq!(faces.len(), 1);
        assert_eq!(faces[0].num_edges, 4);

        let face_vs = face_vertices(&faces[0], &surfedges, &edges, &verts);
        assert_eq!(face_vs.len(), 4);
        assert_eq!(face_vs[0], Vec3::new(0.0, 0.0, 0.0));
        assert_eq!(face_vs[3], Vec3::new(0.0, 1.0, 0.0));
    }

    #[test]
    fn decodes_bsp2_quad_geometry() {
        let edges = bsp2_edge_bytes(&[(0, 1), (1, 2), (2, 3), (3, 0)]);
        let face = bsp2_face_bytes(0, 0, 0, 4, 0);
        let bsp = make_quad_bsp(BSP_MAGIC_BSP2, &edges, &face);
        assert_eq!(bsp.version(), BspVersion::Bsp2);

        let verts = decode_vertexes(&bsp).unwrap();
        let edges = decode_edges(&bsp).unwrap();
        let surfedges = decode_surfedges(&bsp).unwrap();
        let faces = decode_faces(&bsp).unwrap();
        assert_eq!(edges.len(), 4);
        assert_eq!(faces.len(), 1);
        assert_eq!(faces[0].num_edges, 4);

        let face_vs = face_vertices(&faces[0], &surfedges, &edges, &verts);
        assert_eq!(face_vs.len(), 4);
        assert_eq!(face_vs[0], Vec3::new(0.0, 0.0, 0.0));
        assert_eq!(face_vs[3], Vec3::new(0.0, 1.0, 0.0));
    }

    #[test]
    fn bsp2_widens_high_indices() {
        // High vertex indices (> u16::MAX) should round-trip through
        // the BSP2 decoder without truncation.
        let high_a: u32 = 70_000;
        let high_b: u32 = 65_536;
        // Edge index 0 references high_a/high_b; the actual vertex
        // lookup will fail since our vertex array only has 4 entries,
        // and face_vertices skips out-of-range vertices. We just
        // verify the decode preserved the high values.
        let edges = bsp2_edge_bytes(&[(high_a, high_b)]);
        let face = bsp2_face_bytes(0, 0, 0, 1, 0);
        let bsp = make_quad_bsp(BSP_MAGIC_BSP2, &edges, &face);
        let decoded = decode_edges(&bsp).unwrap();
        assert_eq!(decoded[0].0, high_a);
        assert_eq!(decoded[0].1, high_b);
    }
}
