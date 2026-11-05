// SPICE 画面视图：CocoaSpice 负责协议与 Metal 渲染，这里只把它接到 MacVMDisplay.h 的 C 接口上。
// CocoaSpice 的回调来自 glib 线程，一律转到主线程处理。
@import AppKit;
@import MetalKit;
#import <objc/message.h>
#import <spice-client.h>
#import "CocoaSpice.h"
@import CocoaSpiceRenderer;
#import "MacVMDisplay.h"

// 设了 MACVM_SPICE_DEBUG 才输出；没设时参数不求值，可以放在每帧都走的路径上。
static BOOL debug_enabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = getenv("MACVM_SPICE_DEBUG") != NULL; });
    return enabled;
}

#define debug_log(format, ...) do { \
    if (debug_enabled()) { \
        fprintf(stderr, "[MacVMDisplay] %s\n", [NSString stringWithFormat:format, ##__VA_ARGS__].UTF8String); \
    } \
} while (0)

/// 宿主剪贴板与一个 SPICE 会话之间只传文本，每个会话一个。CocoaSpice 在 glib 线程上调用这些方法，NSPasteboard 可在任意线程使用。
@interface MacVMPasteboard : NSObject <CSPasteboardDelegate>
/// 宿主剪贴板里有文本、且自本会话上次同步后变过（`force` 时不论变没变）时，通知各会话交给客户机。
- (void)offer:(BOOL)force;
@end

@implementation MacVMPasteboard {
    /// 上次交给本会话的客户机或从它写入时宿主剪贴板的 changeCount。
    NSInteger _syncedChangeCount;
}

- (instancetype)init {
    if ((self = [super init])) {
        _syncedChangeCount = -1;
    }
    return self;
}

- (void)offer:(BOOL)force {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    @synchronized (self) {
        if (!force && pasteboard.changeCount == _syncedChangeCount) {
            return;
        }
        _syncedChangeCount = pasteboard.changeCount;
    }
    if ([pasteboard stringForType:NSPasteboardTypeString]) {
        [NSNotificationCenter.defaultCenter postNotificationName:kCSPasteboardChangedNotification object:nil];
    }
}

- (BOOL)canReadItemForType:(CSPasteboardType)type {
    return type == kCSPasteboardTypeString && [self string] != nil;
}

- (NSData *)dataForType:(CSPasteboardType)type {
    return type == kCSPasteboardTypeString ? [[self string] dataUsingEncoding:NSUTF8StringEncoding] : nil;
}

- (void)setData:(NSData *)data forType:(CSPasteboardType)type {}

- (NSString *)string {
    return [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
}

- (void)setString:(NSString *)string {
    // 客户机清空剪贴板时宿主的内容留着。
    if (string.length == 0) {
        return;
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    @synchronized (self) {
        [pasteboard clearContents];
        [pasteboard setString:string forType:NSPasteboardTypeString];
        _syncedChangeCount = pasteboard.changeCount;
    }
}

// 客户机放弃剪贴板（如复制内容的程序退出）时宿主的内容留着。
- (void)clearContents {}

@end

@interface MacVMSpiceView : MTKView <CSConnectionDelegate, MTKViewDelegate>
@property (nonatomic) MacVMDisplayHandler handler;
@property (nonatomic) MacVMDisplayCursorHandler cursorHandler;
@property (nonatomic) void *context;
@end

@implementation MacVMSpiceView {
    CSConnection *_connection;
    /// 会话只弱引用剪贴板代理，由视图持有。
    MacVMPasteboard *_pasteboard;
    CSMetalRenderer *_renderer;
    CSDisplay *_display;
    CSInput *_input;
    BOOL _showsGuestCursor;
    BOOL _frozen;
    BOOL _freezeOnResize;
    CGSize _freezeFromSize;
    /// 冻结期间最近一次有新帧要画的时间。
    CFTimeInterval _lastFrozenFrame;
    NSTimer *_thawTimer;
}

- (instancetype)initWithSocket:(NSURL *)socket {
    if (!(self = [super initWithFrame:NSZeroRect device:MTLCreateSystemDefaultDevice()])) {
        return nil;
    }
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    // 有新帧才画（渲染器随即请求重绘），不按刷新率轮询：新帧不必等下一个节拍，空闲时也不占 CPU。
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    // 窗口里的画面本来就由系统合成器按刷新率合成，图层不必再等垂直同步、也不必多排一张，
    // 客户机画的光标因此少落后一到两帧。
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.maximumDrawableCount = 2;
    layer.displaySyncEnabled = NO;
    _renderer = [[CSMetalRenderer alloc] initWithMetalKitView:self];
    self.delegate = self;
    _showsGuestCursor = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 设了 MACVM_SPICE_DEBUG 时把 SPICE 的调试日志写到标准错误。
        if (getenv("MACVM_SPICE_DEBUG")) {
            CSMain.sharedInstance.logHandler = ^(NSString *line) { fprintf(stderr, "%s", line.UTF8String); };
            [CSMain.sharedInstance spiceSetDebug:YES];
        }
        [CSMain.sharedInstance spiceStart];
    });
    _connection = [[CSConnection alloc] initWithUnixSocketFile:socket];
    _connection.delegate = self;
    _connection.audioEnabled = NO;
    _pasteboard = [[MacVMPasteboard alloc] init];
    _connection.session.pasteboardDelegate = _pasteboard;
    // spice-gtk 只在有 EGL 时默认声明能收 GL scanout；不声明，服务端会改走视频编码（这里没有编码器）而不共享 IOSurface。
    SpiceSession *session = ((SpiceSession *(*)(id, SEL))objc_msgSend)(_connection, NSSelectorFromString(@"spiceSession"));
    g_object_set(session, "gl-scanout", TRUE, NULL);
    [_connection connect];
    return self;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)close {
    [_thawTimer invalidate];
    _thawTimer = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _handler = NULL;
    _cursorHandler = NULL;
    _connection.delegate = nil;
    [_connection disconnect];
    [self detachDisplay];
    _input = nil;
}

- (void)emit:(int)event size:(CGSize)size {
    if (_handler) {
        _handler(_context, event, size.width, size.height);
    }
}

- (void)fitDisplay {
    [self fitDisplayInto:self.drawableSize];
}

// 按比例缩放进视图；渲染器以视图中心为原点。
- (void)fitDisplayInto:(CGSize)drawable {
    if (!_display) {
        return;
    }
    CGSize guest = _display.displaySize;
    if (guest.width > 0 && guest.height > 0 && drawable.width > 0 && drawable.height > 0) {
        _renderer.viewportScale = MIN(drawable.width / guest.width, drawable.height / guest.height);
        debug_log(@"fit: guest %@ drawable %@ scale %f", NSStringFromSize(guest), NSStringFromSize(drawable), _renderer.viewportScale);
        _renderer.viewportOrigin = CGPointZero;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != self->_display) {
            return;
        }
        [self fitDisplay];
        [self emit:MacVMDisplayEventResized size:self->_display.displaySize];
    });
}

