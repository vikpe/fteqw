//! qworld CLI — operates on Quake content from the shell.
//!
//! Subcommands:
//! - `pak list <FILE>`        : list entries in a PAK archive
//! - `pak extract <PAK> <NAME> <OUT>` : extract one entry
//! - `bsp info <FILE>`        : print BSP header + entity count
//! - `bsp spawn <FILE>`       : print the chosen preview spawn point
//! - `demo sniff <FILE>`      : guess demo format from bytes
//! - `render <FILE> --out <PNG>` : render an overview screenshot of a BSP
//!
//! Future: `mpeg`, `streambot` subcommands.

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use glam::{Mat4, Vec3};
use qworld_bsp::{
    geom::{decode_edges, decode_faces, decode_surfedges, decode_vertexes, face_vertices},
    Bsp,
};
use qworld_fs::Archive;
use qworld_render::{
    context::GpuContext,
    headless::{HeadlessTarget, COLOR_FORMAT},
    mesh::{Mesh, Vertex},
    pipeline::MeshPipeline,
    wgpu,
};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "qworld", version, about = "QuakeWorld engine CLI")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// PAK archive operations
    Pak {
        #[command(subcommand)]
        op: PakOp,
    },
    /// BSP map operations
    Bsp {
        #[command(subcommand)]
        op: BspOp,
    },
    /// Demo file operations
    Demo {
        #[command(subcommand)]
        op: DemoOp,
    },
    /// Render an overview PNG of a BSP map
    Render {
        file: PathBuf,
        /// Output PNG path
        #[arg(long)]
        out: PathBuf,
        #[arg(long, default_value_t = 1024)]
        width: u32,
        #[arg(long, default_value_t = 768)]
        height: u32,
    },
}

#[derive(Subcommand)]
enum PakOp {
    /// List all entries in a PAK
    List { file: PathBuf },
    /// Extract one entry to disk
    Extract {
        pak: PathBuf,
        name: String,
        out: PathBuf,
    },
}

#[derive(Subcommand)]
enum BspOp {
    /// Print BSP header info
    Info { file: PathBuf },
    /// Print chosen preview spawn point
    Spawn { file: PathBuf },
}

#[derive(Subcommand)]
enum DemoOp {
    /// Guess demo format
    Sniff { file: PathBuf },
}

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Pak { op } => match op {
            PakOp::List { file } => pak_list(&file),
            PakOp::Extract { pak, name, out } => pak_extract(&pak, &name, &out),
        },
        Cmd::Bsp { op } => match op {
            BspOp::Info { file } => bsp_info(&file),
            BspOp::Spawn { file } => bsp_spawn(&file),
        },
        Cmd::Demo { op } => match op {
            DemoOp::Sniff { file } => demo_sniff(&file),
        },
        Cmd::Render { file, out, width, height } => render_bsp(&file, &out, width, height),
    }
}

fn pak_list(path: &std::path::Path) -> Result<()> {
    let reader = qworld_fs::pak::PakReader::open(path)
        .with_context(|| format!("open {}", path.display()))?;
    for e in reader.entries_slice() {
        println!("{:>10}  {}", e.size, e.name);
    }
    println!("({} entries)", reader.entries_slice().len());
    Ok(())
}

fn pak_extract(pak_path: &std::path::Path, name: &str, out: &std::path::Path) -> Result<()> {
    let mut reader = qworld_fs::pak::PakReader::open(pak_path)?;
    let bytes = reader.read(name)?;
    std::fs::write(out, &bytes)?;
    println!("wrote {} bytes to {}", bytes.len(), out.display());
    Ok(())
}

fn bsp_info(path: &std::path::Path) -> Result<()> {
    let bytes = std::fs::read(path)?;
    let bsp = qworld_bsp::Bsp::from_bytes(bytes)?;
    println!("version: {}", bsp.header.version);
    let ents = bsp.entities_str()?;
    let n_blocks = qworld_bsp::entity::parse_entities(ents)?.len();
    println!("entities: {n_blocks} blocks");
    for (i, lump) in qworld_bsp::Lump::ALL.iter().enumerate() {
        let dir = bsp.header.dir[i];
        println!(
            "  {:<14}  offset={:>10}  length={:>10}",
            format!("{:?}", lump),
            dir.offset,
            dir.length
        );
    }
    Ok(())
}

fn bsp_spawn(path: &std::path::Path) -> Result<()> {
    let bytes = std::fs::read(path)?;
    let bsp = qworld_bsp::Bsp::from_bytes(bytes)?;
    let server = qworld_server::LocalServer::spawn_on_map(bsp)?;
    println!("origin: {:?}", server.spawn_origin);
    println!("yaw: {}", server.spawn_yaw);
    Ok(())
}

