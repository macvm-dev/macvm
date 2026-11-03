//! virtio-gpu 的驱动：在场设备的枚举，以及 3D 驱动 viogpu3d 的安装。
//!
//! 宿主把 viogpu3d 驱动包放在 `GPU_DRIVER_DIR`；代理在 QEMU 下开机时把它装到在场的 virtio-gpu 上，
//! 3D 经 virglrenderer 在宿主 GPU 上执行。VZ 的 virtio-gpu 没有 3D，换上 viogpu3d 开机即崩溃，
//! 所以只装在场的设备，不像 `pnputil /install` 那样给不在场的同型号实例也标上「下次出现时重装」。

use std::io;
use std::mem::size_of;
use std::path::Path;
use std::ptr;

use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
    DICS_FLAG_GLOBAL, DIGCF_PRESENT, DIREG_DRV, GUID_DEVCLASS_DISPLAY, HDEVINFO, INSTALLFLAG_FORCE, SP_DEVINFO_DATA, SPDRP_HARDWAREID,
    SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInfo, SetupDiGetClassDevsW, SetupDiGetDeviceInstanceIdW,
    SetupDiGetDeviceRegistryPropertyW, SetupDiOpenDevRegKey, UpdateDriverForPlugAndPlayDevicesW,
};
use windows_sys::Win32::Foundation::{GetLastError, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_LOCAL_MACHINE, KEY_QUERY_VALUE, RRF_RT_REG_SZ, RegCloseKey, RegGetValueW, RegQueryValueExW,
};

use super::wide;

/// 宿主放 viogpu3d 驱动包（含 `viogpu3d.inf`）的目录。
pub const GPU_DRIVER_DIR: &str = r"C:\ProgramData\macvm\viogpu3d";
/// virtio-gpu 的 PCI 厂商与设备号。
const VIRTIO_GPU: &str = "VEN_1AF4&DEV_1050";
/// VZ 的 SMBIOS 制造商。
const VZ_MANUFACTURER: &str = "Apple Inc.";

/// 是否在 VZ 下运行。
pub(super) fn on_vz() -> bool {
    let mut buf = [0u16; 256];
    let mut bytes = (buf.len() * 2) as u32;
    // SAFETY: 缓冲区与长度（字节）一致。
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            wide(r"HARDWARE\DESCRIPTION\System\BIOS").as_ptr(),
            wide("SystemManufacturer").as_ptr(),
            RRF_RT_REG_SZ,
            ptr::null_mut(),
            buf.as_mut_ptr().cast(),
            &mut bytes,
        )
    };
    status == 0 && String::from_utf16_lossy(&buf[..buf.iter().position(|&c| c == 0).unwrap_or(0)]) == VZ_MANUFACTURER
}

/// 对每块在场的 virtio-gpu 调用 `f`，传入设备信息集与设备。
pub(super) fn for_each_present_virtio_gpu(mut f: impl FnMut(HDEVINFO, &SP_DEVINFO_DATA)) {
    // SAFETY: 设备信息集在本函数内创建并销毁；缓冲区长度如实传入。
    unsafe {
        let set = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, ptr::null(), ptr::null_mut(), DIGCF_PRESENT);
        if set == INVALID_HANDLE_VALUE as isize || set == 0 {
            return;
        }
        for index in 0.. {
            let mut info: SP_DEVINFO_DATA = std::mem::zeroed();
            info.cbSize = size_of::<SP_DEVINFO_DATA>() as u32;
            if SetupDiEnumDeviceInfo(set, index, &mut info) == 0 {
                break;
            }
            let mut id = [0u16; 512];
            if SetupDiGetDeviceInstanceIdW(set, &info, id.as_mut_ptr(), id.len() as u32, ptr::null_mut()) != 0
                && String::from_utf16_lossy(&id).to_uppercase().contains(VIRTIO_GPU)
            {
                f(set, &info);
            }
        }
        SetupDiDestroyDeviceInfoList(set);
    }
}