- (void)detachDisplay {
    if (!_display) {
        return;
    }
    [_display removeObserver:self forKeyPath:@"displaySize"];
    [_display removeRenderer:_renderer];
    _display.cursor.shapeHandler = nil;
    _display = nil;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidEnterFullScreenNotification object:nil];
    [center removeObserver:self name:NSWindowDidExitFullScreenNotification object:nil];
    [center removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    if (self.window) {
        // 宿主剪贴板在窗口成为主窗口时交给客户机；客户机的剪贴板一变，SPICE 就送回宿主。
        [center addObserver:self selector:@selector(offerPasteboard) name:NSWindowDidBecomeKeyNotification object:self.window];
        [center addObserver:self selector:@selector(updateDisplaySync) name:NSWindowDidEnterFullScreenNotification object:self.window];
        [center addObserver:self selector:@selector(updateDisplaySync) name:NSWindowDidExitFullScreenNotification object:self.window];
    }
    [self updateDisplaySync];
}

- (void)offerPasteboard {
    [_pasteboard offer:NO];
}

// 全屏时系统可能让画面跳过合成器直接上屏，不等垂直同步就会撕裂。
- (void)updateDisplaySync {
    BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    ((CAMetalLayer *)self.layer).displaySyncEnabled = fullScreen;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self fitDisplay];
}

- (void)setFrozen:(BOOL)frozen {
    [_thawTimer invalidate];
    _thawTimer = nil;
    _frozen = frozen;
    _freezeOnResize = NO;
    if (!frozen) {
        self.needsDisplay = YES;
    }
}

