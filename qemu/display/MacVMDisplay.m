// SPICE 画面视图：CocoaSpice 负责协议与 Metal 渲染，这里只把它接到 MacVMDisplay.h 的 C 接口上。
// CocoaSpice 的回调来自 glib 线程，一律转到主线程处理。
@import AppKit;
@import MetalKit;
#import <objc/message.h>
#import <spice-client.h>
#import "CocoaSpice.h"
@import CocoaSpiceRenderer;
#import "MacVMDisplay.h"

static void debug_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void debug_log(NSString *format, ...) {
    if (!getenv("MACVM_SPICE_DEBUG")) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[MacVMDisplay] %s\n", line.UTF8String);
}

@interface MacVMSpiceView : MTKView <CSConnectionDelegate>
@property (nonatomic) MacVMDisplayHandler handler;
@property (nonatomic) void *context;
@end

@implementation MacVMSpiceView {
    CSConnection *_connection;
    CSMetalRenderer *_renderer;
    CSDisplay *_display;
    CSInput *_input;
    BOOL _showsGuestCursor;
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
    self.delegate = _renderer;
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
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _handler = NULL;
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

// 按比例缩放进视图；渲染器以视图中心为原点。
- (void)fitDisplay {
    if (!_display) {
        return;
    }
    CGSize guest = _display.displaySize, drawable = self.drawableSize;
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
    _display = nil;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidEnterFullScreenNotification object:nil];
    [center removeObserver:self name:NSWindowDidExitFullScreenNotification object:nil];
    if (self.window) {
        [center addObserver:self selector:@selector(updateDisplaySync) name:NSWindowDidEnterFullScreenNotification object:self.window];
        [center addObserver:self selector:@selector(updateDisplaySync) name:NSWindowDidExitFullScreenNotification object:self.window];
    }
    [self updateDisplaySync];
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

- (void)setShowsGuestCursor:(BOOL)shows {
    _showsGuestCursor = shows;
    _display.cursor.isInhibited = !shows;
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

- (void)spiceAgentConnected:(CSConnection *)connection supportingFeatures:(CSConnectionAgentFeature)features {}
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
