/*
 * monitorctl - tiny macOS utility (Apple silicon)
 *
 *   1. Put an external monitor into standby / wake it via DDC, leaving the
 *      USB-C link up so the monitor keeps charging the Mac.
 *   2. Stop drawing power from the adapter (run on battery) via the SMC (needs root).
 *   3. `menubar` mode: all of the above as a menu bar item. Sleeping the monitor also
 *      mirrors it onto the built-in screen so open windows stay reachable.
 *
 * Build:  make        (see the Makefile and README.md)
 *
 * Usage:
 *   monitorctl menubar                 run the menu bar app
 *   monitorctl [-d N] off | on         monitor standby / wake
 *   monitorctl [-d N] brightness [0-100]   get or set brightness
 *   monitorctl status                  show DDC brightness and adapter state
 *   sudo monitorctl adapter off|on     run on battery / draw from the adapter
 *
 * -d N picks the Nth external display (default 0) if you have more than one.
 *
 * NOTE: uses private Apple APIs (IOAVService) and undocumented SMC keys.
 * They can change between macOS versions. SMC settings revert on reboot.
 */

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <mach-o/dyld.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>

/* ------------------------------------------------------------------ */
/* DDC over IOAVService (private API, Apple silicon)                   */
/* ------------------------------------------------------------------ */

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset,
                                   void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress,
                                    void *inputBuffer, uint32_t inputBufferSize);

#define DDC_CHIP   0x37
#define DDC_DATA   0x51
#define VCP_BRIGHTNESS 0x10
#define VCP_POWER      0xD6

static IOAVServiceRef find_external(int index) {
    io_iterator_t it;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                 kIORegistryIterateRecursively, &it) != KERN_SUCCESS)
        return NULL;
    IOAVServiceRef found = NULL;
    int n = 0;
    io_registry_entry_t e;
    while (!found && (e = IOIteratorNext(it))) {
        io_name_t name;
        if (IORegistryEntryGetName(e, name) == KERN_SUCCESS && strcmp(name, "DCPAVServiceProxy") == 0) {
            CFTypeRef loc = IORegistryEntryCreateCFProperty(e, CFSTR("Location"), kCFAllocatorDefault, 0);
            if (loc && CFGetTypeID(loc) == CFStringGetTypeID() && CFEqual(loc, CFSTR("External"))) {
                if (n++ == index) found = IOAVServiceCreateWithService(kCFAllocatorDefault, e);
            }
            if (loc) CFRelease(loc);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return found;
}

/*
 * While the monitor is in standby macOS still treats it as attached, so windows
 * stay on a dark screen. Mirroring the external display onto the built-in one
 * pulls them back; stopping the mirror lets them return when the monitor wakes.
 */
static void set_external_mirroring(BOOL mirror) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return;
    CGDirectDisplayID builtin = kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++) if (CGDisplayIsBuiltin(ids[i])) builtin = ids[i];
    if (builtin == kCGNullDirectDisplay) return;

    BOOL needed = NO;
    for (uint32_t i = 0; i < n; i++) {
        if (ids[i] == builtin) continue;
        BOOL mirrored = CGDisplayMirrorsDisplay(ids[i]) == builtin;
        if (mirror != mirrored) needed = YES;
    }
    if (!needed) return;

    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    for (uint32_t i = 0; i < n; i++) {
        if (ids[i] == builtin) continue;
        if (!mirror && CGDisplayMirrorsDisplay(ids[i]) != builtin) continue;
        CGConfigureDisplayMirrorOfDisplay(cfg, ids[i], mirror ? builtin : kCGNullDirectDisplay);
    }
    if (CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) != kCGErrorSuccess)
        CGCancelDisplayConfiguration(cfg);
}

/* Standby: gather the windows on the Mac screen. Wake: let them go back. */
static void external_gather(void)  { set_external_mirroring(YES); }
static void external_release(void) { set_external_mirroring(NO); }

static BOOL external_present(int index) {
    IOAVServiceRef s = find_external(index);
    if (s) CFRelease(s);
    return s != NULL;
}

