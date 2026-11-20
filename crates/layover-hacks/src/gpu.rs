//! Picking a GPU. The saver asks for one that can present to its surfaces;
//! the wear test asks for any adapter at all.

use anyhow::{Context, Result};
use layover_core::config::Gpu as GpuPref;

pub fn instance() -> wgpu::Instance {
    let mut desc = wgpu::InstanceDescriptor::new_without_display_handle();
    desc.backends = wgpu::Backends::VULKAN;
    wgpu::Instance::new(desc)
}

fn preference(pref: GpuPref) -> wgpu::PowerPreference {
    match pref {
        GpuPref::Auto => wgpu::PowerPreference::None,
        GpuPref::LowPower => wgpu::PowerPreference::LowPower,
        GpuPref::HighPerformance => wgpu::PowerPreference::HighPerformance,
    }
}

pub struct Gpu {
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
}

impl Gpu {
    /// An adapter that can present to `surface` (when given).
    pub fn new(
        instance: &wgpu::Instance,
        pref: GpuPref,
        surface: Option<&wgpu::Surface<'_>>,
    ) -> Result<Gpu> {
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: preference(pref),
            force_fallback_adapter: false,
            compatible_surface: surface,
            ..Default::default()
        }))
        .context("no Vulkan adapter (is a Vulkan driver installed?)")?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("layover"),
            ..Default::default()
        }))
        .context("the GPU refused a device")?;
        Ok(Gpu { adapter, device, queue })
    }

    pub fn headless() -> Result<Gpu> {
        Gpu::new(&instance(), GpuPref::Auto, None)
    }

    pub fn describe(&self) -> String {
        let info = self.adapter.get_info();
        format!("{} ({:?}, {})", info.name, info.device_type, info.driver)
    }
}
