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
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue];
    return dflt;
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
        PLog(@"[img] eye = %@", img ? [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height] : @"nil");
    });
    return img;
}

#pragma mark - 录屏状态 / 计时

static BOOL KZCaptured(void) {
    @try {
        for (UIScreen *s in [UIScreen screens]) if (s.isCaptured) return YES;
    } @catch (...) {}
    return NO;
}

static NSTimeInterval gStartAt = 0;      // 本次录屏的起点
static NSString *KZElapsed(void) {
    if (gStartAt <= 0) return @"00:00";
    double t = CFAbsoluteTimeGetCurrent() - gStartAt;
    if (t < 0) t = 0;
    int total = (int)t;
    return [NSString stringWithFormat:@"%02d:%02d", total / 60, total % 60];
}

#pragma mark - 私有协议

@protocol SAElementIdentifying <NSObject>
- (NSString *)clientIdentifier;
- (NSString *)elementIdentifier;
@end
@protocol SAElement <SAElementIdentifying>
- (id)viewProvider;
@end
@protocol SAElementViewProviding <NSObject>
- (id)element;
@end
@protocol SAActivityBehavior <NSObject>
- (BOOL)hasActivityBehavior;
@end
@protocol SAUILayoutSpecifying <NSObject>
- (NSInteger)layoutMode;
- (NSInteger)maximumSupportedLayoutMode;
- (NSInteger)minimumSupportedLayoutMode;
- (NSInteger)preferredLayoutMode;
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason;
@end

#pragma mark - 写轮眼视图

@interface KZEyeDot : UIView
@property (nonatomic, strong) UIImageView *img;
@property (nonatomic) CGFloat side;
@end

@implementation KZEyeDot
- (void)layoutSubviews {
    [super layoutSubviews];
    self.img.frame = self.bounds;
}
@end

static KZEyeDot *KZMakeEye(CGFloat side) {
    KZEyeDot *v = [[KZEyeDot alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    v.tag = KZ_EYE_TAG;
    v.side = side;
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = side / 2.0;
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;

    UIImage *img = KZEyeImage();
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = v.bounds;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.img = iv;
    [v addSubview:iv];
    if (!img) v.backgroundColor = [UIColor redColor];

    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.2) dur = 1.5;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = dur;
    spin.repeatCount = INFINITY;
    [iv.layer addAnimation:spin forKey:@"kzspin"];
    return v;
}

static CGFloat KZEyeSide(void) {
    double sc = KZPrefNum(@"scale", 1.0);
    if (sc < 0.3 || sc > 3.0) sc = 1.0;
    CGFloat side = 26.0 * sc;
    if (side < 12) side = 12;
    if (side > 44) side = 44;   // 岛高上限
    return side;
}

#pragma mark - 计时视图（我们自己画，因为系统那套已经被顶掉）

@interface KZTimerView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation KZTimerView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _label = [[UILabel alloc] initWithFrame:self.bounds];
        _label.text = @"00:00";
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.6;
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_label];
        [self kzStartTimer];
    }
    return self;
}
- (void)kzStartTimer {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        self.label.text = KZElapsed();
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)kzStopTimer {
    [self.timer invalidate];
    self.timer = nil;
}
- (void)dealloc {
    [self kzStopTimer];
}
@end

#pragma mark - 停止录屏

static void KZStopRecording(void) {
    PLog(@"[tap] 请求停止录屏");
    Class rp = NSClassFromString(@"RPScreenRecorder");
    id rec = nil;
    if (rp) {
        SEL sh = NSSelectorFromString(@"sharedRecorder");
        if ([rp respondsToSelector:sh]) rec = ((id (*)(id, SEL))objc_msgSend)(rp, sh);
    }
    if (!rec) { PLog(@"[tap] 拿不到 RPScreenRecorder"); return; }

    SEL s1 = NSSelectorFromString(@"stopSystemRecording:");
    if ([rec respondsToSelector:s1]) {
        @try {
            void (^handler)(id) = ^(id err) { PLog(@"[tap] stopSystemRecording 回调 %@", err ?: @"ok"); };
            ((void (*)(id, SEL, id))objc_msgSend)(rec, s1, handler);
            PLog(@"[tap] 调用 stopSystemRecording:");
            return;
        } @catch (NSException *e) { PLog(@"[tap] 异常 %@", e.reason); }
    }
    SEL s2 = NSSelectorFromString(@"stopRecordingWithHandler:");
    if ([rec respondsToSelector:s2]) {
        @try {
            void (^handler)(id) = ^(id err) { PLog(@"[tap] stopRecording 回调 %@", err ?: @"ok"); };
            ((void (*)(id, SEL, id))objc_msgSend)(rec, s2, handler);
            PLog(@"[tap] 调用 stopRecordingWithHandler:");
        } @catch (NSException *e) { PLog(@"[tap] 异常 %@", e.reason); }
    }
}