static int ddc_write(IOAVServiceRef s, uint8_t vcp, uint16_t val) {
    uint8_t buf[6] = {0x84, 0x03, vcp, (uint8_t)(val >> 8), (uint8_t)(val & 0xFF), 0};
    uint8_t ck = (DDC_CHIP << 1) ^ DDC_DATA;
    for (int i = 0; i < 5; i++) ck ^= buf[i];
    buf[5] = ck;
    int ok = 0;
    for (int i = 0; i < 2; i++) {            /* some monitors want it twice */
        usleep(20000);
        if (IOAVServiceWriteI2C(s, DDC_CHIP, DDC_DATA, buf, sizeof buf) == kIOReturnSuccess) ok = 1;
    }
    return ok ? 0 : -1;
}

static int ddc_read(IOAVServiceRef s, uint8_t vcp, uint16_t *cur, uint16_t *max) {
    uint8_t req[4] = {0x82, 0x01, vcp, 0};
    uint8_t ck = (DDC_CHIP << 1) ^ DDC_DATA;
    for (int i = 0; i < 3; i++) ck ^= req[i];
    req[3] = ck;
    for (int attempt = 0; attempt < 4; attempt++) {
        usleep(20000);
        if (IOAVServiceWriteI2C(s, DDC_CHIP, DDC_DATA, req, sizeof req) != kIOReturnSuccess) continue;
        usleep(50000);
        uint8_t r[11] = {0};
        if (IOAVServiceReadI2C(s, DDC_CHIP, 0, r, sizeof r) != kIOReturnSuccess) continue;
        uint8_t c = 0x50;
        for (int i = 0; i < 10; i++) c ^= r[i];
        if (c != r[10]) continue;
        *max = (uint16_t)(r[6] << 8 | r[7]);
        *cur = (uint16_t)(r[8] << 8 | r[9]);
        return 0;
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* SMC                                                                 */
/* ------------------------------------------------------------------ */

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t   key;
    SMCVers    vers;
    SMCPLimit  pLimit;
    SMCKeyInfo keyInfo;
    uint8_t    result, status, data8;
    uint32_t   data32;
    uint8_t    bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "SMCParam must be 80 bytes");

#define SMC_SELECTOR      2
#define SMC_READ_BYTES    5
#define SMC_WRITE_BYTES   6
#define SMC_READ_KEYINFO  9

static io_connect_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t c = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? c : 0;
}

static uint32_t fourcc(const char *k) {
    return (uint32_t)(uint8_t)k[0] << 24 | (uint32_t)(uint8_t)k[1] << 16 |
           (uint32_t)(uint8_t)k[2] << 8  | (uint32_t)(uint8_t)k[3];
}

static int smc_call(io_connect_t c, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(c, SMC_SELECTOR, in, sizeof(SMCParam), out, &outSize);
    return (kr == KERN_SUCCESS && out->result == 0) ? 0 : -1;
}

static int smc_keyinfo(io_connect_t c, const char *key, uint32_t *size) {
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = SMC_READ_KEYINFO;
    if (smc_call(c, &in, &out) != 0) return -1;
    *size = out.keyInfo.dataSize;
    return (*size >= 1 && *size <= 32) ? 0 : -1;
}

static int smc_read(io_connect_t c, const char *key, uint8_t *buf, uint32_t *size) {
    if (smc_keyinfo(c, key, size) != 0) return -1;
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = *size;
    in.data8 = SMC_READ_BYTES;
    if (smc_call(c, &in, &out) != 0) return -1;
    memcpy(buf, out.bytes, *size);
    return 0;
}

static int smc_write(io_connect_t c, const char *key, const uint8_t *buf, uint32_t len) {
    uint32_t sz;
    if (smc_keyinfo(c, key, &sz) != 0 || sz != len) return -1;
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = sz;
    in.data8 = SMC_WRITE_BYTES;
    memcpy(in.bytes, buf, sz);
    return smc_call(c, &in, &out);
}

static int key_exists(io_connect_t c, const char *key) {
    uint32_t sz;
    return smc_keyinfo(c, key, &sz) == 0;
}

/* Adapter: run on battery even though power is connected. */
static int set_adapter(io_connect_t c, int enable) {
    if (key_exists(c, "CHIE")) {
        uint8_t v = enable ? 0x00 : 0x08;
        return smc_write(c, "CHIE", &v, 1);
    }
    return -2;
}

/* ------------------------------------------------------------------ */
/* Menu bar app                                                        */
/* ------------------------------------------------------------------ */

/* If the adapter is off and the battery falls to this level, switch it back on. */
#define LOW_BATTERY_PCT 15

static int g_display_index = 0;
static dispatch_queue_t g_ddc_queue;

