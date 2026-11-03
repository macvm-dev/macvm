//! 线性帧缓冲垫片：Apple Virtualization.framework 固件的 GOP 只支持 Blt、没有可直接写的帧缓冲，
//! Windows 启动管理器显示 logo 时找不到帧缓冲就会停止启动。
//!
//! 在原 GOP 所在句柄上换装一个自己的 GOP：帧缓冲是一块保留内存（操作系统不会回收），
//! 启动服务期间每 40ms 把它整屏 Blt 回原 GOP。退出启动服务后画面停在最后一帧，直到 Windows 加载 virtio-gpu 驱动。

extern crate alloc;

use alloc::boxed::Box;
use core::ffi::c_void;
use core::ptr;
use uefi::boot::{self, EventType, MemoryType, SearchType, TimerTrigger, Tpl};
use uefi::proto::console::gop::GraphicsOutput;
use uefi::{Event, Identify};
use uefi_raw::Status;
use uefi_raw::protocol::console::{
    GraphicsOutputBltOperation as Op, GraphicsOutputBltPixel as Pixel, GraphicsOutputModeInformation as ModeInfo,
    GraphicsOutputProtocol as RawGop, GraphicsOutputProtocolMode as Mode, GraphicsPixelFormat, PixelBitmask,
};

/// 40ms，单位 100ns。
const FLUSH_PERIOD: u64 = 400_000;

#[repr(C)]
struct Shim {
    /// 必须是第一个字段：固件把 `*mut RawGop` 传回各函数，按此布局转换为 `*mut Shim`。
    gop: RawGop,
    mode: Mode,
    info: ModeInfo,
    original: *mut RawGop,
    fb: *mut Pixel,
    width: usize,
    height: usize,
}

/// 原 GOP 已有线性帧缓冲、或找不到 GOP 时什么都不做。
pub fn install() -> uefi::Result<()> {
    let handles = boot::locate_handle_buffer(SearchType::ByProtocol(&GraphicsOutput::GUID))?;
    let Some(&handle) = handles.first() else { return Ok(()) };
    // SAFETY: 以 GetProtocol 方式取原接口指针，不独占、不需要关闭。
    let original = unsafe {
        let scoped = boot::open_protocol::<GraphicsOutput>(
            boot::OpenProtocolParams { handle, agent: boot::image_handle(), controller: None },
            boot::OpenProtocolAttributes::GetProtocol,
        )?;
        &*scoped as *const GraphicsOutput as *mut RawGop
    };

    // SAFETY: original 指向固件维护的有效 GOP，mode/info 在启动服务期间有效。
    let (width, height, linear) = unsafe {
        let mode = &*(*original).mode;
        let info = &*mode.info;
        (info.horizontal_resolution as usize, info.vertical_resolution as usize,
         info.pixel_format != GraphicsPixelFormat::PIXEL_BLT_ONLY && mode.frame_buffer_base != 0)
    };
    if linear || width == 0 || height == 0 {
        return Ok(());
    }

    let bytes = width * height * 4;
    let pages = bytes.div_ceil(4096);
    let fb = boot::allocate_pages(boot::AllocateType::AnyPages, MemoryType::RESERVED, pages)?.as_ptr() as *mut Pixel;
    // SAFETY: fb 是刚分配的 bytes 字节。
    unsafe { ptr::write_bytes(fb as *mut u8, 0, bytes) };

    let shim = Box::leak(Box::new(Shim {
        gop: RawGop { query_mode, set_mode, blt, mode: ptr::null_mut() },
        mode: Mode {
            max_mode: 1,
            mode: 0,
            info: ptr::null_mut(),
            size_of_info: size_of::<ModeInfo>(),
            frame_buffer_base: fb as u64,
            frame_buffer_size: bytes,
        },
        info: ModeInfo {
            version: 0,
            horizontal_resolution: width as u32,
            vertical_resolution: height as u32,
            pixel_format: GraphicsPixelFormat::PIXEL_BLUE_GREEN_RED_RESERVED_8_BIT_PER_COLOR,
            pixel_information: PixelBitmask { red: 0, green: 0, blue: 0, reserved: 0 },
            pixels_per_scan_line: width as u32,
        },
        original,
        fb,
        width,
        height,
    }));
    shim.mode.info = &mut shim.info;
    shim.gop.mode = &mut shim.mode;
    let shim_ptr: *mut Shim = shim;

    // SAFETY: 用同一 GUID 把句柄上的接口从原 GOP 换成垫片，两者布局相同。
    unsafe {
        boot::reinstall_protocol_interface(handle, &GraphicsOutput::GUID, original as *const c_void, shim_ptr as *const c_void)?;
        let event = boot::create_event(EventType::TIMER | EventType::NOTIFY_SIGNAL, Tpl::CALLBACK, Some(flush), ptr::NonNull::new(shim_ptr as *mut c_void))?;
        boot::set_timer(&event, TimerTrigger::Periodic(FLUSH_PERIOD))?;
    }
    Ok(())
}