#pragma mark - 自建 element provider（o2Pro 的核心：自己是 element，不是客人）

@interface KZElementProvider : NSObject <SAElement, SAElementViewProviding, SAActivityBehavior, SAUILayoutSpecifying>
@end

@implementation KZElementProvider {
    KZEyeDot *_eye;
    KZEyeDot *_minEye;
    KZTimerView *_timerView;
    NSInteger _layoutMode;
}

- (NSString *)clientIdentifier { return @"com.minis.kzsa"; }
- (NSString *)elementIdentifier { return @"KZSharinganElement"; }
- (NSString *)description { return @"KZSharinganElement"; }

- (BOOL)hasActivityBehavior { return YES; }
- (BOOL)hasAlertBehavior { return NO; }
- (id)element { return self; }
- (id)viewProvider { return self; }
- (BOOL)_canShowWhileLocked { return YES; }

- (KZEyeDot *)eye {
    if (!_eye) {
        _eye = KZMakeEye(KZEyeSide());
        PLog(@"[prov] 建写轮眼 side=%.0f", _eye.side);
    }
    return _eye;
}
- (KZEyeDot *)minEye {
    if (!_minEye) _minEye = KZMakeEye(KZEyeSide() * 0.72);
    return _minEye;
}
- (KZTimerView *)timerView {
    if (!_timerView) {
        _timerView = [[KZTimerView alloc] initWithFrame:CGRectMake(0, 0, 58, 22)];
        PLog(@"[prov] 建计时视图");
    }
    return _timerView;
}

- (UIView *)leadingView { KZOnce(@"lead", @"[prov] leadingView"); return [self eye]; }
- (UIView *)expandedLeadingView { return [self eye]; }
- (UIView *)minimalView { KZOnce(@"min", @"[prov] minimalView"); return [self minEye]; }
- (UIView *)trailingView { KZOnce(@"trail", @"[prov] trailingView（自己的计时）"); return [self timerView]; }
- (UIView *)expandedTrailingView {
    KZOnce(@"extrail", @"[prov] expandedTrailingView");
    return KZPrefBool(@"showTimer", YES) ? [self timerView] : nil;
}

- (NSInteger)layoutMode { return _layoutMode; }
- (NSInteger)preferredLayoutMode { return 2; }
- (NSInteger)maximumSupportedLayoutMode { return 3; }
- (NSInteger)minimumSupportedLayoutMode { return 0; }
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    _layoutMode = mode;
}

- (CGSize)sizeThatFitsSize:(CGSize)size forProvidedView:(UIView *)view inLayoutMode:(NSInteger)mode {
    if (view == _eye || view == _minEye) {
        CGFloat s = [(KZEyeDot *)view side];
        return CGSizeMake(s, s);
    }
    if (view == _timerView) return CGSizeMake(58, 22);
    return CGSizeMake(22, 22);
}
- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode
                                            suggestedOutsets:(NSDirectionalEdgeInsets)sug
                                               maximumOutsets:(NSDirectionalEdgeInsets)mx {
    return sug;
}
- (BOOL)isProvidedViewConcentric:(UIView *)view inLayoutMode:(NSInteger)mode { return YES; }
- (BOOL)isMinimalPresentationPossible { return YES; }
- (BOOL)isInteractiveDismissalEnabled { return NO; }
- (BOOL)isRequestingMenuPresentation { return NO; }

// 点头像/整块 → 停止录屏（系统那套 UI 已被我们顶替，没有停止按钮了）
- (BOOL)handleElementViewEvent:(long long)event {
    PLog(@"[tap] handleElementViewEvent %lld", event);
    if ((unsigned long long)event < 4) {
        KZStopRecording();
        return YES;
    }
    return NO;
}