/* Is the adapter currently disabled? (CHIE is readable without root.) */
static int adapter_disabled(void) {
    static io_connect_t c = 0;
    if (!c) c = smc_open();
    if (!c) return 0;
    uint8_t b[32]; uint32_t n;
    if (smc_read(c, "CHIE", b, &n) != 0 || n < 1) return 0;
    return b[0] != 0;
}

/* Battery percentage (or -1); sets *onAC if the Mac is currently powered by the adapter. */
static int battery_info(BOOL *onAC) {
    *onAC = NO;
    int pct = -1;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFStringRef type = IOPSGetProvidingPowerSourceType(info);
    if (type && CFEqual(type, CFSTR("AC Power"))) *onAC = YES;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
            if (!d) continue;
            CFNumberRef cap = CFDictionaryGetValue(d, CFSTR("Current Capacity"));
            if (cap) CFNumberGetValue(cap, kCFNumberIntType, &pct);
        }
        CFRelease(list);
    }
    CFRelease(info);
    return pct;
}

static NSString *self_path(void) {
    char buf[PATH_MAX];
    uint32_t size = sizeof buf;
    if (_NSGetExecutablePath(buf, &size) != 0) return nil;
    char real[PATH_MAX];
    if (!realpath(buf, real)) return nil;
    return [NSString stringWithUTF8String:real];
}

static int run_tool(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) return -1;
    [t waitUntilExit];
    return t.terminationStatus;
}

/*
 * Changing the adapter needs root. First try passwordless sudo (works if you
 * installed the optional sudoers rule); otherwise fall back to the standard
 * macOS administrator password prompt.
 */
static BOOL set_adapter_privileged(BOOL enable) {
    NSString *me = self_path();
    if (!me) return NO;
    if ([me containsString:@"'"] || [me containsString:@"\""] || [me containsString:@"\\"]) return NO;
    NSString *arg = enable ? @"on" : @"off";
    if (run_tool(@"/usr/bin/sudo", @[@"-n", me, @"adapter", arg]) == 0) return YES;
    NSString *script = [NSString stringWithFormat:
        @"do shell script \"'%@' adapter %@\" with administrator privileges", me, arg];
    return run_tool(@"/usr/bin/osascript", @[@"-e", script]) == 0;
}

#define PANEL_W 308.0
#define PANEL_H 157.0

/*
 * Brightness slider drawn like Apple's menu bar sliders: a thick capsule track,
 * a white fill up to the value, and a plain white pill-shaped knob.
 */
@interface BrightnessSlider : NSControl
@property (assign) double value;   /* 0...100 */
@end

@implementation BrightnessSlider

#define KNOB_W  20.0
#define KNOB_H  16.0
#define TRACK_H 6.0

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _value = 50;
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alphaValue = enabled ? 1.0 : 0.4;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    CGFloat cy = NSMidY(b);
    CGFloat frac = MAX(0.0, MIN(1.0, self.value / 100.0));
    CGFloat knobX = b.origin.x + KNOB_W / 2.0 + frac * (b.size.width - KNOB_W);

    NSRect track = NSMakeRect(b.origin.x, cy - TRACK_H / 2.0, b.size.width, TRACK_H);
    [[[NSColor labelColor] colorWithAlphaComponent:0.11] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:TRACK_H / 2.0 yRadius:TRACK_H / 2.0] fill];

    NSRect fillRect = NSMakeRect(b.origin.x, cy - TRACK_H / 2.0, knobX - b.origin.x, TRACK_H);
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:TRACK_H / 2.0 yRadius:TRACK_H / 2.0] fill];

    NSRect knob = NSMakeRect(knobX - KNOB_W / 2.0, cy - KNOB_H / 2.0, KNOB_W, KNOB_H);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    shadow.shadowBlurRadius = 1.5;
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.12];
    [shadow set];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:KNOB_H / 2.0 yRadius:KNOB_H / 2.0] fill];
    [NSGraphicsContext restoreGraphicsState];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)setValueFromEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat frac = (p.x - KNOB_W / 2.0) / (self.bounds.size.width - KNOB_W);
    frac = MAX(0.0, MIN(1.0, frac));
    self.value = round(frac * 100.0);
    [self setNeedsDisplay:YES];
    [self sendAction:self.action to:self.target];
}

