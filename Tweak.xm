#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import "kzeye_b64.h"

#define KZ_DOMAIN "com.minis.kzprobe"
#define KZ_PREF_DOMAIN "com.minis.kzsa"
#define KZ_NOTIFY "com.minis.kzsa.changed"
#define KZ_EYE_TAG 0x4B5A

#pragma mark - 日志

static NSMutableString *gDump = nil;
static void KZFlush(void) {
    if (!gDump) return;
    CFPreferencesSetAppValue(CFSTR("dump"), (__bridge CFStringRef)[gDump copy], CFSTR(KZ_DOMAIN));
    CFPreferencesAppSynchronize(CFSTR(KZ_DOMAIN));
}
static void PLog(NSString *fmt, ...) {
    if (!gDump) gDump = [NSMutableString string];
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gDump.length < 60000) [gDump appendFormat:@"%@\n", body];
    KZFlush();
}
static NSMutableSet *gSeen = nil;
static void KZOnce(NSString *key, NSString *msg) {
    if (!gSeen) gSeen = [NSMutableSet set];
    if ([gSeen containsObject:key]) return;
    [gSeen addObject:key];
    if (msg.length) PLog(@"%@", msg);
}

#pragma mark - 偏好

static id KZPrefRaw(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KZ_PREF_DOMAIN));
    return v ? (__bridge_transfer id)v : nil;
}
static double KZPrefNum(NSString *key, double dflt) {
    id v = KZPrefRaw(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return dflt;
}
static BOOL KZPrefBool(NSString *key, BOOL dflt) {
    id v = KZPrefRaw(key);
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : dflt;
}
static NSString *KZPrefStr(NSString *key) {
    id v = KZPrefRaw(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static UIImage *KZEyeImage(void) {
    NSString *b64 = KZPrefStr(@"eyeImage");
    if (b64.length > 200) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d.length > 200) {
            UIImage *u = [UIImage imageWithData:d];
            if (u) return u;
        }
    }
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:kKZeyeB64]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d.length > 200) img = [UIImage imageWithData:d];
        if (!img) img = [UIImage imageWithContentsOfFile:@"/Library/KZTheme/eye/tomoe2.png"];
        if (img) PLog(@"[img] eye = %.0fx%.0f", img.size.width, img.size.height);
        else PLog(@"[img] 读不到素材");
    });
    return img;
}

#pragma mark - 写轮眼视图（容器 + 内部小圆，偏移只动小圆，不动容器）

// 容器铺满系统给的槽位，内部 dot 固定尺寸并可按 offX 左右移动；
// 这样系统的居中布局不会把我们的偏移吃掉，也不会被裁剪。
@interface KZEyeContainerView : UIView
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UIImageView *imgView;
@property (nonatomic) CGFloat side;
@property (nonatomic) CGFloat offX;
@property (nonatomic) double duration;
@property (nonatomic) BOOL leftSide;
@end

@implementation KZEyeContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.tag = KZ_EYE_TAG;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        self.autoresizingMask = UIViewAutoresizingNone;

        _dot = [[UIView alloc] initWithFrame:CGRectZero];
        _dot.userInteractionEnabled = NO;
        _dot.clipsToBounds = YES;
        _dot.backgroundColor = [UIColor blackColor];
        [self addSubview:_dot];

        _imgView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _imgView.contentMode = UIViewContentModeScaleAspectFill;
        _imgView.userInteractionEnabled = NO;
        [_dot addSubview:_imgView];
        [self kzReload];
    }
    return self;
}

- (void)kzReload {
    double sc = KZPrefNum(self.leftSide ? @"scale" : @"scaleR", self.leftSide ? 1.0 : 0.95);
    if (sc < 0.3 || sc > 2.5) sc = 1.0;
    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.2) dur = 1.5;
    CGFloat off = KZPrefNum(self.leftSide ? @"offX" : @"offXR", 0.0);

    self.side = 22.0 * sc;
    self.offX = off;
    self.duration = dur;

    UIImage *img = KZEyeImage();
    self.dot.backgroundColor = img ? [UIColor blackColor] : [UIColor redColor];
    self.imgView.image = img;
    self.dot.layer.cornerRadius = self.side / 2.0;
    self.imgView.frame = self.dot.bounds;
    PLog(@"[eye] side=%.1f offX=%.1f dur=%.2f", self.side, off, dur);
    [self setNeedsLayout];
    [self kzAnim];
}

