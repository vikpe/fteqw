//! MDL (IDPO version 6) alias-model loader.
//!
//! Layout:
//! - 84-byte header (magic, version, scale/origin, sizes, counts)
//! - Skin texture data (paletted, palette indices into Quake palette)
//! - Skin texture coords (per-vertex S/T)
//! - Triangle list (3 vertex indices + faces-front flag)
//! - Frame data (vertex positions for each animation frame)
//!
//! Initial scope: single-skin and single-frame models. Skin groups
//! (animated skins) and frame groups (grouped animations) are
//! returned as the first member only. Vanilla QW player/weapon
//! models all use single-frame layout.

use byteorder::{LittleEndian, ReadBytesExt};
use glam::{Vec2, Vec3};
use qworld_core::color::QuakePalette;
use std::io::{Cursor, Read};

use crate::ModelError;

pub const MDL_MAGIC: &[u8; 4] = b"IDPO";
pub const MDL_VERSION: u32 = 6;

/// `STVert::on_seam` is this bit when set.
pub const ALIAS_ONSEAM: u32 = 0x20;

#[derive(Debug, Clone)]
pub struct MdlHeader {
    pub scale: [f32; 3],
    pub origin: [f32; 3],
    pub bounding_radius: f32,
    pub eye_position: [f32; 3],
    pub num_skins: u32,
    pub skin_width: u32,
    pub skin_height: u32,
    pub num_vertices: u32,
    pub num_triangles: u32,
    pub num_frames: u32,
    pub synctype: u32,
    pub flags: u32,
    pub size: f32,
}

impl MdlHeader {
    pub fn parse(raw: &[u8]) -> Result<Self, ModelError> {
        let mut cur = Cursor::new(raw);
        let mut magic = [0u8; 4];
        cur.read_exact(&mut magic)?;
        if &magic != MDL_MAGIC {
            return Err(ModelError::InvalidMdlMagic(magic));
        }
        let version = cur.read_u32::<LittleEndian>()?;
        if version != MDL_VERSION {
            return Err(ModelError::UnsupportedMdlVersion(version));
        }
        let scale = [
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        ];
        let origin = [
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        ];
        let bounding_radius = cur.read_f32::<LittleEndian>()?;
        let eye_position = [
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
            cur.read_f32::<LittleEndian>()?,
        ];
        let num_skins = cur.read_u32::<LittleEndian>()?;
        let skin_width = cur.read_u32::<LittleEndian>()?;
        let skin_height = cur.read_u32::<LittleEndian>()?;
        let num_vertices = cur.read_u32::<LittleEndian>()?;
        let num_triangles = cur.read_u32::<LittleEndian>()?;
        let num_frames = cur.read_u32::<LittleEndian>()?;
        let synctype = cur.read_u32::<LittleEndian>()?;
        let flags = cur.read_u32::<LittleEndian>()?;
        let size = cur.read_f32::<LittleEndian>()?;

        Ok(Self {
            scale,
            origin,
            bounding_radius,
            eye_position,
            num_skins,
            skin_width,
            skin_height,
            num_vertices,
            num_triangles,
            num_frames,
            synctype,
            flags,
            size,
        })
    }
}

/// Paletted skin image. `indices.len() == width * height`.
#[derive(Debug, Clone)]
pub struct Skin {
    pub width: u32,
    pub height: u32,
    pub indices: Vec<u8>,
}

impl Skin {
    /// Convert paletted indices to a flat RGBA8 buffer (row-major,
    /// 4 bytes per pixel). All output pixels have alpha = 255;
    /// vanilla MDL skins do not use transparency.
    #[must_use]
    pub fn to_rgba(&self, palette: &QuakePalette) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.indices.len() * 4);
        for &index in &self.indices {
            let rgb = palette[index as usize];
            out.extend_from_slice(&[rgb[0], rgb[1], rgb[2], 255]);
        }
        out
    }
}

/// Per-vertex texture coordinate (S/T) plus seam flag for backfacing
/// triangles. Backfacing triangles wrap S by `skin_width / 2`.
#[derive(Debug, Clone, Copy)]
pub struct StVert {
    pub on_seam: bool,
    pub s: u32,
    pub t: u32,
}

impl StVert {
    /// Normalised UV. If `back_facing` and the vert is `on_seam`, add
    /// `skin_width / 2` to S before normalising.
    pub fn uv(&self, skin_width: u32, skin_height: u32, back_facing: bool) -> Vec2 {
        let s = if back_facing && self.on_seam {
            self.s + skin_width / 2
        } else {
            self.s
        };
        Vec2::new(
            (s as f32 + 0.5) / skin_width as f32,
            (self.t as f32 + 0.5) / skin_height as f32,
        )
    }
}

