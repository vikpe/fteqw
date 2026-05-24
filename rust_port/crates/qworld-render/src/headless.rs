//! Headless render target: a color texture (always) and an optional
//! depth texture, plus a CPU readback helper.
//!
//! Used by the CLI screenshot pipeline and integration tests.
//! Real-time / windowed surfaces will live in a sibling module.

use crate::{context::GpuContext, pipeline::DEPTH_FORMAT, RenderError};

pub const COLOR_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

pub struct HeadlessTarget {
    pub color_texture: wgpu::Texture,
    pub color_view: wgpu::TextureView,
    pub depth_texture: Option<wgpu::Texture>,
    pub depth_view: Option<wgpu::TextureView>,
    pub width: u32,
    pub height: u32,
}

impl HeadlessTarget {
    /// Create a color-only target (no depth). Useful for the
    /// clear-only path and for 2D drawing.
    #[must_use]
    pub fn new(ctx: &GpuContext, width: u32, height: u32) -> Self {
        let color_texture = make_color_texture(ctx, width, height);
        let color_view = color_texture.create_view(&wgpu::TextureViewDescriptor::default());
        Self {
            color_texture,
            color_view,
            depth_texture: None,
            depth_view: None,
            width,
            height,
        }
    }

    /// Create a target with both a color and a depth attachment.
    /// Required by [`crate::pipeline::MeshPipeline`].
    #[must_use]
    pub fn with_depth(ctx: &GpuContext, width: u32, height: u32) -> Self {
        let mut target = Self::new(ctx, width, height);
        let depth_texture = ctx.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("qworld headless depth"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: DEPTH_FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let depth_view = depth_texture.create_view(&wgpu::TextureViewDescriptor::default());
        target.depth_texture = Some(depth_texture);
        target.depth_view = Some(depth_view);
        target
    }

    /// Submit a clear-only render pass against the color attachment.
    pub fn render_clear(&self, ctx: &GpuContext, clear: wgpu::Color) {
        let mut encoder = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("qworld clear encoder"),
            });
        {
            let _rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.color_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(clear),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
        }
        ctx.queue.submit(Some(encoder.finish()));
    }

    /// Copy the color attachment back to CPU as a tightly-packed
    /// RGBA8 buffer (rows of `width * 4` bytes, no padding).
    pub async fn read_back_rgba(&self, ctx: &GpuContext) -> Result<Vec<u8>, RenderError> {
        let bytes_per_row = align_up(self.width * 4, 256);
        let buffer_size = u64::from(bytes_per_row * self.height);
        let buffer = ctx.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("qworld readback"),
            size: buffer_size,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let mut encoder = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("qworld readback encoder"),
            });
        encoder.copy_texture_to_buffer(
            wgpu::ImageCopyTexture {
                texture: &self.color_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::ImageCopyBuffer {
                buffer: &buffer,
                layout: wgpu::ImageDataLayout {
                    offset: 0,
                    bytes_per_row: Some(bytes_per_row),
                    rows_per_image: Some(self.height),
                },
            },
            wgpu::Extent3d {
                width: self.width,
                height: self.height,
                depth_or_array_layers: 1,
            },
        );
        ctx.queue.submit(Some(encoder.finish()));

        let buffer_slice = buffer.slice(..);
        let (sender, receiver) = futures_intrusive::channel::shared::oneshot_channel();
        buffer_slice.map_async(wgpu::MapMode::Read, move |v| {
            sender.send(v).ok();
        });
        ctx.device.poll(wgpu::Maintain::Wait);
        receiver.receive().await.expect("readback channel")?;

        let data = buffer_slice.get_mapped_range();
        let mut out = Vec::with_capacity((self.width * self.height * 4) as usize);
        for y in 0..self.height {
            let row_start = (y * bytes_per_row) as usize;
            out.extend_from_slice(&data[row_start..row_start + (self.width * 4) as usize]);
        }
        Ok(out)
    }
}

fn make_color_texture(ctx: &GpuContext, width: u32, height: u32) -> wgpu::Texture {
    ctx.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("qworld headless color"),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: COLOR_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    })
}

fn align_up(value: u32, align: u32) -> u32 {
    value.div_ceil(align) * align
}
