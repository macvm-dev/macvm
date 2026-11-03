// libMacVMDisplay 的 C 接口：App 用 dlopen 加载，不链接 glib 与 SPICE。
// 所有函数都在主线程调用；事件回调也在主线程。
#pragma once
#include <stdbool.h>
#include <stdint.h>

/// 连上与断开时 `width`、`height` 为零；画面尺寸变化时为客户机像素尺寸。
enum {
    MacVMDisplayEventConnected = 1,
    MacVMDisplayEventDisconnected = 2,
    MacVMDisplayEventResized = 3,
};
typedef void (*MacVMDisplayHandler)(void *context, int event, double width, double height);

/// 返回一个已持有（+1）的 NSView，连接 `socketPath` 上的 SPICE 并用 Metal 按比例居中显示画面。
/// 视图不接收鼠标事件（hitTest 返回 nil），键鼠由宿主视图经下列函数转发。
void *MacVMDisplayCreate(const char *socketPath, MacVMDisplayHandler handler, void *context);
/// 断开连接，之后不再回调；视图仍需调用方释放。
void MacVMDisplayClose(void *view);
/// `scancode` 为第 1 套扫描码，E0 前缀键为 0x100 | 第二字节。
void MacVMDisplayKey(void *view, int scancode, bool down);
/// 绝对位置，单位为客户机像素；`buttons` 各位：1 左键、2 中键、4 右键。
void MacVMDisplayPointer(void *view, double x, double y, uint32_t buttons);
/// `up` 为真时向上滚一格，否则向下。
void MacVMDisplayScroll(void *view, bool up, uint32_t buttons);
/// 是否把 SPICE 光标通道的光标画进画面（默认画）；宿主已用系统光标显示客户机光标时关掉。
void MacVMDisplayShowGuestCursor(void *view, bool shows);
/// 冻结时画面停在当前这一帧（窗口变大时拉伸显示），新帧照常接收确认、客户机不受阻；解冻立即画最新一帧。
void MacVMDisplaySetFrozen(void *view, bool frozen);
/// 画面尺寸下次变化时自动冻结，停在变化前的最后一帧，直到 `MacVMDisplaySetFrozen(view, false)`。
void MacVMDisplayFreezeOnResize(void *view);
