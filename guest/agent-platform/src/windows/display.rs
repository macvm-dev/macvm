//! 让 virtio-gpu 成为唯一的桌面显示器，并取宿主给的分辨率。
//!
//! VZ 下引导垫片交给 Windows 的内存帧缓冲会成为另一块显示器，宿主看不到它，却常被选为主显示器。
//! 任意尺寸的做法与 virtio-win 的 viogpures 相同：先经驱动的 escape 接口设定自定义模式，再用
//! `SetDisplayConfig`（允许系统调整）提交只含 virtio-gpu 的显示拓扑；`ChangeDisplaySettingsEx`
//! 按 Windows 缓存的模式列表校验，会拒绝新尺寸。

use std::io;
use std::mem::{size_of, zeroed};
use std::ptr;

use windows_sys::Wdk::Graphics::Direct3D::{
    D3DKMT_CLOSEADAPTER, D3DKMT_ESCAPE, D3DKMT_ESCAPE_DRIVERPRIVATE, D3DKMT_OPENADAPTERFROMHDC, D3DKMTCloseAdapter, D3DKMTEscape,
    D3DKMTOpenAdapterFromHdc,
};
use windows_sys::Win32::Devices::Display::{
    DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE, DISPLAYCONFIG_PATH_INFO, GetDisplayConfigBufferSizes,
    QDC_ONLY_ACTIVE_PATHS, QueryDisplayConfig, SDC_ALLOW_CHANGES, SDC_APPLY, SDC_SAVE_TO_DATABASE, SDC_USE_SUPPLIED_DISPLAY_CONFIG,
    SetDisplayConfig,
};
use windows_sys::Win32::Foundation::LUID;
use windows_sys::Win32::Graphics::Gdi::{
    CreateDCW, DISPLAY_DEVICE_ATTACHED_TO_DESKTOP, DISPLAY_DEVICE_PRIMARY_DEVICE, DISPLAY_DEVICEW, DEVMODEW, DeleteDC,
    ENUM_CURRENT_SETTINGS, EnumDisplayDevicesW, EnumDisplaySettingsW,
};

use super::{VIRTIO_GPU, until_nul};

/// 只用 virtio-gpu 作主显示器、取 `width`×`height`，卸下其他显示器，并写入显示配置数据库。
/// 驱动可能把过小的尺寸放大到它的下限，实际取驱动接受的尺寸。
pub fn set_display(width: u32, height: u32) -> io::Result<()> {
    let list = adapters();
    let virtio = list.iter().find(|a| a.virtio).ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No virtio-gpu display found"))?;
    let others_attached = list.iter().any(|a| !a.virtio && a.flags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP != 0);
    let current = current_size(&virtio.name);
    if virtio.flags & DISPLAY_DEVICE_PRIMARY_DEVICE != 0 && !others_attached && current == Some((width, height)) {
        return Ok(());
    }
    let adapter = Adapter::open(&virtio.name)?;
    let (width, height) = adapter.set_custom_resolution(width, height)?;
    apply_only(adapter.luid, adapter.source_id, width, height)
}

/// 提交只含 (`luid`, `source`) 这一路输出的拓扑，其余输出随之关闭；该输出放在原点即为主显示器。
fn apply_only(luid: LUID, source: u32, width: u32, height: u32) -> io::Result<()> {
    let (paths, mut modes) = active_config()?;
    // SAFETY: 联合体按 infoType 与 QueryDisplayConfig 的约定访问；模式数组的长度如实传入。
    unsafe {
        let path = paths
            .iter()
            .find(|p| same_luid(p.sourceInfo.adapterId, luid) && p.sourceInfo.id == source)
            .copied()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "The virtio-gpu display isn't part of the desktop"))?;
        let index = path.sourceInfo.Anonymous.modeInfoIdx as usize;
        let mode = modes.get_mut(index).filter(|m| m.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE)
            .ok_or_else(|| io::Error::other("Couldn't find the virtio-gpu source mode"))?;
        mode.Anonymous.sourceMode.width = width;
        mode.Anonymous.sourceMode.height = height;
        mode.Anonymous.sourceMode.position.x = 0;
        mode.Anonymous.sourceMode.position.y = 0;
        win32(SetDisplayConfig(1, &path, modes.len() as u32, modes.as_ptr(), SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE))
    }
}

/// 在用的显示路径与模式。
pub(super) fn active_config() -> io::Result<(Vec<DISPLAYCONFIG_PATH_INFO>, Vec<DISPLAYCONFIG_MODE_INFO>)> {
    // SAFETY: 缓冲区按 GetDisplayConfigBufferSizes 的结果分配，QueryDisplayConfig 写回实际条数。
    unsafe {
        let (mut path_count, mut mode_count) = (0u32, 0u32);
        win32(GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count) as i32)?;
        let mut paths = vec![zeroed::<DISPLAYCONFIG_PATH_INFO>(); path_count as usize];
        let mut modes = vec![zeroed::<DISPLAYCONFIG_MODE_INFO>(); mode_count as usize];
        win32(QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut path_count, paths.as_mut_ptr(), &mut mode_count, modes.as_mut_ptr(), ptr::null_mut()) as i32)?;
        paths.truncate(path_count as usize);
        modes.truncate(mode_count as usize);
        Ok((paths, modes))
    }
}

