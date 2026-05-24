//! End-to-end CLI tests: build a tiny PAK in a tempdir, run the
//! binary, parse its stdout.

use std::process::Command;
use tempfile::TempDir;

fn cli_path() -> std::path::PathBuf {
    // The integration test binary lives next to target/<profile>/deps,
    // so the main binary is up two levels under target/<profile>/qworld.
    let exe = std::env::current_exe().unwrap();
    let target_dir = exe.parent().unwrap().parent().unwrap();
    target_dir.join("qworld")
}

fn write_minimal_pak(dir: &TempDir) -> std::path::PathBuf {
    let pak_path = dir.path().join("pak0.pak");
    let mut file_data = Vec::new();
    file_data.extend_from_slice(&[0u8; 12]); // header placeholder

    let entry_data: &[u8] = b"hello-quake-world";
    let entry_offset = file_data.len() as u32;
    file_data.extend_from_slice(entry_data);

    let dir_offset = file_data.len() as u32;
    let name = "greeting.txt";
    let mut name_buf = [0u8; 56];
    name_buf[..name.len()].copy_from_slice(name.as_bytes());
    file_data.extend_from_slice(&name_buf);
    file_data.extend_from_slice(&entry_offset.to_le_bytes());
    file_data.extend_from_slice(&(entry_data.len() as u32).to_le_bytes());
    let dir_length = 64u32; // one entry

    file_data[0..4].copy_from_slice(b"PACK");
    file_data[4..8].copy_from_slice(&dir_offset.to_le_bytes());
    file_data[8..12].copy_from_slice(&dir_length.to_le_bytes());

    std::fs::write(&pak_path, &file_data).unwrap();
    pak_path
}

#[test]
fn pak_list_outputs_entry() {
    let dir = TempDir::new().unwrap();
    let pak_path = write_minimal_pak(&dir);

    let output = Command::new(cli_path())
        .args(["pak", "list", pak_path.to_str().unwrap()])
        .output()
        .expect("run qworld");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("greeting.txt"), "got: {stdout}");
    assert!(stdout.contains("(1 entries)"), "got: {stdout}");
}

#[test]
fn pak_extract_writes_file() {
    let dir = TempDir::new().unwrap();
    let pak_path = write_minimal_pak(&dir);
    let out_path = dir.path().join("greeting-out.txt");

    let output = Command::new(cli_path())
        .args([
            "pak",
            "extract",
            pak_path.to_str().unwrap(),
            "greeting.txt",
            out_path.to_str().unwrap(),
        ])
        .output()
        .expect("run qworld");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let extracted = std::fs::read(&out_path).unwrap();
    assert_eq!(extracted, b"hello-quake-world");
}

/// Build a one-quad BSP byte-for-byte (4 verts, 4 edges, 4 surfedges,
/// 1 face). Mirrors `qworld_bsp::geom::tests::make_quad_bsp`.
fn write_minimal_bsp(dir: &TempDir) -> std::path::PathBuf {
    const BSP_VERSION_Q1: u32 = 29;
    const NUM_LUMPS: usize = 15;
    // Lump indices from qworld_bsp::lumps::Lump
    const LUMP_VERTEXES: usize = 3;
    const LUMP_FACES: usize = 7;
    const LUMP_EDGES: usize = 12;
    const LUMP_SURFEDGES: usize = 13;

    let vertexes: [[f32; 3]; 4] = [
        [0.0, 0.0, 0.0],
        [128.0, 0.0, 0.0],
        [128.0, 128.0, 0.0],
        [0.0, 128.0, 0.0],
    ];
    let edges: [(u16, u16); 4] = [(0, 1), (1, 2), (2, 3), (3, 0)];
    let surfedges: [i32; 4] = [0, 1, 2, 3];
    let mut face_bytes = Vec::new();
    face_bytes.extend_from_slice(&0u16.to_le_bytes()); // plane
    face_bytes.extend_from_slice(&0u16.to_le_bytes()); // side
    face_bytes.extend_from_slice(&0i32.to_le_bytes()); // first_edge
    face_bytes.extend_from_slice(&4u16.to_le_bytes()); // num_edges
    face_bytes.extend_from_slice(&0u16.to_le_bytes()); // texinfo
    face_bytes.extend_from_slice(&[0u8; 4]); // styles
    face_bytes.extend_from_slice(&(-1i32).to_le_bytes()); // lightofs

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

    let mut file = Vec::new();
    file.extend_from_slice(&BSP_VERSION_Q1.to_le_bytes());
    let dir_pos = file.len();
    file.extend(std::iter::repeat_n(0u8, NUM_LUMPS * 8));

    let mut offsets = [(0u32, 0u32); NUM_LUMPS];
    let put = |file: &mut Vec<u8>, data: &[u8]| -> (u32, u32) {
        let off = file.len() as u32;
        file.extend_from_slice(data);
        (off, data.len() as u32)
    };
    offsets[LUMP_VERTEXES] = put(&mut file, &verts_bytes);
    offsets[LUMP_EDGES] = put(&mut file, &edges_bytes);
    offsets[LUMP_SURFEDGES] = put(&mut file, &surfedge_bytes);
    offsets[LUMP_FACES] = put(&mut file, &face_bytes);

    for (i, (off, len)) in offsets.iter().enumerate() {
        let p = dir_pos + i * 8;
        file[p..p + 4].copy_from_slice(&off.to_le_bytes());
        file[p + 4..p + 8].copy_from_slice(&len.to_le_bytes());
    }

    let bsp_path = dir.path().join("quad.bsp");
    std::fs::write(&bsp_path, &file).unwrap();
    bsp_path
}

#[test]
fn render_writes_png_with_requested_dimensions() {
    let dir = TempDir::new().unwrap();
    let bsp_path = write_minimal_bsp(&dir);
    let out_path = dir.path().join("shot.png");

    let output = Command::new(cli_path())
        .args([
            "render",
            bsp_path.to_str().unwrap(),
            "--out",
            out_path.to_str().unwrap(),
            "--width",
            "64",
            "--height",
            "48",
        ])
        .output()
        .expect("run qworld");

    // Headless GPU init can fail in CI without a GPU adapter. Skip
    // the rest of the assertion in that case rather than failing.
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("init gpu") || stderr.contains("NoAdapter") {
            eprintln!("skipping render test: no GPU adapter ({stderr})");
            return;
        }
        panic!("render failed: {stderr}");
    }

    assert!(out_path.exists(), "PNG was not written");
    let decoded = image::open(&out_path).expect("decode PNG");
    assert_eq!(decoded.width(), 64);
    assert_eq!(decoded.height(), 48);
}