/* Track the whole drag inside mouseDown; this works while a menu is open. */
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    [self setValueFromEvent:event];
    for (;;) {
        NSEvent *e = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                              untilDate:[NSDate distantFuture]
                                                 inMode:NSEventTrackingRunLoopMode
                                                dequeue:YES];
        if (!e) break;
        [self setValueFromEvent:e];
        if (e.type == NSEventTypeLeftMouseUp) break;
    }
}

- (void)nudge:(double)delta {
    self.value = MAX(0.0, MIN(100.0, self.value + delta));
    [self setNeedsDisplay:YES];
    [self sendAction:self.action to:self.target];
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilitySliderRole; }
- (NSString *)accessibilityLabel { return @"Monitor brightness"; }
- (id)accessibilityValue { return @(self.value); }
- (BOOL)accessibilityPerformIncrement { [self nudge:5]; return YES; }
- (BOOL)accessibilityPerformDecrement { [self nudge:-5]; return YES; }

@end

/*
 * A mode row in the style of Apple's "Low Power" row: a round icon that fills
 * with the accent colour while the mode is on, and a plain label beside it.
 */
@interface ModeRowView : NSView
@property (copy) NSString *symbolName;
@property (copy) NSString *text;
@property (strong) NSColor *textColor;
@property (assign) BOOL on;
@property (assign) BOOL rowEnabled;
@property (assign) BOOL hover;
@property (assign) BOOL pressed;
@property (copy) void (^onClick)(void);
- (instancetype)initWithFrame:(NSRect)frame symbol:(NSString *)symbol text:(NSString *)text;
- (void)update;
@end

@implementation ModeRowView {
    NSImageView *_icon;
    NSTextField *_label;
    NSTrackingArea *_area;
}

#define CIRCLE_D 26.0

- (instancetype)initWithFrame:(NSRect)frame symbol:(NSString *)symbol text:(NSString *)text {
    if ((self = [super initWithFrame:frame])) {
        _symbolName = symbol;
        _text = text;
        _rowEnabled = YES;

        CGFloat cy = (frame.size.height - CIRCLE_D) / 2.0;
        _icon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, cy, CIRCLE_D, CIRCLE_D)];
        _icon.imageScaling = NSImageScaleNone;
        _icon.imageAlignment = NSImageAlignCenter;
        [self addSubview:_icon];

        _label = [NSTextField labelWithString:text];
        _label.font = [NSFont systemFontOfSize:13];
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.frame = NSMakeRect(14 + CIRCLE_D + 8, (frame.size.height - 16) / 2.0,
                                  frame.size.width - (14 + CIRCLE_D + 8) - 14, 16);
        [self addSubview:_label];

        [self update];
    }
    return self;
}

- (void)update {
    _icon.image = [NSImage imageWithSystemSymbolName:self.symbolName accessibilityDescription:nil];
    _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12
                                                                                weight:NSFontWeightMedium];
    _icon.contentTintColor = self.on ? [NSColor whiteColor]
                                     : [NSColor labelColor];
    _label.stringValue = self.text ?: @"";
    _label.textColor = self.textColor ?: [[NSColor labelColor] colorWithAlphaComponent:0.85];
    self.alphaValue = self.rowEnabled ? 1.0 : 0.5;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.rowEnabled && (self.hover || self.pressed)) {
        NSRect hr = NSInsetRect(self.bounds, 6, 1);
        [[[NSColor labelColor] colorWithAlphaComponent:(self.pressed ? 0.14 : 0.08)] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:hr xRadius:8 yRadius:8] fill];
    }
    NSRect c = NSMakeRect(14, (self.bounds.size.height - CIRCLE_D) / 2.0, CIRCLE_D, CIRCLE_D);
    NSColor *fill = self.on ? [NSColor controlAccentColor]
                            : [[NSColor labelColor] colorWithAlphaComponent:0.10];
    [fill setFill];
    [[NSBezierPath bezierPathWithOvalInRect:c] fill];
}

/* Take every click inside the row so the label and icon never swallow it. */
- (NSView *)hitTest:(NSPoint)point {
    NSPoint p = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(p, self.bounds) ? self : nil;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) [self removeTrackingArea:_area];
    _area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                         options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                           owner:self userInfo:nil];
    [self addTrackingArea:_area];
}

