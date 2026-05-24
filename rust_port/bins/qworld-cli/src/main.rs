//! qworld CLI — operates on Quake content from the shell.
//!
//! Subcommands:
//! - `pak list <FILE>`        : list entries in a PAK archive
//! - `pak extract <PAK> <NAME> <OUT>` : extract one entry
//! - `bsp info <FILE>`        : print BSP header + entity count
//! - `bsp spawn <FILE>`       : print the chosen preview spawn point
//! - `demo sniff <FILE>`      : guess demo format from bytes
//!
//! Future: `screenshot`, `mpeg`, `streambot` subcommands once the
//! renderer is online.

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use qworld_fs::Archive;
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
