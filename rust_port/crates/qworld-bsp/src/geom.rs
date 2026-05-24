//! Geometry lump decoders: vertexes, edges, surfedges, faces.
//!
//! Q1 BSP face decoding: each face references a contiguous range in
//! the surfedges lump. Each surfedge is a signed index into the
//! edges lump (negative means "use edge with vertices swapped").
//! Each edge is a pair of vertex indices.
//!
//! The renderer wants an indexed triangle list per face; this module
//! provides that conversion.

use byteorder::{LittleEndian, ReadBytesExt};
use glam::Vec3;
use std::io::{Cursor, Read};

use crate::{Bsp, BspError, Lump};

/// Decode the Vertexes lump: array of 3 f32 (xyz) per vertex.
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

/// An edge connects two vertices (by index).
#[derive(Debug, Clone, Copy)]
pub struct Edge(pub u16, pub u16);

pub fn decode_edges(bsp: &Bsp) -> Result<Vec<Edge>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Edges);
    if !bytes.len().is_multiple_of(4) {
        return Err(BspError::EntityParse(format!(
            "edge lump size {} not divisible by 4",
            bytes.len()
        )));
    }
    let count = bytes.len() / 4;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let a = cur.read_u16::<LittleEndian>()?;
        let b = cur.read_u16::<LittleEndian>()?;
        out.push(Edge(a, b));
    }
    Ok(out)
}

/// Signed edge index into the Edges lump.
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
/// surfedges. We expose just the fields the renderer needs.
#[derive(Debug, Clone)]
pub struct Face {
    pub plane: u16,
    pub side: u16,
    pub first_edge: i32,
    pub num_edges: u16,
    pub texinfo: u16,
    pub styles: [u8; 4],
    pub lightofs: i32,
}

pub fn decode_faces(bsp: &Bsp) -> Result<Vec<Face>, BspError> {
    let bytes = bsp.lump_bytes(Lump::Faces);
    let face_size = 20;
    if !bytes.len().is_multiple_of(face_size) {
        return Err(BspError::EntityParse(format!(
            "face lump size {} not divisible by {face_size}",
            bytes.len()
        )));
    }
    let count = bytes.len() / face_size;
    let mut cur = Cursor::new(bytes);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let plane = cur.read_u16::<LittleEndian>()?;
        let side = cur.read_u16::<LittleEndian>()?;
        let first_edge = cur.read_i32::<LittleEndian>()?;
        let num_edges = cur.read_u16::<LittleEndian>()?;
        let texinfo = cur.read_u16::<LittleEndian>()?;
        let mut styles = [0u8; 4];
        cur.read_exact(&mut styles)?;
        let lightofs = cur.read_i32::<LittleEndian>()?;
        out.push(Face {
            plane,
            side,
            first_edge,
            num_edges,
            texinfo,
            styles,
            lightofs,
        });
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

    /// Build a tiny BSP with 4 vertices, 4 edges, 4 surfedges, 1 face.
    fn make_quad_bsp() -> Bsp {
        let vertexes: [[f32; 3]; 4] =
            [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]];
        let edges: [(u16, u16); 4] = [(0, 1), (1, 2), (2, 3), (3, 0)];
        let surfedges: [i32; 4] = [0, 1, 2, 3];
        let face_bytes: Vec<u8> = {
            let mut b = Vec::new();
            b.extend_from_slice(&0u16.to_le_bytes()); // plane
            b.extend_from_slice(&0u16.to_le_bytes()); // side
            b.extend_from_slice(&0i32.to_le_bytes()); // first_edge
            b.extend_from_slice(&4u16.to_le_bytes()); // num_edges
            b.extend_from_slice(&0u16.to_le_bytes()); // texinfo
            b.extend_from_slice(&[0u8; 4]);           // styles
            b.extend_from_slice(&(-1i32).to_le_bytes()); // lightofs
            b
        };

        // Build the lump-bytes buffers
        let mut verts_bytes = Vec::new();
        for v in &vertexes {
            for c in v {
                verts_bytes.extend_from_slice(&c.to_le_bytes());
            }
        }
        let mut edges_bytes = Vec::new();
        for e in &edges {
            edges_bytes.extend_from_slice(&e.0.to_le_bytes());
            edges_bytes.extend_from_slice(&e.1.to_le_bytes());
        }
        let mut surfedge_bytes = Vec::new();
        for s in &surfedges {
            surfedge_bytes.extend_from_slice(&s.to_le_bytes());
        }

        // Lay out file: header then each lump.
        let mut file = Vec::new();
        file.extend_from_slice(&crate::header::BSP_VERSION_Q1.to_le_bytes());
        // Reserve lump dir
        let dir_pos = file.len();
        file.extend(std::iter::repeat_n(0u8, crate::header::NUM_LUMPS * 8));

        // Append lumps and record offsets
        let mut offsets = [(0u32, 0u32); crate::header::NUM_LUMPS];
        let put = |file: &mut Vec<u8>, data: &[u8]| -> (u32, u32) {
            let off = file.len() as u32;
            file.extend_from_slice(data);
            (off, data.len() as u32)
        };
        offsets[Lump::Entities as usize] = put(&mut file, b"");
        offsets[Lump::Vertexes as usize] = put(&mut file, &verts_bytes);
        offsets[Lump::Edges as usize] = put(&mut file, &edges_bytes);
        offsets[Lump::Surfedges as usize] = put(&mut file, &surfedge_bytes);
        offsets[Lump::Faces as usize] = put(&mut file, &face_bytes);

        // Patch dir
        for (i, (off, len)) in offsets.iter().enumerate() {
            let p = dir_pos + i * 8;
            file[p..p + 4].copy_from_slice(&off.to_le_bytes());
            file[p + 4..p + 8].copy_from_slice(&len.to_le_bytes());
        }
        Bsp::from_bytes(file).unwrap()
    }

    #[test]
    fn decodes_quad_geometry() {
        let bsp = make_quad_bsp();
        let verts = decode_vertexes(&bsp).unwrap();
        let edges = decode_edges(&bsp).unwrap();
        let surfedges = decode_surfedges(&bsp).unwrap();
        let faces = decode_faces(&bsp).unwrap();
        assert_eq!(verts.len(), 4);
        assert_eq!(edges.len(), 4);
        assert_eq!(surfedges.len(), 4);
        assert_eq!(faces.len(), 1);

        let face_vs = face_vertices(&faces[0], &surfedges, &edges, &verts);
        assert_eq!(face_vs.len(), 4);
        assert_eq!(face_vs[0], Vec3::new(0.0, 0.0, 0.0));
        assert_eq!(face_vs[1], Vec3::new(1.0, 0.0, 0.0));
        assert_eq!(face_vs[2], Vec3::new(1.0, 1.0, 0.0));
        assert_eq!(face_vs[3], Vec3::new(0.0, 1.0, 0.0));
    }
}