- (void)mouseEntered:(NSEvent *)event { self.hover = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { self.hover = NO; self.pressed = NO; [self setNeedsDisplay:YES]; }

- (void)mouseDown:(NSEvent *)event {
    if (!self.rowEnabled) return;
    self.pressed = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    BOOL armed = self.pressed && self.rowEnabled;
    self.pressed = NO;
    [self setNeedsDisplay:YES];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (armed && NSPointInRect(p, self.bounds) && self.onClick) self.onClick();
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityCheckBoxRole; }
- (NSString *)accessibilityLabel { return self.text; }
- (id)accessibilityValue { return @(self.on ? 1 : 0); }
- (BOOL)accessibilityPerformPress {
    if (self.rowEnabled && self.onClick) self.onClick();
    return YES;
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSMenu *mainMenu;
@property (strong) NSMenu *quitMenu;
@property (strong) BrightnessSlider *slider;
@property (strong) ModeRowView *sleepRow;
@property (strong) ModeRowView *batteryRow;
@property (strong) NSLock *lock;
@property (strong) NSDate *lastSafety;
@property (strong) NSString *errorText;
@property (strong) NSDate *errorUntil;
@property (assign) int errorTile;          /* 0 none/general, 1 sleep row, 2 battery row */
@property (assign) BOOL busy;
@property (assign) BOOL desiredAdapterDisabled;
@property (assign) BOOL monitorAsleep;
@property (assign) BOOL brightnessWriting;
@property (assign) int pendingBrightness;
@property (assign) int brightnessMax;
@end

@implementation AppDelegate

#pragma mark - Views

- (NSImage *)symbol:(NSString *)name description:(NSString *)desc {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:desc];
    img.template = YES;
    return img;
}

- (NSTextField *)labelWithText:(NSString *)text font:(NSFont *)font color:(NSColor *)color frame:(NSRect)frame {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = font;
    l.textColor = color;
    l.frame = frame;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

/*
 * Layout, top to bottom:
 *   title, brightness slider, divider, "Modes" header, Sleep Monitor row, Run on Battery row.
 */
- (NSView *)makePanelView {
    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, PANEL_W, PANEL_H)];
    __weak AppDelegate *weakSelf = self;

    /* Title */
    [panel addSubview:[self labelWithText:@"Monitor"
                                     font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                    color:[[NSColor labelColor] colorWithAlphaComponent:0.85]
                                    frame:NSMakeRect(14, 133, PANEL_W - 28, 16)]];

    /* Brightness row: 16 pt icons at the edges, 6 pt capsule track, 20 pt knob. */
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];

    NSImageView *lo = [NSImageView imageViewWithImage:[self symbol:@"sun.min" description:nil]];
    lo.symbolConfiguration = cfg;
    lo.imageScaling = NSImageScaleNone;
    lo.contentTintColor = [[NSColor labelColor] colorWithAlphaComponent:0.7];
    lo.frame = NSMakeRect(15, 105, 18, 18);
    [panel addSubview:lo];

    self.slider = [[BrightnessSlider alloc] initWithFrame:NSMakeRect(38, 102, PANEL_W - 76, 24)];
    self.slider.target = self;
    self.slider.action = @selector(brightnessChanged:);
    [panel addSubview:self.slider];

    NSImageView *hi = [NSImageView imageViewWithImage:[self symbol:@"sun.max" description:nil]];
    hi.symbolConfiguration = cfg;
    hi.imageScaling = NSImageScaleNone;
    hi.contentTintColor = [[NSColor labelColor] colorWithAlphaComponent:0.7];
    hi.frame = NSMakeRect(PANEL_W - 33, 105, 18, 18);
    [panel addSubview:hi];

    /* Divider, then the "Modes" section. */
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(14, 96, PANEL_W - 28, 1)];
    line.boxType = NSBoxCustom;
    line.borderWidth = 0;
    line.contentViewMargins = NSZeroSize;
    line.fillColor = [[NSColor labelColor] colorWithAlphaComponent:0.11];
    [panel addSubview:line];

    [panel addSubview:[self labelWithText:@"Modes"
                                     font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                                    color:[NSColor secondaryLabelColor]
                                    frame:NSMakeRect(14, 71, PANEL_W - 28, 16)]];

    self.sleepRow = [[ModeRowView alloc] initWithFrame:NSMakeRect(0, 37, PANEL_W, 32)
                                                symbol:@"moon.zzz.fill" text:@"Sleep Monitor"];
    self.sleepRow.onClick = ^{ [weakSelf applyMonitorSleep:!weakSelf.monitorAsleep]; };
    [panel addSubview:self.sleepRow];

    self.batteryRow = [[ModeRowView alloc] initWithFrame:NSMakeRect(0, 5, PANEL_W, 32)
                                                  symbol:@"bolt.slash.fill" text:@"Run on Battery"];
    self.batteryRow.onClick = ^{ [weakSelf applyAdapter:adapter_disabled() ? YES : NO]; };
    [panel addSubview:self.batteryRow];

    return panel;
}

