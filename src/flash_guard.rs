//! Reduced Motion flash limiter.
//!
//! When Reduced Motion is on, the live path renders its final composite into
//! `input_view` instead of the swapchain. `run()` then measures the frame's
//! mean luminance on the GPU and writes it to the swapchain with its overall
//! brightness slew-limited (see shaders/flash_guard.wgsl), so large
//! full-frame brightness swings can happen at most ~2.5 times per second.
//! Everything stays on the GPU — no readback, no frame of latency.

use bytemuck::{Pod, Zeroable};

/// Max change in mean relative luminance per second. A 10% swing therefore
/// takes ≥ 0.2 s and a flash (up + down) ≥ 0.4 s → ≤ 2.5 flashes/s (< 3 Hz).
pub const MAX_LUMA_RATE_PER_S: f32 = 0.5;

const STATE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba32Float;

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct GuardUniforms {
    dt:       f32,
    reset:    f32,
    max_rate: f32,
    _pad:     f32,
}

pub struct FlashGuard {
    _input_texture: wgpu::Texture,
    pub input_view: wgpu::TextureView,
    state_views: [wgpu::TextureView; 2],
    _state_textures: [wgpu::Texture; 2],
    /// Index of the state texture holding last frame's result.
    current: usize,
    state_pipeline: wgpu::RenderPipeline,
    apply_pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    uniforms: wgpu::Buffer,
    reset_pending: bool,
    width: u32,
    height: u32,
    format: wgpu::TextureFormat,
}

impl FlashGuard {
    pub fn new(device: &wgpu::Device, width: u32, height: u32, format: wgpu::TextureFormat) -> Self {
        let (input_texture, input_view) = Self::make_input(device, width, height, format);
        let make_state = |label| {
            let t = device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: STATE_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let v = t.create_view(&wgpu::TextureViewDescriptor::default());
            (t, v)
        };
        let (sa, va) = make_state("FlashGuard state A");
        let (sb, vb) = make_state("FlashGuard state B");

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("FlashGuard sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });
        let uniforms = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("FlashGuard uniforms"),
            size: std::mem::size_of::<GuardUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("FlashGuard BGL"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("FlashGuard shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/flash_guard.wgsl").into()),
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("FlashGuard pipeline layout"),
            bind_group_layouts: &[&bgl],
            push_constant_ranges: &[],
        });
        let make_pipeline = |label, entry, fmt| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(label),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: "vs_main",
                    buffers: &[],
                    compilation_options: Default::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: entry,
                    targets: &[Some(wgpu::ColorTargetState {
                        format: fmt,
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                    compilation_options: Default::default(),
                }),
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview: None,
                cache: None,
            })
        };
        let state_pipeline = make_pipeline("FlashGuard state pipeline", "fs_state", STATE_FORMAT);
        let apply_pipeline = make_pipeline("FlashGuard apply pipeline", "fs_apply", format);

        Self {
            _input_texture: input_texture,
            input_view,
            state_views: [va, vb],
            _state_textures: [sa, sb],
            current: 0,
            state_pipeline,
            apply_pipeline,
            bgl,
            sampler,
            uniforms,
            reset_pending: true,
            width,
            height,
            format,
        }
    }

    fn make_input(
        device: &wgpu::Device, width: u32, height: u32, format: wgpu::TextureFormat,
    ) -> (wgpu::Texture, wgpu::TextureView) {
        let t = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("FlashGuard input"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let v = t.create_view(&wgpu::TextureViewDescriptor::default());
        (t, v)
    }

    pub fn resize(&mut self, device: &wgpu::Device, width: u32, height: u32) {
        if width == self.width && height == self.height { return; }
        let (t, v) = Self::make_input(device, width, height, self.format);
        self._input_texture = t;
        self.input_view = v;
        self.width = width;
        self.height = height;
    }

    /// Next `run()` snaps the displayed luminance to the measured one
    /// (call when the guard is (re-)enabled so it starts from the real frame).
    pub fn reset(&mut self) {
        self.reset_pending = true;
    }

    /// Measure `input_view`, update the limiter state, and write the
    /// brightness-limited frame to `target`.
    pub fn run(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::TextureView,
        dt: f32,
    ) {
        queue.write_buffer(&self.uniforms, 0, bytemuck::cast_slice(&[GuardUniforms {
            dt,
            reset: if self.reset_pending { 1.0 } else { 0.0 },
            max_rate: MAX_LUMA_RATE_PER_S,
            _pad: 0.0,
        }]));
        self.reset_pending = false;

        let prev = self.current;
        let next = 1 - prev;
        let bind = |state: &wgpu::TextureView| {
            device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("FlashGuard BG"),
                layout: &self.bgl,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: self.uniforms.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&self.input_view) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(state) },
                    wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                ],
            })
        };
        let state_bg = bind(&self.state_views[prev]);
        let apply_bg = bind(&self.state_views[next]);

        for (label, view, pipeline, bg) in [
            ("FlashGuard state pass", &self.state_views[next], &self.state_pipeline, &state_bg),
            ("FlashGuard apply pass", target, &self.apply_pipeline, &apply_bg),
        ] {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some(label),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                occlusion_query_set: None,
                timestamp_writes: None,
            });
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, bg, &[]);
            pass.draw(0..3, 0..1);
        }
        self.current = next;
    }
}