- (void)setActivityHost:(id)host { PLog(@"[prov] activityHost=%@", host ? NSStringFromClass([host class]) : @"nil"); }
- (id)activityHost { return nil; }
- (void)setElementHost:(id)host { PLog(@"[prov] elementHost=%@", host ? NSStringFromClass([host class]) : @"nil"); }
- (id)elementHost { return nil; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

#pragma mark - 假 assertion（用来吞掉系统录屏 element 的注册）

@interface KZDummyAssertion : NSObject
@end
@implementation KZDummyAssertion
- (BOOL)isValid { return YES; }
- (void)invalidate { PLog(@"[sup] 系统录屏 assertion 被 invalidate（我们已吞掉）"); }
- (void)invalidateWithReason:(id)r { PLog(@"[sup] 系统录屏 assertion invalidateWithReason: %@", r); }
- (id)element { return nil; }
- (id)invalidationReason { return nil; }
@end

#pragma mark - 状态

static id gManager = nil;
static id gProvider = nil;
static id gAssertion = nil;
static BOOL gSuppressOn = NO;
static NSUInteger gSuppressed = 0;

static NSString *KZElemIdent(id e) {
    if (!e) return nil;
    @try {
        id v = [e valueForKey:@"elementIdentifier"];
        if ([v isKindOfClass:[NSString class]]) return v;
    } @catch (...) {}
    return nil;
}
static BOOL KZIsRecordingElem(id e) {
    NSString *s = KZElemIdent(e);
    return s.length > 0 && [s.lowercaseString containsString:@"screenrecording"];
}

#pragma mark - hook：吞掉系统录屏 element 的注册（= o2Pro 的 _shouldSuppressElement 等价物）

static id (*origRegister)(id, SEL, id);
static id kzRegister(id self, SEL _cmd, id element) {
    if (gSuppressOn && KZIsRecordingElem(element)) {
        gSuppressed++;
        PLog(@"[sup] 拦截系统录屏 element 注册：#%lu %@", (unsigned long)gSuppressed,
             KZElemIdent(element) ?: @"?");
        return [[KZDummyAssertion alloc] init];
    }
    return origRegister ? origRegister(self, _cmd, element) : nil;
}

static void (*origPromote)(id, SEL);
static void kzPromote(id self, SEL _cmd) {
    if (!gManager) {
        gManager = self;
        PLog(@"[init] manager = %@", NSStringFromClass([self class]));
    }
    @try { if (origPromote) origPromote(self, _cmd); } @catch (...) {}
}

static void (*origWillLayout)(id, SEL);
static void kzWillLayout(id self, SEL _cmd) {
    if (!gManager) gManager = self;
    @try { if (origWillLayout) origWillLayout(self, _cmd); } @catch (...) {}
}

#pragma mark - 注册 / 注销

static void KZUnregister(void) {
    if (!gAssertion) return;
    @try {
        SEL inv = NSSelectorFromString(@"invalidate");
        if ([gAssertion respondsToSelector:inv]) {
            ((void (*)(id, SEL))objc_msgSend)(gAssertion, inv);
            PLog(@"[reg] 已注销自己的 element");
        }
    } @catch (NSException *e) { PLog(@"[reg] 注销异常 %@", e.reason); }
    gAssertion = nil;
    gProvider = nil;
    gSuppressOn = NO;
}

static void KZRegister(void) {
    if (gProvider || !gManager) return;
    if (!KZPrefBool(@"enabled", YES)) return;
    @try {
        gProvider = [[KZElementProvider alloc] init];
        // 先注册我们的，再开抑制 —— 顺序很重要：我们的 element 必须先占位
        SEL reg = NSSelectorFromString(@"registerElement:");
        id a = ((id (*)(id, SEL, id))objc_msgSend)(gManager, reg, gProvider);
        gAssertion = a;
        gSuppressOn = (a != nil);
        PLog(@"[reg] registerElement -> %@ (抑制=%@)",
             a ? NSStringFromClass([a class]) : @"nil", gSuppressOn ? @"开" : @"关");

        SEL as = NSSelectorFromString(@"_assertionForElementCreatingIfNecessary:");
        if ([gManager respondsToSelector:as]) {
            id a2 = ((id (*)(id, SEL, id))objc_msgSend)(gManager, as, gProvider);
            if (a2) { gAssertion = a2; }
        }
        SEL rg = NSSelectorFromString(@"registeredElements");
        if ([gManager respondsToSelector:rg]) {
            NSArray *rs = ((id (*)(id, SEL))objc_msgSend)(gManager, rg);
            NSMutableString *m = [NSMutableString string];
            for (id e in rs) [m appendFormat:@"%@ ", KZElemIdent(e) ?: @"?"];
            PLog(@"[reg] registeredElements=%lu -> %@", (unsigned long)rs.count, m);
        }
        // 请求宽布局
        SEL setL = NSSelectorFromString(@"setLayoutMode:reason:forTargetWithOverrider:");
        if ([gManager respondsToSelector:setL]) {
            @try {
                ((void (*)(id, SEL, long, long, id))objc_msgSend)(gManager, setL, 2, 0, gProvider);
                PLog(@"[reg] setLayoutMode:2");
            } @catch (NSException *e) { PLog(@"[reg] setLayoutMode 异常 %@", e.reason); }
        }
        SEL inval = NSSelectorFromString(@"invalidatePromotedElements");
        if ([gManager respondsToSelector:inval]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(gManager, inval); } @catch (...) {}
        }
    } @catch (NSException *e) {
        PLog(@"[reg] 异常 %@", e.reason);
        gProvider = nil;
        gAssertion = nil;
    }
}

