//! 经 DRM 读出正在扫描输出的帧缓冲：与显示服务器无关，要 root（`CAP_SYS_ADMIN` 才拿得到缓冲句柄）。
//! shortcut: 只认线性排布的 32 位 RGB 格式；QEMU virgl 的扫描输出在宿主 GPU 上、客户机里读不到，要支持时改由宿主截屏。

use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};

const fn drm_iowr(nr: u32, size: usize) -> libc::c_ulong {
    ((3 << 30) | ((size as u32) << 16) | (0x64 << 8) | nr) as libc::c_ulong
}

const fn drm_iow(nr: u32, size: usize) -> libc::c_ulong {
    ((1 << 30) | ((size as u32) << 16) | (0x64 << 8) | nr) as libc::c_ulong
}

#[repr(C)]
#[derive(Default)]
struct CardRes {
    fb_id_ptr: u64,
    crtc_id_ptr: u64,
    connector_id_ptr: u64,
    encoder_id_ptr: u64,
    count_fbs: u32,
    count_crtcs: u32,
    count_connectors: u32,
    count_encoders: u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
}

#[repr(C)]
#[derive(Default)]
struct ModeInfo {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    kind: u32,
    name: [u8; 32],
}

#[repr(C)]
#[derive(Default)]
struct Crtc {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32,
    y: u32,
    gamma_size: u32,
    mode_valid: u32,
    mode: ModeInfo,
}

#[repr(C)]
#[derive(Default)]
struct FbCmd2 {
    fb_id: u32,
    width: u32,
    height: u32,
    pixel_format: u32,
    flags: u32,
    handles: [u32; 4],
    pitches: [u32; 4],
    offsets: [u32; 4],
    modifier: [u64; 4],
}

#[repr(C)]
#[derive(Default)]
struct PrimeHandle {
    handle: u32,
    flags: u32,
    fd: i32,
}

#[repr(C)]
#[derive(Default)]
struct MapDumb {
    handle: u32,
    pad: u32,
    offset: u64,
}

#[repr(C)]
#[derive(Default)]
struct GemClose {
    handle: u32,
    pad: u32,
}

const GET_RESOURCES: libc::c_ulong = drm_iowr(0xA0, size_of::<CardRes>());
const GET_CRTC: libc::c_ulong = drm_iowr(0xA1, size_of::<Crtc>());
const GET_FB2: libc::c_ulong = drm_iowr(0xCE, size_of::<FbCmd2>());
const PRIME_HANDLE_TO_FD: libc::c_ulong = drm_iowr(0x2D, size_of::<PrimeHandle>());
const MAP_DUMB: libc::c_ulong = drm_iowr(0xB3, size_of::<MapDumb>());
const GEM_CLOSE: libc::c_ulong = drm_iow(0x09, size_of::<GemClose>());
const FB_MODIFIERS: u32 = 2;
const FORMAT_MOD_LINEAR: u64 = 0;

const fn fourcc(code: &[u8; 4]) -> u32 {
    u32::from_le_bytes(*code)
}