fn demo_sniff(path: &std::path::Path) -> Result<()> {
    let bytes = std::fs::read(path)?;
    match qworld_demo::sniff(&bytes) {
        Some(fmt) => {
            println!("{fmt:?}");
            Ok(())
        }
        None => bail!("too short to sniff"),
    }
}

fn render_bsp(path: &std::path::Path, out: &std::path::Path, width: u32, height: u32) -> Result<()> {
    let bytes = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    let bsp = Bsp::from_bytes(bytes)?;
    let (vertices, indices, world_bounds) = build_world_mesh(&bsp)?;
    let view_proj = overview_camera(world_bounds, width, height);

    let ctx = pollster::block_on(GpuContext::new_headless())
        .map_err(|e| anyhow::anyhow!("init gpu: {e}"))?;
    let target = HeadlessTarget::with_depth(&ctx, width, height);
    let pipeline = MeshPipeline::new(&ctx, COLOR_FORMAT);
    let mesh = Mesh::upload(&ctx.device, &vertices, &indices);

    pipeline.render(
        &ctx,
        &target,
        view_proj,
        &mesh,
        wgpu::Color { r: 0.05, g: 0.05, b: 0.08, a: 1.0 },
    );

    let rgba = pollster::block_on(target.read_back_rgba(&ctx))
        .map_err(|e| anyhow::anyhow!("readback: {e}"))?;
    image::save_buffer(out, &rgba, width, height, image::ColorType::Rgba8)
        .with_context(|| format!("write {}", out.display()))?;
    println!(
        "rendered {} triangles -> {} ({}x{})",
        indices.len() / 3,
        out.display(),
        width,
        height
    );
    Ok(())
}

/// Triangulate every BSP face as a fan; color each face by a hash of
/// its texinfo index so distinct surfaces are distinguishable.
fn build_world_mesh(bsp: &Bsp) -> Result<(Vec<Vertex>, Vec<u32>, Option<WorldBounds>)> {
    let positions = decode_vertexes(bsp)?;
    let edges = decode_edges(bsp)?;
    let surfedges = decode_surfedges(bsp)?;
    let faces = decode_faces(bsp)?;

    let mut out_vertices: Vec<Vertex> = Vec::new();
    let mut out_indices: Vec<u32> = Vec::new();
    let mut bounds: Option<WorldBounds> = None;

    for face in &faces {
        let polygon = face_vertices(face, &surfedges, &edges, &positions);
        if polygon.len() < 3 {
            continue;
        }
        let color = face_color(face.texinfo);
        let base = out_vertices.len() as u32;
        for point in &polygon {
            out_vertices.push(Vertex {
                position: [point.x, point.y, point.z],
                color,
            });
            bounds = Some(match bounds {
                None => WorldBounds { min: *point, max: *point },
                Some(b) => WorldBounds {
                    min: b.min.min(*point),
                    max: b.max.max(*point),
                },
            });
        }
        for i in 1..(polygon.len() as u32 - 1) {
            out_indices.push(base);
            out_indices.push(base + i);
            out_indices.push(base + i + 1);
        }
    }
    Ok((out_vertices, out_indices, bounds))
}

#[derive(Clone, Copy)]
struct WorldBounds {
    min: Vec3,
    max: Vec3,
}

/// Pick a 3/4 orbit camera that frames the map's bounds. For an
/// empty BSP, return the identity matrix; the resulting render is
/// just the clear color, which is the right answer.
fn overview_camera(bounds: Option<WorldBounds>, width: u32, height: u32) -> Mat4 {
    let Some(bounds) = bounds else {
        return Mat4::IDENTITY;
    };
    let center = (bounds.min + bounds.max) * 0.5;
    let radius = ((bounds.max - bounds.min).max_element() * 0.5).max(64.0);
    let eye = center + Vec3::new(1.0, 1.0, 0.6).normalize() * radius * 2.5;
    let view = Mat4::look_at_rh(eye, center, Vec3::Z);
    let aspect = width as f32 / height as f32;
    let proj = Mat4::perspective_rh(60_f32.to_radians(), aspect, 1.0, radius * 10.0);
    proj * view
}

/// Deterministic per-face color from texinfo index. Brightens the
/// hash output so the visualisation never reads as near-black.
fn face_color(texinfo_index: u32) -> [f32; 3] {
    let hash = texinfo_index.wrapping_mul(0x9E37_79B1);
    let r = ((hash >> 16) & 0xFF) as f32 / 255.0;
    let g = ((hash >> 8) & 0xFF) as f32 / 255.0;
    let b = (hash & 0xFF) as f32 / 255.0;
    [r * 0.6 + 0.3, g * 0.6 + 0.3, b * 0.6 + 0.3]
}