/// 打开设备的驱动键；调用方负责 `RegCloseKey`。
pub(super) fn open_driver_key(set: HDEVINFO, info: &SP_DEVINFO_DATA, access: u32) -> Option<HKEY> {
    // SAFETY: set 与 info 来自同一次枚举。
    let key = unsafe { SetupDiOpenDevRegKey(set, info, DICS_FLAG_GLOBAL, 0, DIREG_DRV, access) };
    (!key.is_null() && !ptr::eq(key, INVALID_HANDLE_VALUE as _)).then_some(key)
}

/// 驱动键所属的驱动是否带用户态驱动（Direct3D），即 viogpu3d：只有它在驱动键下登记 UserModeDriverName，viogpudo 没有。
pub(super) fn is_3d_driver(key: HKEY) -> bool {
    // SAFETY: 只查询值是否存在，不读数据。
    unsafe { RegQueryValueExW(key, wide("UserModeDriverName").as_ptr(), ptr::null(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut()) == 0 }
}

/// QEMU 下有驱动包时，把在场且还没用上这个包的 virtio-gpu 换成它；返回是否换了。以宿主带的包为准，
/// 比已装的旧也强制换上：驱动要与宿主的图形栈配套。
/// 换上后画面立即由它驱动，桌面合成改用 GPU 要等下次开机。
pub fn install_gpu_driver() -> io::Result<bool> {
    let inf = Path::new(GPU_DRIVER_DIR).join("viogpu3d.inf");
    if on_vz() {
        return Ok(false);
    }
    let Ok(package) = std::fs::read(&inf) else { return Ok(false) };
    let mut pending = Vec::new();
    for_each_present_virtio_gpu(|set, info| {
        if let Some(key) = open_driver_key(set, info, KEY_QUERY_VALUE) {
            let current = installed_inf(key);
            // SAFETY: 键由 open_driver_key 打开，只关一次。
            unsafe { RegCloseKey(key) };
            if current.as_deref() == Some(package.as_slice()) {
                return;
            }
        }
        if let Some(id) = hardware_id(set, info) {
            pending.push(id);
        }
    });
    let inf = wide(&inf.to_string_lossy());
    let mut changed = false;
    for id in &pending {
        let mut reboot = 0;
        // SAFETY: 字符串以 NUL 结尾；只影响在场且硬件号相同的设备。
        if unsafe { UpdateDriverForPlugAndPlayDevicesW(ptr::null_mut(), wide(id).as_ptr(), inf.as_ptr(), INSTALLFLAG_FORCE, &mut reboot) } == 0 {
            return Err(io::Error::from_raw_os_error(unsafe { GetLastError() } as i32));
        }
        changed = true;
    }
    if changed {
        super::cursor::hardware_cursor_lost();
    }
    Ok(changed)
}

/// 设备当前驱动的 INF 内容。Windows 安装驱动时把 INF 原样复制为 `%windir%\INF` 下的 oemN.inf，驱动键的 InfPath 记着文件名。
fn installed_inf(key: HKEY) -> Option<Vec<u8>> {
    let mut name = [0u16; 64];
    let mut bytes = (name.len() * 2) as u32;
    // SAFETY: 缓冲区与长度（字节）一致。
    let status = unsafe {
        RegQueryValueExW(key, wide("InfPath").as_ptr(), ptr::null(), ptr::null_mut(), name.as_mut_ptr().cast(), &mut bytes)
    };
    if status != 0 {
        return None;
    }
    let name = String::from_utf16_lossy(&name[..name.iter().position(|&c| c == 0).unwrap_or(name.len())]);
    let windows = std::env::var_os("SystemRoot")?;
    std::fs::read(Path::new(&windows).join("INF").join(name)).ok()
}

/// 设备的第一个硬件号（最具体的那个，含子系统号与版本）。
fn hardware_id(set: HDEVINFO, info: &SP_DEVINFO_DATA) -> Option<String> {
    let mut buf = [0u16; 1024];
    // SAFETY: 缓冲区长度按字节传入。
    let ok = unsafe {
        SetupDiGetDeviceRegistryPropertyW(set, info, SPDRP_HARDWAREID, ptr::null_mut(), buf.as_mut_ptr().cast(), (buf.len() * 2) as u32, ptr::null_mut())
    };
    if ok == 0 {
        return None;
    }
    let end = buf.iter().position(|&c| c == 0).unwrap_or(0);
    (end > 0).then(|| String::from_utf16_lossy(&buf[..end]))
}