- (void)kzAnim {
    [self.imgView.layer removeAnimationForKey:@"kzspin"];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = self.duration;
    spin.repeatCount = INFINITY;
    [self.imgView.layer addAnimation:spin forKey:@"kzspin"];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds), h = CGRectGetHeight(self.bounds);
    CGFloat side = self.side > 0 ? self.side : 22.0;
    self.dot.frame = CGRectMake((w - side) / 2.0 + self.offX, (h - side) / 2.0, side, side);
    self.dot.layer.cornerRadius = side / 2.0;
    self.imgView.frame = self.dot.bounds;
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat side = self.side > 0 ? self.side : 22.0;
    CGFloat pad = fabs(self.offX) * 2.0 + 2.0;
    return CGSizeMake(side + pad, side);
}
@end

static NSHashTable *gEyes = nil;   // 所有已交给系统的写轮眼容器（弱引用）
static void KZEyeRegister(KZEyeContainerView *v) {
    if (!gEyes) gEyes = [NSHashTable weakObjectsHashTable];
    [gEyes addObject:v];
}

static KZEyeContainerView *KZMakeEye(BOOL left) {
    if (!KZPrefBool(@"enabled", YES)) return nil;
    if (left && !KZPrefBool(@"leftOn", YES)) return nil;
    if (!left && !KZPrefBool(@"rightOn", YES)) return nil;
    KZEyeContainerView *v = [[KZEyeContainerView alloc] initWithFrame:CGRectMake(0, 0, 44, 22)];
    v.leftSide = left;
    [v kzReload];
    KZEyeRegister(v);
    return v;
}

#pragma mark - 代理 provider

@interface KZVCProvider : NSObject
@property (nonatomic, strong) id systemElement;
@property (nonatomic, strong) KZEyeContainerView *leftEye;
@property (nonatomic, strong) KZEyeContainerView *minEye;
@property (nonatomic, strong) KZEyeContainerView *rightEye;
@end

@implementation KZVCProvider

- (KZEyeContainerView *)leftEye {
    if (!_leftEye) _leftEye = KZMakeEye(YES);
    return _leftEye;
}
- (KZEyeContainerView *)minEye {
    if (!_minEye) _minEye = KZMakeEye(YES);
    return _minEye;
}
- (KZEyeContainerView *)rightEye {
    if (!_rightEye) _rightEye = KZMakeEye(NO);
    return _rightEye;
}

- (NSString *)elementIdentifier {
    NSString *s = nil;
    @try { s = [self.systemElement valueForKey:@"elementIdentifier"]; } @catch (...) {}
    return s ?: @"KZSharinganElement";
}
- (NSString *)clientIdentifier {
    NSString *s = nil;
    @try { s = [self.systemElement valueForKey:@"clientIdentifier"]; } @catch (...) {}
    return s ?: @"com.minis.kzsa";
}
- (id)element { return self.systemElement; }
- (id)viewProvider { return self; }
- (BOOL)_canShowWhileLocked { return YES; }

- (UIView *)leadingView {
    UIView *e = self.leftEye;
    if (e) { KZOnce(@"lead", @"[prov] leadingView = 写轮眼"); return e; }
    return [self kzOriginal:@selector(leadingView)];
}
- (UIView *)expandedLeadingView {
    UIView *e = self.leftEye;
    return e ?: [self kzOriginal:@selector(expandedLeadingView)];
}
- (UIView *)minimalView {
    UIView *e = self.minEye;
    if (e) { KZOnce(@"min", @"[prov] minimalView = 写轮眼"); return e; }
    return [self kzOriginal:@selector(minimalView)];
}
- (UIView *)trailingView {
    if (KZPrefBool(@"rightOn", NO)) {
        UIView *e = self.rightEye;
        if (e) { KZOnce(@"trail", @"[prov] trailingView = 写轮眼"); return e; }
    }
    return [self kzOriginal:@selector(trailingView)];
}
- (UIView *)expandedTrailingView {
    if (KZPrefBool(@"rightOn", NO)) {
        UIView *e = self.rightEye;
        if (e) return e;
    }
    return [self kzOriginal:@selector(expandedTrailingView)];
}

- (UIView *)kzOriginal:(SEL)sel {
    id t = self.systemElement;
    if (!t) return nil;
    @try {
        if ([t respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(t, sel);
    } @catch (...) {}
    return nil;
}

- (NSInteger)layoutMode { return [self kzInt:@selector(layoutMode) dflt:0]; }
// 录屏时请求「展开」，把岛拉长，左侧才有足够空间放下素材（用户要求的做法）
- (NSInteger)preferredLayoutMode { return 2; }
- (NSInteger)maximumSupportedLayoutMode { return 3; }
- (NSInteger)minimumSupportedLayoutMode { return 0; }
- (NSInteger)kzInt:(SEL)sel dflt:(NSInteger)d {
    id t = self.systemElement;
    if (t && [t respondsToSelector:sel]) {
        @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(t, sel); } @catch (...) {}
    }
    return d;
}
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    id t = self.systemElement;
    if (t && [t respondsToSelector:_cmd]) {
        @try { ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(t, _cmd, mode, reason); } @catch (...) {}
    }
}