- (void)thawWhenIdle:(CFTimeInterval)idle limit:(CFTimeInterval)limit {
    if (!_frozen) {
        [self setFrozen:NO];
        return;
    }
    [_thawTimer invalidate];
    CFTimeInterval deadline = CACurrentMediaTime() + limit;
    _lastFrozenFrame = CACurrentMediaTime();
    __weak MacVMSpiceView *weakSelf = self;
    _thawTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        MacVMSpiceView *view = weakSelf;
        CFTimeInterval now = CACurrentMediaTime();
        if (!view || now - view->_lastFrozenFrame >= idle || now >= deadline) {
            [view setFrozen:NO];
            [timer invalidate];
        }
    }];
}

- (void)freezeOnResize {
    _freezeOnResize = YES;
    _freezeFromSize = _display.displaySize;
}

#pragma mark - MTKViewDelegate

// 渲染器的待画标记在跳过时保留，解冻后的那次绘制会画上最新一帧。
// 尺寸在新尺寸的帧画出之前就已更新，所以绘制时比较尺寸，新尺寸的第一帧也不会漏出来。
- (void)drawInMTKView:(MTKView *)view {
    if (_freezeOnResize && !CGSizeEqualToSize(_display.displaySize, _freezeFromSize)) {
        _freezeOnResize = NO;
        _frozen = YES;
    }
    if (_frozen) {
        _lastFrozenFrame = CACurrentMediaTime();
    } else {
        [_renderer drawInMTKView:view];
    }
}

// 换到缩放倍数不同的屏幕时视图点数不变、像素变了，缩放比例要跟着重算。
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer mtkView:view drawableSizeWillChange:size];
    [self fitDisplayInto:size];
}

- (void)setShowsGuestCursor:(BOOL)shows {
    _showsGuestCursor = shows;
    _display.cursor.isInhibited = !shows;
}

- (void)setCursorHandler:(MacVMDisplayCursorHandler)cursorHandler {
    _cursorHandler = cursorHandler;
    [self watchCursorOf:_display];
}

/// 光标形状在 SPICE 线程上送来，拷一份转到主线程；换了画面或关闭后到的旧形状丢掉。
- (void)watchCursorOf:(CSDisplay *)display {
    if (!display || !_cursorHandler) {
        return;
    }
    // 块存在 display 的光标里，弱引用 display 免得循环引用。
    __weak MacVMSpiceView *weakSelf = self;
    __weak CSDisplay *weakDisplay = display;
    display.cursor.shapeHandler = ^(NSData *bgra, CGSize size, CGPoint hotspot) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MacVMSpiceView *view = weakSelf;
            CSDisplay *current = weakDisplay;
            if (!view || !current || view->_display != current || !view->_cursorHandler) {
                return;
            }
            view->_cursorHandler(view->_context, bgra.bytes, (int)size.width, (int)size.height, (int)hotspot.x, (int)hotspot.y);
        });
    };
}

#pragma mark - 输入

- (void)key:(int)scancode down:(BOOL)down {
    [_input sendKey:down ? kCSInputKeyPress : kCSInputKeyRelease code:scancode];
}

- (void)pointerX:(double)x y:(double)y buttons:(uint32_t)buttons {
    if (!_input || !_display) {
        return;
    }
    [_input sendMousePosition:(CSInputButton)buttons absolutePoint:CGPointMake(x, y) forMonitorID:_display.monitorID];
    [_display.cursor moveTo:CGPointMake(x, y)];
}

- (void)scrollUp:(BOOL)up buttons:(uint32_t)buttons {
    [_input sendMouseScroll:up ? kCSInputScrollUp : kCSInputScrollDown buttonMask:(CSInputButton)buttons dy:0];
}

#pragma mark - CSConnectionDelegate

- (void)spiceConnected:(CSConnection *)connection {
    dispatch_async(dispatch_get_main_queue(), ^{ [self emit:MacVMDisplayEventConnected size:CGSizeZero]; });
}

- (void)spiceDisconnected:(CSConnection *)connection {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self detachDisplay];
        self->_input = nil;
        [self emit:MacVMDisplayEventDisconnected size:CGSizeZero];
    });
}

- (void)spiceError:(CSConnection *)connection code:(CSConnectionError)code message:(NSString *)message {
    [self spiceDisconnected:connection];
}

