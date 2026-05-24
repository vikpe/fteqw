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
