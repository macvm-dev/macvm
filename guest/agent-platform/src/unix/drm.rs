//! 经 DRM 读出正在扫描输出的帧缓冲：与显示服务器无关，要 root（`CAP_SYS_ADMIN` 才拿得到缓冲句柄）。
//! virtio-gpu 开了 3D（virgl）时扫描输出在宿主 GPU 上，客户机里的缓冲是空的，报 Unsupported。
//! shortcut: 只认线性排布的 32 位 RGB 格式，客户机用上别的格式或平铺排布时再补转换。

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
/// `DRM_IOCTL_VIRTGPU_GETPARAM`：驱动私有命令从 `DRM_COMMAND_BASE`（0x40）起。
const VIRTGPU_GETPARAM: libc::c_ulong = drm_iowr(0x43, size_of::<VirtgpuGetParam>());
const VIRTGPU_PARAM_3D_FEATURES: u64 = 1;

#[repr(C)]
#[derive(Default)]
struct Version {
    major: i32,
    minor: i32,
    patch: i32,
    name_len: usize,
    name: u64,
    date_len: usize,
    date: u64,
    desc_len: usize,
    desc: u64,
}

const VERSION: libc::c_ulong = drm_iowr(0x00, size_of::<Version>());

#[repr(C)]
#[derive(Default)]
struct VirtgpuGetParam {
    param: u64,
    /// 指向接收结果的 int。
    value: u64,
}
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

/// 有画面输出的 CRTC 与它所在的卡；`None` 表示显卡驱动在、但输出关着（客户机闲置息屏）。
/// 固件留下的帧缓冲（simpledrm 一类）在显卡驱动接管后仍挂着开机时的画面，只在没有显卡驱动时才用。
fn active_crtc() -> io::Result<Option<(File, Crtc)>> {
    let mut fallback = None;
    let mut driver_present = false;
    for n in 0..8 {
        let Ok(card) = OpenOptions::new().read(true).write(true).open(format!("/dev/dri/card{n}")) else { continue };
        let firmware = is_firmware_framebuffer(n);
        let crtcs = crtc_ids(&card)?;
        driver_present |= !firmware && !crtcs.is_empty();
        let Some(crtc) = first_active_crtc(&card, crtcs) else { continue };
        if !firmware {
            return Ok(Some((card, crtc)));
        }
        fallback.get_or_insert((card, crtc));
    }
    match fallback {
        _ if driver_present => Ok(None),
        Some(found) => Ok(Some(found)),
        None => Err(io::Error::new(io::ErrorKind::NotFound, "No display is active in the guest")),
    }
}

fn screen_off() -> io::Error {
    io::Error::other("The guest's screen is off because it's idle; press a key or move the mouse to wake it")
}

fn crtc_ids(card: &File) -> io::Result<Vec<u32>> {
    let mut res = CardRes::default();
    if ioctl(card, GET_RESOURCES, &mut res).is_err() || res.count_crtcs == 0 {
        return Ok(Vec::new());
    }
    let mut crtcs = vec![0u32; res.count_crtcs as usize];
    res = CardRes { crtc_id_ptr: crtcs.as_mut_ptr() as u64, count_crtcs: crtcs.len() as u32, ..Default::default() };
    ioctl(card, GET_RESOURCES, &mut res)?;
    crtcs.truncate(res.count_crtcs as usize);
    Ok(crtcs)
}

fn first_active_crtc(card: &File, crtcs: Vec<u32>) -> Option<Crtc> {
    crtcs.into_iter().find_map(|id| {
        let mut crtc = Crtc { crtc_id: id, ..Default::default() };
        (ioctl(card, GET_CRTC, &mut crtc).is_ok() && crtc.fb_id != 0 && crtc.mode_valid != 0).then_some(crtc)
    })
}

/// 卡是开了 3D 的 virtio-gpu。私有命令号各驱动自己定义，先按驱动名确认是 virtio-gpu 再发。
fn renders_on_host(card: &File) -> bool {
    if driver_name(card).as_deref() != Some("virtio_gpu") {
        return false;
    }
    let mut value: i32 = 0;
    let mut param = VirtgpuGetParam { param: VIRTGPU_PARAM_3D_FEATURES, value: &mut value as *mut i32 as u64 };
    ioctl(card, VIRTGPU_GETPARAM, &mut param).is_ok() && value != 0
}

/// 卡的 DRM 驱动名（`DRM_IOCTL_VERSION`），如 `virtio_gpu`。
fn driver_name(card: &File) -> Option<String> {
    let mut name = [0u8; 32];
    let mut version = Version { name_len: name.len(), name: name.as_mut_ptr() as u64, ..Default::default() };
    ioctl(card, VERSION, &mut version).ok()?;
    Some(String::from_utf8_lossy(&name[..version.name_len.min(name.len())]).into_owned())
}