/// Win32 错误码转成 `io::Result`。
pub(super) fn win32(code: i32) -> io::Result<()> {
    if code == 0 { Ok(()) } else { Err(io::Error::from_raw_os_error(code)) }
}

fn same_luid(a: LUID, b: LUID) -> bool {
    a.LowPart == b.LowPart && a.HighPart == b.HighPart
}

const VIOGPU_GET_CUSTOM_RESOLUTION: u16 = 0x01;
const VIOGPU_SET_CUSTOM_RESOLUTION: u16 = 0x02;

/// viogpudo 的 escape 数据（`VIOGPU_ESCAPE`，1 字节对齐）。
#[repr(C, packed)]
#[derive(Clone, Copy, Default)]
struct ViogpuEscape {
    kind: u16,
    data_length: u16,
    width: u16,
    height: u16,
}

/// 打开的内核态显示适配器句柄，析构时关闭。
struct Adapter {
    handle: u32,
    luid: LUID,
    source_id: u32,
}

impl Adapter {
    fn open(device: &[u16]) -> io::Result<Self> {
        // SAFETY: 设备名以 NUL 结尾；打开适配器后 DC 即可释放。
        unsafe {
            let dc = CreateDCW(ptr::null(), device.as_ptr(), ptr::null(), ptr::null());
            if dc.is_null() {
                return Err(io::Error::last_os_error());
            }
            let mut open: D3DKMT_OPENADAPTERFROMHDC = zeroed();
            open.hDc = dc;
            let status = D3DKMTOpenAdapterFromHdc(&mut open);
            DeleteDC(dc);
            if status < 0 {
                return Err(io::Error::other(format!("Couldn't open the display adapter (NTSTATUS {status:#x})")));
            }
            Ok(Self { handle: open.hAdapter, luid: open.AdapterLuid, source_id: open.VidPnSourceId })
        }
    }

    fn escape(&self, data: &mut ViogpuEscape) -> io::Result<()> {
        // SAFETY: escape 数据在调用期间有效，大小与驱动约定的结构一致。
        let status = unsafe {
            let mut request: D3DKMT_ESCAPE = zeroed();
            request.hAdapter = self.handle;
            request.Type = D3DKMT_ESCAPE_DRIVERPRIVATE;
            request.pPrivateDriverData = (data as *mut ViogpuEscape).cast();
            request.PrivateDriverDataSize = size_of::<ViogpuEscape>() as u32;
            D3DKMTEscape(&request)
        };
        if status < 0 { Err(io::Error::other(format!("The display driver rejected the request (NTSTATUS {status:#x})"))) } else { Ok(()) }
    }

    /// 设定驱动的自定义模式，返回驱动实际采用的尺寸。
    fn set_custom_resolution(&self, width: u32, height: u32) -> io::Result<(u32, u32)> {
        let to_u16 = |v: u32| u16::try_from(v).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput));
        let data_length = 2 * size_of::<u16>() as u16;
        self.escape(&mut ViogpuEscape { kind: VIOGPU_SET_CUSTOM_RESOLUTION, data_length, width: to_u16(width)?, height: to_u16(height)? })?;
        let mut applied = ViogpuEscape { kind: VIOGPU_GET_CUSTOM_RESOLUTION, data_length, ..Default::default() };
        self.escape(&mut applied)?;
        Ok((u32::from(applied.width), u32::from(applied.height)))
    }
}

impl Drop for Adapter {
    fn drop(&mut self) {
        // SAFETY: 句柄由 open 取得，只关闭一次。
        unsafe { D3DKMTCloseAdapter(&D3DKMT_CLOSEADAPTER { hAdapter: self.handle }) };
    }
}

struct DisplayDevice {
    name: Vec<u16>,
    flags: u32,
    virtio: bool,
}

fn adapters() -> Vec<DisplayDevice> {
    let mut out = Vec::new();
    for i in 0.. {
        // SAFETY: 结构体按约定先填 cb，API 只写入该结构体。
        let mut dd: DISPLAY_DEVICEW = unsafe { zeroed() };
        dd.cb = size_of::<DISPLAY_DEVICEW>() as u32;
        if unsafe { EnumDisplayDevicesW(ptr::null(), i, &mut dd, 0) } == 0 {
            break;
        }
        let id = String::from_utf16_lossy(until_nul(&dd.DeviceID)).to_uppercase();
        out.push(DisplayDevice { name: until_nul(&dd.DeviceName).iter().copied().chain([0]).collect(), flags: dd.StateFlags, virtio: id.contains(VIRTIO_GPU) });
    }
    out
}

fn current_size(name: &[u16]) -> Option<(u32, u32)> {
    // SAFETY: 先填 dmSize；设备名以 NUL 结尾。
    let mut dm: DEVMODEW = unsafe { zeroed() };
    dm.dmSize = size_of::<DEVMODEW>() as u16;
    (unsafe { EnumDisplaySettingsW(name.as_ptr(), ENUM_CURRENT_SETTINGS, &mut dm) } != 0).then_some((dm.dmPelsWidth, dm.dmPelsHeight))
}