unsafe extern "efiapi" fn flush(_event: Event, context: Option<ptr::NonNull<c_void>>) {
    let Some(context) = context else { return };
    // SAFETY: context 是 install 中泄漏的 Shim，生命周期覆盖整个启动服务阶段。
    unsafe {
        let shim = &*(context.as_ptr() as *const Shim);
        let _ = ((*shim.original).blt)(shim.original, shim.fb, Op::BLT_BUFFER_TO_VIDEO, 0, 0, 0, 0, shim.width, shim.height, 0);
    }
}

unsafe extern "efiapi" fn query_mode(this: *const RawGop, mode: u32, size: *mut usize, info: *mut *const ModeInfo) -> Status {
    if mode != 0 || size.is_null() || info.is_null() {
        return Status::INVALID_PARAMETER;
    }
    // 规范要求返回调用方用 FreePool 释放的拷贝。
    let Ok(copy) = boot::allocate_pool(MemoryType::BOOT_SERVICES_DATA, size_of::<ModeInfo>()) else {
        return Status::OUT_OF_RESOURCES;
    };
    // SAFETY: this 即 Shim 的首字段；copy 大小与 ModeInfo 一致。
    unsafe {
        let shim = &*(this as *const Shim);
        ptr::write(copy.as_ptr() as *mut ModeInfo, ptr::read(&shim.info));
        *size = size_of::<ModeInfo>();
        *info = copy.as_ptr() as *const ModeInfo;
    }
    Status::SUCCESS
}

unsafe extern "efiapi" fn set_mode(this: *mut RawGop, mode: u32) -> Status {
    if mode != 0 {
        return Status::UNSUPPORTED;
    }
    // SAFETY: 同 query_mode。
    unsafe {
        let shim = &*(this as *const Shim);
        ptr::write_bytes(shim.fb as *mut u8, 0, shim.width * shim.height * 4);
    }
    Status::SUCCESS
}

#[allow(clippy::too_many_arguments)]
unsafe extern "efiapi" fn blt(
    this: *mut RawGop, buffer: *mut Pixel, op: Op,
    sx: usize, sy: usize, dx: usize, dy: usize, w: usize, h: usize, delta: usize,
) -> Status {
    // SAFETY: this 即 Shim；所有访问先做边界检查。
    let shim = unsafe { &*(this as *const Shim) };
    let (fw, fh) = (shim.width, shim.height);
    if w == 0 || h == 0 {
        return Status::INVALID_PARAMETER;
    }
    let stride = if delta == 0 { w } else { delta / 4 };
    let fits = |x: usize, y: usize| x.checked_add(w).is_some_and(|r| r <= fw) && y.checked_add(h).is_some_and(|b| b <= fh);
    // SAFETY: 下列指针运算都在已检查的矩形范围内。
    unsafe {
        match op {
            Op::BLT_VIDEO_FILL => {
                if buffer.is_null() || !fits(dx, dy) { return Status::INVALID_PARAMETER; }
                let pixel = *buffer;
                for row in 0..h {
                    let line = shim.fb.add((dy + row) * fw + dx);
                    for col in 0..w { *line.add(col) = pixel; }
                }
            }
            Op::BLT_VIDEO_TO_BLT_BUFFER => {
                if buffer.is_null() || !fits(sx, sy) { return Status::INVALID_PARAMETER; }
                for row in 0..h {
                    ptr::copy_nonoverlapping(shim.fb.add((sy + row) * fw + sx), buffer.add((dy + row) * stride + dx), w);
                }
            }
            Op::BLT_BUFFER_TO_VIDEO => {
                if buffer.is_null() || !fits(dx, dy) { return Status::INVALID_PARAMETER; }
                for row in 0..h {
                    ptr::copy_nonoverlapping(buffer.add((sy + row) * stride + sx), shim.fb.add((dy + row) * fw + dx), w);
                }
            }
            Op::BLT_VIDEO_TO_VIDEO => {
                if !fits(sx, sy) || !fits(dx, dy) { return Status::INVALID_PARAMETER; }
                // 源与目标可能重叠：向下移动时从最后一行开始。
                let rows: &mut dyn Iterator<Item = usize> = if dy > sy { &mut (0..h).rev() } else { &mut (0..h) };
                for row in rows {
                    ptr::copy(shim.fb.add((sy + row) * fw + sx), shim.fb.add((dy + row) * fw + dx), w);
                }
            }
            _ => return Status::INVALID_PARAMETER,
        }
    }
    Status::SUCCESS
}
