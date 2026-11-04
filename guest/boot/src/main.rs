//! macvm-boot：放在启动盘的 `\EFI\BOOT\BOOTAA64.EFI`，先装好线性帧缓冲垫片，再在所有文件系统里
//! 找到 Windows 启动管理器转交启动。用于在 Virtualization.framework 上启动 Windows。

#![no_main]
#![no_std]

extern crate alloc;

use alloc::vec::Vec;
use uefi::boot::{self, LoadImageSource, SearchType};
use uefi::prelude::*;
use uefi::proto::device_path::build::{self, DevicePathBuilder};
use uefi::proto::device_path::{DevicePath, DeviceSubType, DeviceType};
use uefi::proto::media::file::{File, FileAttribute, FileMode};
use uefi::proto::media::fs::SimpleFileSystem;
use uefi::{CStr16, Identify, cstr16, println};

mod gop;

const CANDIDATES: [&CStr16; 1] = [cstr16!("\\EFI\\Microsoft\\Boot\\bootmgfw.efi")];

#[entry]
fn main() -> Status {
    let _ = uefi::helpers::init();
    if let Err(e) = gop::install() {
        println!("macvm-boot: 帧缓冲垫片安装失败：{:?}", e.status());
    }
    for path in CANDIDATES {
        if let Some(status) = try_boot(path) {
            return status;
        }
    }
    println!("macvm-boot: 没有找到 Windows 引导程序");
    boot::stall(5_000_000);
    Status::NOT_FOUND
}

/// 找到并启动成功时返回 `Some`（启动的程序返回后的状态）；没找到返回 `None`。
fn try_boot(path: &CStr16) -> Option<Status> {
    let handles = boot::locate_handle_buffer(SearchType::ByProtocol(&SimpleFileSystem::GUID)).ok()?;
    for &handle in handles.iter() {
        if handle == boot::image_handle() || !file_exists(handle, path) {
            continue;
        }
        let Some(device_path) = get_protocol::<DevicePath>(handle) else { continue };
        let mut storage = Vec::new();
        let mut builder = DevicePathBuilder::with_vec(&mut storage);
        for node in device_path.node_iter() {
            if node.device_type() == DeviceType::END && node.sub_type() == DeviceSubType::END_ENTIRE {
                break;
            }
            builder = builder.push(&node).ok()?;
        }
        let full = builder.push(&build::media::FilePath { path_name: path }).ok()?.finalize().ok()?;
        let image = boot::load_image(
            boot::image_handle(),
            LoadImageSource::FromDevicePath { device_path: full, boot_policy: uefi::proto::BootPolicy::ExactMatch },
        )
        .ok()?;
        return Some(match boot::start_image(image) {
            Ok(()) => Status::SUCCESS,
            Err(e) => e.status(),
        });
    }
    None
}

/// 以 GetProtocol 方式打开：独占打开会让固件断开正在使用该协议的驱动。
fn get_protocol<P: uefi::proto::ProtocolPointer + ?Sized>(handle: Handle) -> Option<boot::ScopedProtocol<P>> {
    // SAFETY: 只读使用，不与其他使用者争夺所有权。
    unsafe {
        boot::open_protocol::<P>(
            boot::OpenProtocolParams { handle, agent: boot::image_handle(), controller: None },
            boot::OpenProtocolAttributes::GetProtocol,
        )
    }
    .ok()
}

fn file_exists(handle: Handle, path: &CStr16) -> bool {
    let Some(mut fs) = get_protocol::<SimpleFileSystem>(handle) else { return false };
    let Ok(mut root) = fs.open_volume() else { return false };
    root.open(path, FileMode::Read, FileAttribute::empty()).is_ok()
}