#pragma mark - Setup

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    g_ddc_queue = dispatch_queue_create("monitorctl.ddc", DISPATCH_QUEUE_SERIAL);
    self.lock = [NSLock new];
    self.pendingBrightness = -1;
    self.brightnessMax = 100;

    self.mainMenu = [NSMenu new];
    self.mainMenu.delegate = self;
    NSMenuItem *panelItem = [NSMenuItem new];
    panelItem.view = [self makePanelView];
    [self.mainMenu addItem:panelItem];

    self.quitMenu = [NSMenu new];
    [self.quitMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit monitorctl"
                                                      action:@selector(terminate:) keyEquivalent:@"q"]];

    /* No menu is attached to the item: left-click opens the panel, right-click opens Quit. */
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.item.button;
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    [self refresh];
    [self syncFromMonitor];
    [self updateVisibility];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateVisibility)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(updateVisibility)
                                   userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(tick:)
                                   userInfo:nil repeats:YES];
}

/* Show the item only while the monitor is connected. It also stays while the adapter is
   disabled or the monitor is in standby, so those states can always be undone. */
- (void)updateVisibility {
    dispatch_async(g_ddc_queue, ^{
        BOOL present = external_present(g_display_index);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL show = present || adapter_disabled() || self.monitorAsleep;
            if (show == self.item.visible) return;
            self.item.visible = show;
            if (show) { [self refresh]; [self syncFromMonitor]; }
        });
    });
}

- (void)statusItemClicked:(id)sender {
    NSEvent *e = NSApp.currentEvent;
    BOOL secondary = e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl);
    [self showMenu:secondary ? self.quitMenu : self.mainMenu];
}

- (void)showMenu:(NSMenu *)menu {
    self.item.menu = menu;
    [self.item.button performClick:nil];
    self.item.menu = nil;
}

#pragma mark - State

- (void)refresh {
    BOOL disabled = adapter_disabled();
    BOOL hasError = self.errorText != nil && [self.errorUntil timeIntervalSinceNow] > 0;
    if (!hasError) { self.errorText = nil; self.errorTile = 0; }

    /* Menu bar icon: always the display symbol (a warning triangle only after a failed action); state is in the panel and tooltip. */
    NSString *symbol, *summary;
    if (hasError)                { symbol = @"exclamationmark.triangle"; summary = self.errorText; }
    else if (disabled)           { symbol = @"display";                  summary = @"monitorctl · running on battery"; }
    else if (self.monitorAsleep) { symbol = @"display";                  summary = @"monitorctl · monitor asleep"; }
    else                         { symbol = @"display";                  summary = @"monitorctl"; }
    NSStatusBarButton *button = self.item.button;
    NSImage *img = [self symbol:symbol description:summary];
    button.image = img;
    button.title = img ? @"" : @"MC";
    button.toolTip = [summary stringByAppendingString:@"\nRight-click for options"];
    button.accessibilityLabel = summary;

    /* Mode rows: grey circle = off, accent-coloured circle = on. */
    BOOL sleepErr = hasError && self.errorTile == 1;
    self.sleepRow.on = self.monitorAsleep;
    self.sleepRow.text = sleepErr ? self.errorText : @"Sleep Monitor";
    self.sleepRow.textColor = sleepErr ? [NSColor systemRedColor] : [NSColor labelColor];
    [self.sleepRow update];

    BOOL batErr = hasError && self.errorTile == 2;
    self.batteryRow.on = self.busy ? self.desiredAdapterDisabled : disabled;
    self.batteryRow.rowEnabled = !self.busy;
    self.batteryRow.text = batErr ? self.errorText : (self.busy ? @"Switching…" : @"Run on Battery");
    self.batteryRow.textColor = batErr ? [NSColor systemRedColor]
                              : (self.busy ? [NSColor secondaryLabelColor] : [NSColor labelColor]);
    [self.batteryRow update];

    self.slider.enabled = !self.monitorAsleep;
}

