//! wgpu-based renderer for the Quake world.
//!
//! Target both unix-native (Vulkan/Metal/DX12) and web (WebGPU /
//! WebGL2 fallback) from one codebase. Headless rendering for the
//! CLI screenshot / streambot use cases works via offscreen
//! textures (no swapchain needed).
//!
//! Status: scaffold + mesh pipeline. BSP world geometry feeding,
//! alias models, sprites, particles, 2D HUD are TBD.

pub mod context;
pub mod headless;
pub mod mesh;
pub mod pipeline;

// Re-export so downstream crates don't need wgpu as a direct dep
// just to construct a clear color or other wgpu primitives that
// surface through this crate's API.
pub use wgpu;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("wgpu request_adapter returned None")]
    NoAdapter,

    #[error("wgpu request_device error: {0}")]
    RequestDevice(#[from] wgpu::RequestDeviceError),

    #[error("wgpu create_surface error: {0}")]
    CreateSurface(#[from] wgpu::CreateSurfaceError),

    #[error("wgpu buffer async error: {0}")]
    BufferAsync(#[from] wgpu::BufferAsyncError),
}

#[cfg(test)]
mod tests {
    use crate::{
        context::GpuContext,
        headless::{HeadlessTarget, COLOR_FORMAT},
        mesh::{Mesh, Vertex},
        pipeline::MeshPipeline,
    };
    use glam::Mat4;

    /// Build a GPU context. If no GPU adapter is available (CI
    /// without a display, container without GPU passthrough), return
    /// `None` and let the caller skip the test.
    fn try_gpu() -> Option<GpuContext> {
        pollster::block_on(GpuContext::new_headless()).ok()
    }

    #[test]
    fn clear_only_target_reads_back_solid_color() {
        let Some(ctx) = try_gpu() else { return };
        let target = HeadlessTarget::new(&ctx, 8, 8);
        target.render_clear(
            &ctx,
            wgpu::Color {
                r: 0.0,
                g: 1.0,
                b: 0.0,
                a: 1.0,
            },
        );
        let pixels = pollster::block_on(target.read_back_rgba(&ctx)).unwrap();
        // 8x8 RGBA = 256 bytes
        assert_eq!(pixels.len(), 8 * 8 * 4);
        // First pixel should be green (with srgb conversion the green
        // channel might shift a bit; allow >= 200 as a loose check).
        assert!(pixels[1] > 200, "green channel was {}", pixels[1]);
    }

    #[test]
    fn mesh_pipeline_renders_centred_triangle() {
        let Some(ctx) = try_gpu() else { return };
        let target = HeadlessTarget::with_depth(&ctx, 16, 16);
        let pipeline = MeshPipeline::new(&ctx, COLOR_FORMAT);

        // A triangle that covers roughly the centre of NDC space,
        // coloured red. Vertices in CCW order so default front-face
        // wins.
        let vertices = [
            Vertex { position: [-0.8, -0.8, 0.0], color: [1.0, 0.0, 0.0] },
            Vertex { position: [ 0.8, -0.8, 0.0], color: [1.0, 0.0, 0.0] },
            Vertex { position: [ 0.0,  0.8, 0.0], color: [1.0, 0.0, 0.0] },
        ];
        let indices: [u32; 3] = [0, 1, 2];
        let mesh = Mesh::upload(&ctx.device, &vertices, &indices);

        pipeline.render(
            &ctx,
            &target,
            Mat4::IDENTITY,
            &mesh,
            wgpu::Color {
                r: 0.0,
                g: 0.0,
                b: 1.0, // blue background
                a: 1.0,
            },
        );

        let pixels = pollster::block_on(target.read_back_rgba(&ctx)).unwrap();
        // 16x16 RGBA
        assert_eq!(pixels.len(), 16 * 16 * 4);

        // Centre pixel should be red (triangle), corner pixel blue.
        let centre = pixel_at(&pixels, 16, 8, 8);
        let corner = pixel_at(&pixels, 16, 0, 0);
        assert!(
            centre[0] > 200 && centre[2] < 50,
            "centre pixel expected red, got {centre:?}"
        );
        assert!(
            corner[2] > 200 && corner[0] < 50,
            "corner pixel expected blue, got {corner:?}"
        );
    }

    fn pixel_at(pixels: &[u8], width: u32, x: u32, y: u32) -> [u8; 4] {
        let offset = ((y * width + x) * 4) as usize;
        [
            pixels[offset],
            pixels[offset + 1],
            pixels[offset + 2],
            pixels[offset + 3],
        ]
    }
}