/// One triangle, indexing three entries in [`MdlBody::stverts`] /
/// [`Frame::verts`]. `faces_front == false` flips S-wrap behaviour
/// for the texture coords.
#[derive(Debug, Clone, Copy)]
pub struct Triangle {
    pub faces_front: bool,
    pub verts: [u32; 3],
}

/// Compressed vertex: per-axis u8 to be decompressed via
/// `header.scale` + `header.origin`, plus a normal index into the
/// builtin Quake normal table (256 entries; not modelled here yet).
#[derive(Debug, Clone, Copy)]
pub struct TriVertx {
    pub xyz: [u8; 3],
    pub normal_index: u8,
}

impl TriVertx {
    /// Decompress into a world-space position using a header's
    /// scale + origin.
    #[must_use]
    pub fn position(&self, scale: [f32; 3], origin: [f32; 3]) -> Vec3 {
        Vec3::new(
            f32::from(self.xyz[0]) * scale[0] + origin[0],
            f32::from(self.xyz[1]) * scale[1] + origin[1],
            f32::from(self.xyz[2]) * scale[2] + origin[2],
        )
    }
}

/// One animation frame. Names look like `"stand1"`, `"walk2"`, etc.
/// In id1 models, the trailing digit groups related frames.
#[derive(Debug, Clone)]
pub struct Frame {
    pub name: String,
    pub bbox_min: TriVertx,
    pub bbox_max: TriVertx,
    pub verts: Vec<TriVertx>,
}

/// A fully-decoded MDL.
#[derive(Debug, Clone)]
pub struct Mdl {
    pub header: MdlHeader,
    pub skins: Vec<Skin>,
    pub stverts: Vec<StVert>,
    pub triangles: Vec<Triangle>,
    pub frames: Vec<Frame>,
}

impl Mdl {
    pub fn from_bytes(raw: &[u8]) -> Result<Self, ModelError> {
        let header = MdlHeader::parse(raw)?;
        // Header is 0x54 = 84 bytes.
        let mut cur = Cursor::new(raw);
        cur.set_position(84);

        let skins = read_skins(&mut cur, &header)?;
        let stverts = read_stverts(&mut cur, header.num_vertices)?;
        let triangles = read_triangles(&mut cur, header.num_triangles)?;
        let frames = read_frames(&mut cur, &header)?;

        Ok(Self {
            header,
            skins,
            stverts,
            triangles,
            frames,
        })
    }
}

fn read_skins(cur: &mut Cursor<&[u8]>, header: &MdlHeader) -> Result<Vec<Skin>, ModelError> {
    let pixels_per_skin = (header.skin_width * header.skin_height) as usize;
    let mut out = Vec::with_capacity(header.num_skins as usize);
    for _ in 0..header.num_skins {
        let group = cur.read_u32::<LittleEndian>()?;
        if group == 0 {
            let mut indices = vec![0u8; pixels_per_skin];
            cur.read_exact(&mut indices)?;
            out.push(Skin {
                width: header.skin_width,
                height: header.skin_height,
                indices,
            });
        } else {
            // Animated skin group: u32 count, count×f32 intervals,
            // count× paletted images. We keep only the first image
            // and skip the rest.
            let count = cur.read_u32::<LittleEndian>()? as usize;
            // Skip intervals
            for _ in 0..count {
                let _ = cur.read_f32::<LittleEndian>()?;
            }
            let mut first = vec![0u8; pixels_per_skin];
            cur.read_exact(&mut first)?;
            out.push(Skin {
                width: header.skin_width,
                height: header.skin_height,
                indices: first,
            });
            // Skip the remaining count-1 images
            for _ in 1..count {
                let mut skip = vec![0u8; pixels_per_skin];
                cur.read_exact(&mut skip)?;
            }
        }
    }
    Ok(out)
}

fn read_stverts(cur: &mut Cursor<&[u8]>, count: u32) -> Result<Vec<StVert>, ModelError> {
    let mut out = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let on_seam_flag = cur.read_u32::<LittleEndian>()?;
        let s = cur.read_u32::<LittleEndian>()?;
        let t = cur.read_u32::<LittleEndian>()?;
        out.push(StVert {
            on_seam: on_seam_flag & ALIAS_ONSEAM != 0,
            s,
            t,
        });
    }
    Ok(out)
}