- (void)showError:(NSString *)msg tile:(int)tile {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.errorText = msg;
        self.errorTile = tile;
        self.errorUntil = [NSDate dateWithTimeIntervalSinceNow:8];
        [self refresh];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ [self refresh]; });
    });
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != self.mainMenu) return;
    /* A closed menu never reports the mouse leaving, so clear any stale hover highlight. */
    for (ModeRowView *row in @[self.sleepRow, self.batteryRow]) {
        row.hover = NO;
        row.pressed = NO;
        [row setNeedsDisplay:YES];
    }
    [self refresh];
    [self syncFromMonitor];
}

- (void)tick:(NSTimer *)timer {
    [self refresh];
    BOOL onAC;
    int pct = battery_info(&onAC);
    if (adapter_disabled() && pct >= 0 && pct <= LOW_BATTERY_PCT && !self.busy &&
        (!self.lastSafety || [[NSDate date] timeIntervalSinceDate:self.lastSafety] > 300)) {
        self.lastSafety = [NSDate date];
        [self showError:@"Battery low: adapter switched back on" tile:0];
        [self applyAdapter:YES];   /* safety: bring the adapter back before the battery runs flat */
    }
}

#pragma mark - Actions

/* enable == YES means "draw from the adapter again". */
- (void)applyAdapter:(BOOL)enable {
    self.desiredAdapterDisabled = !enable;
    self.busy = YES;
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = set_adapter_privileged(enable);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self refresh];
            if (!ok) [self showError:@"Power setting not changed" tile:2];
        });
        /* the power source takes several seconds to actually switch */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ [self refresh]; });
    });
}

- (void)applyMonitorSleep:(BOOL)goSleep {
    self.monitorAsleep = goSleep;     /* show the change immediately; undo it if the monitor doesn't answer */
    [self refresh];
    dispatch_async(g_ddc_queue, ^{
        if (!goSleep) external_release();
        IOAVServiceRef s = find_external(g_display_index);
        BOOL ok = s && ddc_write(s, VCP_POWER, goSleep ? 4 : 1) == 0;
        if (s) CFRelease(s);
        if (ok && goSleep) external_gather();
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.monitorAsleep = !goSleep;
                [self showError:@"Monitor didn't respond" tile:1];
            });
        }
    });
}

/*
 * Dragging the slider fires many events; only the latest value matters. Keep a
 * single writer going on the DDC queue and let it pick up the newest value.
 */
- (void)brightnessChanged:(BrightnessSlider *)slider {
    int v = (int)lround(slider.value * self.brightnessMax / 100.0);
    [self.lock lock];
    self.pendingBrightness = v;
    BOOL alreadyWriting = self.brightnessWriting;
    self.brightnessWriting = YES;
    [self.lock unlock];
    if (alreadyWriting) return;

    dispatch_async(g_ddc_queue, ^{
        IOAVServiceRef s = find_external(g_display_index);
        BOOL ok = (s != NULL);
        for (;;) {
            [self.lock lock];
            int next = self.pendingBrightness;
            if (next < 0) self.brightnessWriting = NO; else self.pendingBrightness = -1;
            [self.lock unlock];
            if (next < 0) break;
            if (s && ddc_write(s, VCP_BRIGHTNESS, (uint16_t)next) != 0) ok = NO;
        }
        if (s) CFRelease(s);
        if (!ok) [self showError:@"Monitor didn't respond" tile:0];
    });
}

/* On launch and whenever the panel opens: read the monitor's real power state and brightness. */
- (void)syncFromMonitor {
    dispatch_async(g_ddc_queue, ^{
        IOAVServiceRef s = find_external(g_display_index);
        uint16_t cur = 0, max = 0;
        BOOL powerOK = s && ddc_read(s, VCP_POWER, &cur, &max) == 0;
        BOOL asleep = powerOK && cur != 1;
        uint16_t bcur = 0, bmax = 0;
        BOOL briOK = NO;
        if (powerOK && !asleep) briOK = ddc_read(s, VCP_BRIGHTNESS, &bcur, &bmax) == 0 && bmax > 0;
        if (s) CFRelease(s);
        if (powerOK && !asleep) external_release();   /* woken some other way, e.g. the monitor's own button */
        dispatch_async(dispatch_get_main_queue(), ^{
            if (powerOK) self.monitorAsleep = asleep;
            if (briOK) {
                self.brightnessMax = bmax;
                if (!self.brightnessWriting) {
                    self.slider.value = 100.0 * bcur / bmax;
                    [self.slider setNeedsDisplay:YES];
                }
            }
            [self refresh];
        });
    });
}