/// 固件帧缓冲的 DRM 驱动在 sysfs 里挂的驱动名：simpledrm、efidrm、vesadrm 按平台设备名匹配，ofdrm 叫 of-display。
const FIRMWARE_FRAMEBUFFER_DRIVERS: [&str; 4] = ["simple-framebuffer", "efi-framebuffer", "vesa-framebuffer", "of-display"];

/// `/dev/dri/card{card}` 是固件留下的帧缓冲。只读 sysfs，不打开设备：打开主节点可能抢走显示服务器要的 DRM master。
pub(crate) fn is_firmware_framebuffer(card: u32) -> bool {
    std::fs::read_link(format!("/sys/class/drm/card{card}/device/driver"))
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .is_some_and(|name| FIRMWARE_FRAMEBUFFER_DRIVERS.contains(&name.as_str()))
}

/// 主屏的像素尺寸。屏幕关着时取显卡输出口的首选模式：唤醒后就是这个尺寸，息屏时注入的输入照样落在对的位置。
pub fn screen_size() -> io::Result<(u32, u32)> {
    match active_crtc()? {
        Some((_, crtc)) => Ok((u32::from(crtc.mode.hdisplay), u32::from(crtc.mode.vdisplay))),
        None => preferred_mode().ok_or_else(screen_off),
    }
}

/// 显卡驱动的卡上第一个接着显示器的输出口的首选模式（sysfs `modes` 的第一行）。
fn preferred_mode() -> Option<(u32, u32)> {
    let mut connectors: Vec<_> = std::fs::read_dir("/sys/class/drm").ok()?.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    connectors.sort();
    connectors.into_iter().find_map(|name| {
        let card = name.strip_prefix("card")?.split_once('-')?.0.parse().ok()?;
        if is_firmware_framebuffer(card) {
            return None;
        }
        let dir = format!("/sys/class/drm/{name}");
        if std::fs::read_to_string(format!("{dir}/status")).ok()?.trim() != "connected" {
            return None;
        }
        parse_mode(std::fs::read_to_string(format!("{dir}/modes")).ok()?.lines().next()?)
    })
}

/// sysfs 里的模式名，如 `2400x1496`，隔行模式带 `i` 后缀。
fn parse_mode(mode: &str) -> Option<(u32, u32)> {
    let (w, h) = mode.split_once('x')?;
    Some((w.parse().ok()?, h.trim_end_matches('i').parse().ok()?))
}

/// 一帧 RGB，自上而下逐行。
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgb: Vec<u8>,
}

pub fn capture() -> io::Result<Frame> {
    let Some((card, crtc)) = active_crtc()? else { return Err(screen_off()) };
    if renders_on_host(&card) {
        return Err(io::Error::new(io::ErrorKind::Unsupported, "The guest's display is rendered on the host GPU (virgl), so it can't be read from inside the guest"));
    }
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
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "Couldn't read the framebuffer handle; the agent needs to run as root"));
    }
    if fb.flags & FB_MODIFIERS != 0 && fb.modifier[0] != FORMAT_MOD_LINEAR {
        return Err(io::Error::new(io::ErrorKind::Unsupported, format!("The framebuffer isn't linear (modifier {:#x})", fb.modifier[0])));
    }
    // 每像素 4 字节里 R、G、B 的位置。
    let (r, g, b) = match fb.pixel_format {
        f if f == fourcc(b"XR24") || f == fourcc(b"AR24") => (2, 1, 0),
        f if f == fourcc(b"XB24") || f == fourcc(b"AB24") => (0, 1, 2),
        f => {
            let name = String::from_utf8_lossy(&f.to_le_bytes()).into_owned();
            return Err(io::Error::new(io::ErrorKind::Unsupported, format!("Unsupported framebuffer format {name}")));
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
        return Err(io::Error::new(io::ErrorKind::InvalidData, "The framebuffer is smaller than the display mode"));
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
    fn parses_sysfs_modes() {
        assert_eq!(parse_mode("2400x1496"), Some((2400, 1496)));
        assert_eq!(parse_mode("1920x1080i"), Some((1920, 1080)));
        assert_eq!(parse_mode("bogus"), None);
    }

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
        assert_eq!(size_of::<Version>(), 64);
        assert_eq!(VERSION, 0xC040_6400);
        assert_eq!(VIRTGPU_GETPARAM, 0xC010_6443);
        assert_eq!(fourcc(b"XR24"), 0x3432_5258);
    }
}