fn read_triangles(cur: &mut Cursor<&[u8]>, count: u32) -> Result<Vec<Triangle>, ModelError> {
    let mut out = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let faces_front = cur.read_u32::<LittleEndian>()? != 0;
        let verts = [
            cur.read_u32::<LittleEndian>()?,
            cur.read_u32::<LittleEndian>()?,
            cur.read_u32::<LittleEndian>()?,
        ];
        out.push(Triangle { faces_front, verts });
    }
    Ok(out)
}

fn read_trivertx(cur: &mut Cursor<&[u8]>) -> Result<TriVertx, ModelError> {
    let mut buf = [0u8; 4];
    cur.read_exact(&mut buf)?;
    Ok(TriVertx {
        xyz: [buf[0], buf[1], buf[2]],
        normal_index: buf[3],
    })
}

fn read_simple_frame(
    cur: &mut Cursor<&[u8]>,
    num_vertices: u32,
) -> Result<Frame, ModelError> {
    let bbox_min = read_trivertx(cur)?;
    let bbox_max = read_trivertx(cur)?;
    let mut name_buf = [0u8; 16];
    cur.read_exact(&mut name_buf)?;
    let name_end = name_buf.iter().position(|&b| b == 0).unwrap_or(16);
    let name = String::from_utf8_lossy(&name_buf[..name_end]).into_owned();
    let mut verts = Vec::with_capacity(num_vertices as usize);
    for _ in 0..num_vertices {
        verts.push(read_trivertx(cur)?);
    }
    Ok(Frame {
        name,
        bbox_min,
        bbox_max,
        verts,
    })
}

