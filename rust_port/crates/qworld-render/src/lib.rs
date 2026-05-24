//! wgpu-based renderer for the Quake world.
//!
//! Target both unix-native (Vulkan/Metal/DX12) and web (WebGPU /
//! WebGL2 fallback) from one codebase. Headless rendering for the
//! CLI screenshot / streambot use cases works via offscreen
//! textures (no swapchain needed).
//!
//! Status: scaffold. Init + clear-color is implemented; BSP world
//! rendering, alias models, sprites, particles, 2D HUD all TBD.

pub mod context;
pub mod headless;

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