- (CGSize)sizeThatFitsSize:(CGSize)size forProvidedView:(UIView *)view inLayoutMode:(NSInteger)mode {
    if ([view isKindOfClass:[KZEyeContainerView class]]) {
        KZEyeContainerView *e = (KZEyeContainerView *)view;
        CGFloat side = e.side > 0 ? e.side : 22.0;
        CGFloat pad = fabs(e.offX) * 2.0 + 4.0;
        return CGSizeMake(side + pad, side + 4.0);
    }
    id t = self.systemElement;
    if (t && [t respondsToSelector:_cmd]) {
        NSMethodSignature *sig = [t methodSignatureForSelector:_cmd];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:t]; [inv setSelector:_cmd];
            [inv setArgument:&size atIndex:2];
            [inv setArgument:&view atIndex:3];
            [inv setArgument:&mode atIndex:4];
            @try {
                [inv invoke];
                CGSize out = CGSizeZero;
                [inv getReturnValue:&out];
                return out;
            } @catch (...) {}
        }
    }
    return CGSizeMake(22, 22);
}

- (BOOL)respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel]) return YES;
    if (!self.systemElement) return NO;
    @try { return [self.systemElement respondsToSelector:sel]; } @catch (...) { return NO; }
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (!sig && self.systemElement) {
        @try { sig = [self.systemElement methodSignatureForSelector:sel]; } @catch (...) {}
    }
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    id t = self.systemElement;
    if (t) {
        @try {
            if ([t respondsToSelector:inv.selector]) { [inv invokeWithTarget:t]; return; }
        } @catch (...) {}
    }
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

static NSMapTable *gProxies = nil;
static KZVCProvider *KZProxyFor(id element) {
    if (!element) return nil;
    if (!gProxies) gProxies = [NSMapTable weakToStrongObjectsMapTable];
    KZVCProvider *p = [gProxies objectForKey:element];
    if (!p) {
        p = [[KZVCProvider alloc] init];
        p.systemElement = element;
        [gProxies setObject:p forKey:element];
        PLog(@"[prov] 新建代理 %@", NSStringFromClass([element class]));
    }
    return p;
}

static BOOL KZIsRecordingElement(id element) {
    if (!element) return NO;
    NSString *n = NSStringFromClass([element class]);
    if ([n rangeOfString:@"SBSystemApertureSceneElement"].location == NSNotFound) return NO;
    NSString *eid = nil;
    @try { eid = [element valueForKey:@"elementIdentifier"]; } @catch (...) {}
    return [eid isKindOfClass:[NSString class]] && [eid.lowercaseString containsString:@"screenrecording"];
}

static id (*origEVP)(id, SEL);
static id kzEVP(id self, SEL _cmd) {
    id orig = nil;
    @try { orig = origEVP ? origEVP(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecordingElement(orig)) {
        KZVCProvider *p = KZProxyFor(orig);
        if (p) { KZOnce(@"evp", @"[vc] elementViewProvider -> 代理"); return p; }
    }
    return orig;
}

static BOOL gHooked = NO;
static void KZInstall(void) {
    if (gHooked) return;
    int n = 0;
    SEL s = NSSelectorFromString(@"elementViewProvider");
    for (NSString *cn in @[ @"SAUIElementViewController", @"SAUILayoutSpecifyingElementViewController" ]) {
        Class c = NSClassFromString(cn);
        if (c && [c instancesRespondToSelector:s]) {
            MSHookMessageEx(c, s, (IMP)kzEVP, (IMP *)&origEVP);
            n++;
        }
    }
    if (n) { gHooked = YES; PLog(@"[hook] hook elementViewProvider x%d", n); }
}

// 改设置：原地更新所有已存在的写轮眼（不销毁，避免素材消失）
static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *eyes = gEyes ? [[gEyes allObjects] copy] : @[];
        for (KZEyeContainerView *e in eyes) {
            if (!e.superview) continue;
            @try { [e kzReload]; } @catch (...) {}
        }
        PLog(@"[apply] 原地更新 %lu 个视图 scale=%.2f offX=%.1f dur=%.2f",
             (unsigned long)eyes.count, KZPrefNum(@"scale", 1.0),
             KZPrefNum(@"offX", 0.0), KZPrefNum(@"duration", 1.5));
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.41 (wide layout + live update)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { KZInstall(); } @catch (...) {}
        }];
    });
}