@end

static AppDelegate *g_delegate;

static int run_menubar(int index) {
    /* Only one menu bar instance at a time: hold an exclusive lock for the life of the process. */
    const char *home = getenv("HOME");
    char lockPath[1024];
    snprintf(lockPath, sizeof lockPath, "%s/.monitorctl.lock", home ? home : "/tmp");
    int lockFd = open(lockPath, O_CREAT | O_RDWR, 0600);
    if (lockFd >= 0 && flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "monitorctl is already running in the menu bar.\n");
        return 0;
    }
    @autoreleasepool {
        g_display_index = index;
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_delegate = [AppDelegate new];
        app.delegate = g_delegate;
        [app run];
    }
    return 0;
}

/* ------------------------------------------------------------------ */

static void usage(void) {
    fprintf(stderr,
        "usage:\n"
        "  monitorctl menubar\n"
        "  monitorctl [-d N] off | on        (monitor standby / wake, stays connected)\n"
        "  monitorctl [-d N] brightness [0-100]\n"
        "  monitorctl status\n"
        "  sudo monitorctl adapter on|off    (draw from the monitor / run on battery)\n");
    exit(2);
}

int main(int argc, char **argv) {
    int idx = 0, a = 1;
    if (argc > 2 && strcmp(argv[1], "-d") == 0) { idx = atoi(argv[2]); a = 3; }
    if (a >= argc) usage();
    const char *cmd = argv[a];

    if (!strcmp(cmd, "menubar")) return run_menubar(idx);

    if (!strcmp(cmd, "adapter")) {
        if (a + 1 >= argc) usage();
        int on = !strcmp(argv[a + 1], "on");
        if (!on && strcmp(argv[a + 1], "off")) usage();
        if (geteuid() != 0) { fprintf(stderr, "Run this with sudo.\n"); return 1; }
        io_connect_t c = smc_open();
        if (!c) { fprintf(stderr, "Could not open the SMC.\n"); return 1; }
        int r = set_adapter(c, on);
        if (r == -2) { fprintf(stderr, "No known SMC key for this Mac/macOS version.\n"); return 1; }
        if (r != 0)  { fprintf(stderr, "SMC write failed.\n"); return 1; }
        printf("adapter %s\n", on ? "on" : "off");
        return 0;
    }

    if (!strcmp(cmd, "status")) {
        IOAVServiceRef s = find_external(idx);
        uint16_t cur, max;
        if (s && ddc_read(s, VCP_BRIGHTNESS, &cur, &max) == 0)
            printf("Monitor brightness: %u / %u\n", cur, max);
        else
            printf("Monitor brightness: unavailable (no external display or DDC not responding)\n");
        printf("Adapter: %s\n", adapter_disabled() ? "off (running on battery)" : "on");
        return 0;
    }

    IOAVServiceRef s = find_external(idx);
    if (!s) { fprintf(stderr, "No external display found (index %d).\n", idx); return 1; }

    uint16_t cur = 0, max = 100;
    if (!strcmp(cmd, "brightness")) {
        if (a + 1 < argc) {
            int v = atoi(argv[a + 1]);
            if (v < 0) v = 0;
            if (v > 100) v = 100;
            if (ddc_write(s, VCP_BRIGHTNESS, (uint16_t)v) != 0) { fprintf(stderr, "Write failed.\n"); return 1; }
            printf("Brightness set to %d.\n", v);
        } else {
            if (ddc_read(s, VCP_BRIGHTNESS, &cur, &max) != 0) { fprintf(stderr, "Could not read brightness.\n"); return 1; }
            printf("%u / %u\n", cur, max);
        }
    } else if (!strcmp(cmd, "off") || !strcmp(cmd, "on")) {
        /* DDC power mode (VCP 0xD6): 4 = standby, 1 = on. USB-C link stays up. */
        int on = !strcmp(cmd, "on");
        if (ddc_write(s, VCP_POWER, on ? 1 : 4) != 0) { fprintf(stderr, "Write failed.\n"); return 1; }
        printf(on ? "Monitor on.\n" : "Monitor in standby.\n");
    } else {
        usage();
    }
    return 0;
}