#pragma mark - 安装 hook

static BOOL gHookManager = NO;
static void KZInstallManagerHook(void) {
    if (gHookManager) return;
    Class c = NSClassFromString(@"SAUISystemApertureManager");
    if (!c) { KZOnce(@"nomgr", @"[hook] 没有 SAUISystemApertureManager"); return; }

    SEL reg = NSSelectorFromString(@"registerElement:");
    if ([c instancesRespondToSelector:reg]) {
        MSHookMessageEx(c, reg, (IMP)kzRegister, (IMP *)&origRegister);
        KZOnce(@"hookreg", @"[hook] hook registerElement:（用于吞掉系统录屏）");
    }
    SEL prom = NSSelectorFromString(@"invalidatePromotedElements");
    if ([c instancesRespondToSelector:prom]) {
        MSHookMessageEx(c, prom, (IMP)kzPromote, (IMP *)&origPromote);
    }
    SEL will = NSSelectorFromString(@"hostWillPerformLayout");
    if ([c instancesRespondToSelector:will]) {
        MSHookMessageEx(c, will, (IMP)kzWillLayout, (IMP *)&origWillLayout);
    }
    gHookManager = YES;
}

#pragma mark - 主循环

static NSTimer *gTimer = nil;
static BOOL gWasCaptured = NO;

static void KZTick(void) {
    KZInstallManagerHook();
    BOOL cap = KZCaptured();
    if (cap && !gWasCaptured) {
        gWasCaptured = YES;
        gStartAt = CFAbsoluteTimeGetCurrent();
        gSeen = nil;
        PLog(@"[state] 录屏开始，准备注册");
        // 等系统把它的录屏 element 建出来再动手（否则我们抢先注册会被挤）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (KZCaptured()) KZRegister();
        });
    } else if (!cap && gWasCaptured) {
        gWasCaptured = NO;
        gStartAt = 0;
        gSeen = nil;
        KZUnregister();
        PLog(@"[state] 录屏结束");
    }
}

static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSeen = nil;
        PLog(@"[apply] scale=%.2f offX=%.1f dur=%.2f timer=%d",
             KZPrefNum(@"scale", 1.0), KZPrefNum(@"offX", 0.0),
             KZPrefNum(@"duration", 1.5), KZPrefBool(@"showTimer", YES));
        if (gProvider) {          // 重建：注销再注册，让新尺寸/新素材生效
            KZUnregister();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (KZCaptured()) KZRegister(); });
        }
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.44 (o2pro: own element + suppress system)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZInstallManagerHook();
        if (!gTimer || !gTimer.valid) {
            gTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                @try { KZTick(); } @catch (NSException *e) { PLog(@"[tick] %@", e.reason); }
            }];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        }
    });
}