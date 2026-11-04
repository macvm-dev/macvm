//! 桌面显示器的缩放比例。Windows 没有公开设置它的 API；`DisplayConfigGetDeviceInfo` 与
//! `DisplayConfigSetDeviceInfo` 的未公开类型 -3（读）与 -4（写）就是「设置 › 显示 › 缩放」所用的接口，
//! 比例以相对「推荐」档位的偏移表示，写入后立即生效并按显示器记住。

use std::io;
use std::mem::{size_of, zeroed};

use windows_sys::Win32::Devices::Display::{DISPLAYCONFIG_DEVICE_INFO_HEADER, DisplayConfigGetDeviceInfo, DisplayConfigSetDeviceInfo};

use super::display::{active_config, win32};

/// 设置界面里的档位（百分比），偏移按这个表计算。
const SCALES: [u32; 12] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];
const GET_DPI_SCALE: i32 = -3;
const SET_DPI_SCALE: i32 = -4;

#[repr(C)]
struct DpiScaleGet {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    /// 100% 相对推荐档位的偏移（≤ 0）。
    minimum: i32,
    current: i32,
    maximum: i32,
}

#[repr(C)]
struct DpiScaleSet {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    relative: i32,
}

/// 把所有在用的显示器设为不超过 `percent` 的最接近档位；超出该显示器允许的范围时取边界。
pub fn set_display_scale(percent: u32) -> io::Result<()> {
    let target = SCALES.iter().rposition(|&s| s <= percent).unwrap_or(0) as i32;
    let (paths, _) = active_config()?;
    // SAFETY: 两个结构体都以 header 开头，size 如实填写。
    unsafe {
        for path in &paths {
            let mut get: DpiScaleGet = zeroed();
            get.header.r#type = GET_DPI_SCALE;
            get.header.size = size_of::<DpiScaleGet>() as u32;
            get.header.adapterId = path.sourceInfo.adapterId;
            get.header.id = path.sourceInfo.id;
            win32(DisplayConfigGetDeviceInfo(&mut get.header))?;
            // 档位 0（100%）对应偏移 minimum，所以推荐档位是 -minimum。
            let relative = (target + get.minimum).clamp(get.minimum, get.maximum);
            if relative == get.current {
                continue;
            }
            let mut set: DpiScaleSet = zeroed();
            set.header = get.header;
            set.header.r#type = SET_DPI_SCALE;
            set.header.size = size_of::<DpiScaleSet>() as u32;
            set.relative = relative;
            win32(DisplayConfigSetDeviceInfo(&set.header))?;
        }
    }
    Ok(())
}