- (void)spiceInputAvailable:(CSConnection *)connection input:(CSInput *)input {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_input = input; });
}

- (void)spiceInputUnavailable:(CSConnection *)connection input:(CSInput *)input {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_input == input) {
            self->_input = nil;
        }
    });
}

- (void)spiceDisplayCreated:(CSConnection *)connection display:(CSDisplay *)display {
    dispatch_async(dispatch_get_main_queue(), ^{
        debug_log(@"display created: monitor %ld primary %d size %@ frame %@ drawable %@", (long)display.monitorID, display.isPrimaryDisplay,
                  NSStringFromSize(display.displaySize), NSStringFromRect(self.frame), NSStringFromSize(self.drawableSize));
        if (!display.isPrimaryDisplay || self->_display) {
            return;
        }
        self->_display = display;
        display.cursor.isInhibited = !self->_showsGuestCursor;
        [self watchCursorOf:display];
        // 尺寸在 SPICE 线程上随 scanout 与显示器配置变化，不一定伴随 spiceDisplayUpdated。
        [display addObserver:self forKeyPath:@"displaySize" options:0 context:NULL];
        [display addRenderer:self->_renderer];
        [self fitDisplay];
        [self emit:MacVMDisplayEventResized size:display.displaySize];
    });
}

- (void)spiceDisplayUpdated:(CSConnection *)connection display:(CSDisplay *)display {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (display != self->_display) {
            return;
        }
        display.cursor.isInhibited = !self->_showsGuestCursor;
        [self fitDisplay];
        [self emit:MacVMDisplayEventResized size:display.displaySize];
    });
}

- (void)spiceDisplayDestroyed:(CSConnection *)connection display:(CSDisplay *)display {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (display == self->_display) {
            [self detachDisplay];
        }
    });
}

// 客户机代理（重新）连上时它的剪贴板是空的，宿主剪贴板没变也要给一次。
- (void)spiceAgentConnected:(CSConnection *)connection supportingFeatures:(CSConnectionAgentFeature)features {
    MacVMPasteboard *pasteboard = _pasteboard;
    dispatch_async(dispatch_get_main_queue(), ^{ [pasteboard offer:YES]; });
}
- (void)spiceAgentDisconnected:(CSConnection *)connection {}
- (void)spiceForwardedPortOpened:(CSConnection *)connection port:(CSPort *)port {}
- (void)spiceForwardedPortClosed:(CSConnection *)connection port:(CSPort *)port {}

@end

#pragma mark - C 接口

// CocoaSpice 启动时调用它注册静态链接的 GStreamer 插件；这里不用 GStreamer 播放任何东西。
void gst_ios_init(void) {}

static MacVMSpiceView *view_of(void *view) {
    return (__bridge MacVMSpiceView *)view;
}

void *MacVMDisplayCreate(const char *socketPath, MacVMDisplayHandler handler, void *context) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:socketPath]];
    MacVMSpiceView *view = [[MacVMSpiceView alloc] initWithSocket:url];
    view.handler = handler;
    view.context = context;
    return (__bridge_retained void *)view;
}

void MacVMDisplayClose(void *view) {
    [view_of(view) close];
}

void MacVMDisplayKey(void *view, int scancode, bool down) {
    [view_of(view) key:scancode down:down];
}

void MacVMDisplayPointer(void *view, double x, double y, uint32_t buttons) {
    [view_of(view) pointerX:x y:y buttons:buttons];
}

void MacVMDisplayScroll(void *view, bool up, uint32_t buttons) {
    [view_of(view) scrollUp:up buttons:buttons];
}

void MacVMDisplayShowGuestCursor(void *view, bool shows) {
    [view_of(view) setShowsGuestCursor:shows];
}

void MacVMDisplaySetCursorHandler(void *view, MacVMDisplayCursorHandler handler) {
    view_of(view).cursorHandler = handler;
}

void MacVMDisplaySetFrozen(void *view, bool frozen) {
    [view_of(view) setFrozen:frozen];
}

void MacVMDisplayFreezeOnResize(void *view) {
    [view_of(view) freezeOnResize];
}

void MacVMDisplayThawWhenIdle(void *view, double idle, double limit) {
    [view_of(view) thawWhenIdle:idle limit:limit];
}