fn ioctl<T>(file: &File, request: libc::c_ulong, arg: &mut T) -> io::Result<()> {
    loop {
        // SAFETY: arg 是与 request 对应、按内核布局定义的结构体。
        if unsafe { libc::ioctl(file.as_raw_fd(), request as _, arg as *mut T) } == 0 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

/// 有画面输出的 CRTC 与它所在的卡。
fn active_crtc() -> io::Result<(File, Crtc)> {
    for n in 0..8 {
        let Ok(card) = OpenOptions::new().read(true).write(true).open(format!("/dev/dri/card{n}")) else { continue };
        let mut res = CardRes::default();
        if ioctl(&card, GET_RESOURCES, &mut res).is_err() || res.count_crtcs == 0 {
            continue;
        }
        let mut crtcs = vec![0u32; res.count_crtcs as usize];
        res = CardRes { crtc_id_ptr: crtcs.as_mut_ptr() as u64, count_crtcs: crtcs.len() as u32, ..Default::default() };
        ioctl(&card, GET_RESOURCES, &mut res)?;
        crtcs.truncate(res.count_crtcs as usize);
        for id in crtcs {
            let mut crtc = Crtc { crtc_id: id, ..Default::default() };
            if ioctl(&card, GET_CRTC, &mut crtc).is_ok() && crtc.fb_id != 0 && crtc.mode_valid != 0 {
                return Ok((card, crtc));
            }
        }
    }
    Err(io::Error::new(io::ErrorKind::NotFound, "客户机没有正在输出画面的显示器"))
}

/// 主屏的像素尺寸。
pub fn screen_size() -> io::Result<(u32, u32)> {
    let (_, crtc) = active_crtc()?;
    Ok((u32::from(crtc.mode.hdisplay), u32::from(crtc.mode.vdisplay)))
}

/// 一帧 RGB，自上而下逐行。
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgb: Vec<u8>,
}

pub fn capture() -> io::Result<Frame> {
    let (card, crtc) = active_crtc()?;
    let mut fb = FbCmd2 { fb_id: crtc.fb_id, ..Default::default() };
    ioctl(&card, GET_FB2, &mut fb)?;
    let mut handles = fb.handles.to_vec();
    handles.retain(|&h| h != 0);
    handles.dedup();
    let result = read_frame(&card, &crtc, &fb);
    for handle in handles {
        let _ = ioctl(&card, GEM_CLOSE, &mut GemClose { handle, pad: 0 });
    }
    result
}

fn read_frame(card: &File, crtc: &Crtc, fb: &FbCmd2) -> io::Result<Frame> {
    if fb.handles[0] == 0 {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "读不到帧缓冲句柄，代理需要 root"));
    }
    if fb.flags & FB_MODIFIERS != 0 && fb.modifier[0] != FORMAT_MOD_LINEAR {
        return Err(io::Error::new(io::ErrorKind::Unsupported, format!("帧缓冲不是线性排布（modifier {:#x}）", fb.modifier[0])));
    }
    // 每像素 4 字节里 R、G、B 的位置。
    let (r, g, b) = match fb.pixel_format {
        f if f == fourcc(b"XR24") || f == fourcc(b"AR24") => (2, 1, 0),
        f if f == fourcc(b"XB24") || f == fourcc(b"AB24") => (0, 1, 2),
        f => {
            let name = String::from_utf8_lossy(&f.to_le_bytes()).into_owned();
            return Err(io::Error::new(io::ErrorKind::Unsupported, format!("不支持的帧缓冲格式 {name}")));
        }
    };
    let pitch = fb.pitches[0] as usize;
    let len = fb.offsets[0] as usize + pitch * fb.height as usize;
    let mapping = Mapping::new(card, fb.handles[0], len)?;
    let pixels = mapping.bytes();
    let (width, height) = (u32::from(crtc.mode.hdisplay).min(fb.width), u32::from(crtc.mode.vdisplay).min(fb.height));
    let (x0, y0) = (crtc.x as usize, crtc.y as usize);
    let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
    for y in 0..height as usize {
        let row = fb.offsets[0] as usize + (y0 + y) * pitch + x0 * 4;
        for px in pixels.get(row..row + width as usize * 4).unwrap_or_default().as_chunks::<4>().0 {
            rgb.extend_from_slice(&[px[r], px[g], px[b]]);
        }
    }
    if rgb.len() != width as usize * height as usize * 3 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "帧缓冲比显示模式小"));
    }
    Ok(Frame { width, height, rgb })
}

/// 帧缓冲的只读映射：先经 PRIME 导出成 dma-buf 映射，驱动不支持时按 dumb 缓冲映射。
struct Mapping {
    ptr: *mut libc::c_void,
    len: usize,
    _prime: Option<File>,
}

impl Mapping {
    fn new(card: &File, handle: u32, len: usize) -> io::Result<Self> {
        let mut prime = PrimeHandle { handle, flags: libc::O_CLOEXEC as u32, fd: -1 };
        if ioctl(card, PRIME_HANDLE_TO_FD, &mut prime).is_ok() {
            // SAFETY: fd 是内核刚交出的 dma-buf，由 File 接管关闭。
            let file = unsafe { File::from_raw_fd(prime.fd) };
            if let Ok(ptr) = map(&file, len, 0) {
                return Ok(Self { ptr, len, _prime: Some(file) });
            }
        }
        let mut dumb = MapDumb { handle, ..Default::default() };
        ioctl(card, MAP_DUMB, &mut dumb)?;
        Ok(Self { ptr: map(card, len, dumb.offset as libc::off_t)?, len, _prime: None })
    }

    fn bytes(&self) -> &[u8] {
        // SAFETY: ptr 是长度为 len 的有效只读映射，存活到 self 析构。
        unsafe { std::slice::from_raw_parts(self.ptr as *const u8, self.len) }
    }
}

impl Drop for Mapping {
    fn drop(&mut self) {
        // SAFETY: 释放 new 里建立的映射。
        unsafe { libc::munmap(self.ptr, self.len) };
    }
}

fn map(file: &File, len: usize, offset: libc::off_t) -> io::Result<*mut libc::c_void> {
    // SAFETY: 按文件描述符建立只读共享映射，失败时返回 MAP_FAILED。
    let ptr = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_SHARED, file.as_raw_fd(), offset) };
    if ptr == libc::MAP_FAILED { Err(io::Error::last_os_error()) } else { Ok(ptr) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_struct_sizes() {
        assert_eq!(size_of::<CardRes>(), 64);
        assert_eq!(size_of::<ModeInfo>(), 68);
        assert_eq!(size_of::<Crtc>(), 104);
        assert_eq!(size_of::<FbCmd2>(), 104);
        assert_eq!(size_of::<PrimeHandle>(), 12);
        assert_eq!(size_of::<MapDumb>(), 16);
        assert_eq!(GET_RESOURCES, 0xC040_64A0);
        assert_eq!(GET_FB2, 0xC068_64CE);
        assert_eq!(fourcc(b"XR24"), 0x3432_5258);
    }
}