fn read_frames(cur: &mut Cursor<&[u8]>, header: &MdlHeader) -> Result<Vec<Frame>, ModelError> {
    let mut out = Vec::with_capacity(header.num_frames as usize);
    for _ in 0..header.num_frames {
        let kind = cur.read_u32::<LittleEndian>()?;
        if kind == 0 {
            out.push(read_simple_frame(cur, header.num_vertices)?);
        } else {
            // Frame group: count, group bbox (2 trivertx), count× f32
            // intervals, count× simple frames. We keep the first one
            // and skip the rest.
            let count = cur.read_u32::<LittleEndian>()? as usize;
            let _group_bbox_min = read_trivertx(cur)?;
            let _group_bbox_max = read_trivertx(cur)?;
            for _ in 0..count {
                let _ = cur.read_f32::<LittleEndian>()?;
            }
            let first = read_simple_frame(cur, header.num_vertices)?;
            out.push(first);
            for _ in 1..count {
                let _ = read_simple_frame(cur, header.num_vertices)?;
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build an MDL header for `num_vertices`/`num_triangles`/`num_frames`
    /// with scale=(1,1,1) origin=(0,0,0), skin 2x2, 1 skin.
    fn header_bytes(num_vertices: u32, num_triangles: u32, num_frames: u32) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(MDL_MAGIC);
        b.extend_from_slice(&MDL_VERSION.to_le_bytes());
        for _ in 0..3 {
            b.extend_from_slice(&1.0f32.to_le_bytes()); // scale
        }
        for _ in 0..3 {
            b.extend_from_slice(&0.0f32.to_le_bytes()); // origin
        }
        b.extend_from_slice(&8.0f32.to_le_bytes()); // bounding_radius
        for _ in 0..3 {
            b.extend_from_slice(&0.0f32.to_le_bytes()); // eye_position
        }
        let u32s: [u32; 9] = [
            1,             // num_skins
            2,             // skin_width
            2,             // skin_height
            num_vertices,
            num_triangles,
            num_frames,
            0,             // synctype
            0,             // flags
            0,             // (filler / unused-ish — actually 8 u32s + 1 f32 follow header above)
        ];
        for v in u32s {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&50.0f32.to_le_bytes()); // size
        b
    }

    fn pad_trivertx(xyz: [u8; 3], normal: u8) -> Vec<u8> {
        vec![xyz[0], xyz[1], xyz[2], normal]
    }

    #[test]
    fn parses_minimal_full_mdl() {
        let mut bytes = header_bytes(3, 1, 1);

        // 1 skin, single (group=0), 2*2 = 4 palette indices
        bytes.extend_from_slice(&0u32.to_le_bytes()); // group
        bytes.extend_from_slice(&[10, 20, 30, 40]);

        // 3 stverts: (on_seam, s, t)
        for (seam, s, t) in &[(0u32, 0u32, 0u32), (ALIAS_ONSEAM, 1, 0), (0, 0, 1)] {
            bytes.extend_from_slice(&seam.to_le_bytes());
            bytes.extend_from_slice(&s.to_le_bytes());
            bytes.extend_from_slice(&t.to_le_bytes());
        }

        // 1 triangle: faces_front=1, verts=[0,1,2]
        bytes.extend_from_slice(&1u32.to_le_bytes()); // faces_front
        for i in 0u32..3 {
            bytes.extend_from_slice(&i.to_le_bytes());
        }

        // 1 frame, single (type=0):
        //   bbox_min, bbox_max, 16-byte name, 3× trivertx
        bytes.extend_from_slice(&0u32.to_le_bytes()); // frame type
        bytes.extend(pad_trivertx([0, 0, 0], 5));     // bbox_min
        bytes.extend(pad_trivertx([10, 10, 10], 6)); // bbox_max
        let mut name = [0u8; 16];
        name[..5].copy_from_slice(b"stand");
        bytes.extend_from_slice(&name);
        bytes.extend(pad_trivertx([2, 4, 8], 0));
        bytes.extend(pad_trivertx([5, 6, 7], 1));
        bytes.extend(pad_trivertx([10, 20, 30], 2));

        let mdl = Mdl::from_bytes(&bytes).unwrap();
        assert_eq!(mdl.skins.len(), 1);
        assert_eq!(mdl.skins[0].width, 2);
        assert_eq!(mdl.skins[0].height, 2);
        assert_eq!(mdl.skins[0].indices, vec![10, 20, 30, 40]);

        assert_eq!(mdl.stverts.len(), 3);
        assert!(!mdl.stverts[0].on_seam);
        assert!(mdl.stverts[1].on_seam);
        assert_eq!(mdl.stverts[2].t, 1);

        assert_eq!(mdl.triangles.len(), 1);
        assert!(mdl.triangles[0].faces_front);
        assert_eq!(mdl.triangles[0].verts, [0, 1, 2]);

        assert_eq!(mdl.frames.len(), 1);
        assert_eq!(mdl.frames[0].name, "stand");
        assert_eq!(mdl.frames[0].verts.len(), 3);
        assert_eq!(mdl.frames[0].verts[1].xyz, [5, 6, 7]);
        assert_eq!(mdl.frames[0].verts[1].normal_index, 1);
    }

    #[test]
    fn trivertx_position_uses_scale_origin() {
        let v = TriVertx { xyz: [2, 4, 8], normal_index: 0 };
        let pos = v.position([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]);
        assert_eq!(pos, Vec3::new(12.0, 28.0, 54.0));
    }

    #[test]
    fn stvert_uv_handles_seam_wrap() {
        let v = StVert { on_seam: true, s: 1, t: 0 };
        let front = v.uv(4, 4, false);
        let back = v.uv(4, 4, true);
        // back-facing on-seam vert wraps S by skin_width / 2 = 2
        assert!((front.x - 0.375).abs() < 1e-5);
        assert!((back.x - 0.875).abs() < 1e-5);
    }

    #[test]
    fn skin_to_rgba_expands_palette() {
        let mut palette: QuakePalette = [[0u8; 3]; 256];
        palette[0] = [10, 20, 30];
        palette[7] = [200, 100, 50];
        palette[255] = [1, 2, 3];

        let skin = Skin {
            width: 2,
            height: 2,
            indices: vec![0, 7, 255, 0],
        };
        let rgba = skin.to_rgba(&palette);
        assert_eq!(rgba.len(), 4 * 4);
        assert_eq!(&rgba[0..4], &[10, 20, 30, 255]);
        assert_eq!(&rgba[4..8], &[200, 100, 50, 255]);
        assert_eq!(&rgba[8..12], &[1, 2, 3, 255]);
        assert_eq!(&rgba[12..16], &[10, 20, 30, 255]);
    }

    #[test]
    fn parses_minimal_header() {
        let bytes = header_bytes(100, 200, 5);
        let h = MdlHeader::parse(&bytes).unwrap();
        assert_eq!(h.num_skins, 1);
        assert_eq!(h.skin_width, 2);
        assert_eq!(h.skin_height, 2);
        assert_eq!(h.num_vertices, 100);
        assert_eq!(h.num_triangles, 200);
        assert_eq!(h.num_frames, 5);
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bytes = header_bytes(0, 0, 0);
        bytes[0..4].copy_from_slice(b"NOPE");
        assert!(matches!(
            MdlHeader::parse(&bytes),
            Err(ModelError::InvalidMdlMagic(_))
        ));
    }
}
