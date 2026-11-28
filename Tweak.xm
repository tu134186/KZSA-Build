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
#define KZ_STOP_TAG 0x4B5B
#define KZ_TIMER_TAG 0x4B5C

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

#pragma mark - 录屏状态 / 控制

static BOOL KZCaptured(void) {
    @try {
        for (UIScreen *s in [UIScreen screens]) if (s.isCaptured) return YES;
    } @catch (...) {}
    return NO;
}

static NSTimeInterval gStartAt = 0;
static BOOL gPaused = NO;
static NSTimeInterval gPausedAt = 0;
static NSTimeInterval gPausedTotal = 0;

static NSTimeInterval KZElapsedDouble(void) {
    if (gStartAt <= 0) return 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (gPaused && gPausedAt > 0) now = gPausedAt;
    return MAX(0, now - gStartAt - gPausedTotal);
}
static NSString *KZElapsedText(void) {
    int total = (int)KZElapsedDouble();
    return [NSString stringWithFormat:@"%02d:%02d", total / 60, total % 60];
}

static id KZRecorder(void) {
    Class rp = NSClassFromString(@"RPScreenRecorder");
    if (!rp) return nil;
    SEL sh = NSSelectorFromString(@"sharedRecorder");
    if (![rp respondsToSelector:sh]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(rp, sh);
}

static void KZStopRecording(void) {
    PLog(@"[tap] 请求停止录屏");
    id rec = KZRecorder();
    if (!rec) { PLog(@"[tap] 拿不到 RPScreenRecorder"); return; }
    SEL s1 = NSSelectorFromString(@"stopSystemRecording:");
    if ([rec respondsToSelector:s1]) {
        @try {
            void (^h)(id) = ^(id err) { PLog(@"[tap] stopSystemRecording 回调 %@", err ?: @"ok"); };
            ((void (*)(id, SEL, id))objc_msgSend)(rec, s1, h);
            PLog(@"[tap] 调用 stopSystemRecording:");
            return;
        } @catch (NSException *e) { PLog(@"[tap] 异常 %@", e.reason); }
    }
    SEL s2 = NSSelectorFromString(@"stopRecordingWithHandler:");
    if ([rec respondsToSelector:s2]) {
        @try {
            void (^h)(id) = ^(id err) { PLog(@"[tap] stopRecording 回调 %@", err ?: @"ok"); };
            ((void (*)(id, SEL, id))objc_msgSend)(rec, s2, h);
            PLog(@"[tap] 调用 stopRecordingWithHandler:");
        } @catch (NSException *e) { PLog(@"[tap] 异常 %@", e.reason); }
    }
}

static void KZTogglePause(void) {
    id rec = KZRecorder();
    if (!rec) return;
    BOOL want = !gPaused;
    // 优先 setPaused:
    SEL sp = NSSelectorFromString(@"setPaused:");
    BOOL ok = NO;
    if ([rec respondsToSelector:sp]) {
        @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(rec, sp, want); ok = YES; } @catch (...) {}
    }
    if (!ok) {
        SEL s = NSSelectorFromString(want ? @"pauseInAppRecording" : @"resumeInAppRecording");
        if ([rec respondsToSelector:s]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(rec, s); ok = YES; } @catch (...) {}
        }
    }
    if (ok) {
        gPaused = want;
        if (want) { gPausedAt = CFAbsoluteTimeGetCurrent(); }
        else if (gPausedAt > 0) { gPausedTotal += CFAbsoluteTimeGetCurrent() - gPausedAt; gPausedAt = 0; }
        PLog(@"[tap] %@ 录屏 %@", want ? @"暂停" : @"恢复", ok ? @"成功" : @"失败");
    } else {
        PLog(@"[tap] 没有可用的暂停接口");
    }
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

#pragma mark - 写轮眼

@interface KZEyeDot : UIView
@property (nonatomic, strong) UIImageView *img;
@property (nonatomic) CGFloat side;
@end
@implementation KZEyeDot
- (void)layoutSubviews { [super layoutSubviews]; self.img.frame = self.bounds; }
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
    if (side < 14) side = 14;
    if (side > 40) side = 40;
    return side;
}

#pragma mark - 计时 + 停止（自己画的，带精确点击）

@interface KZTimerView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIView *stopBtn;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation KZTimerView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        CGFloat stopW = 22;
        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - stopW - 4, frame.size.height)];
        _label.tag = KZ_TIMER_TAG;
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        _label.textAlignment = NSTextAlignmentRight;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.7;
        _label.userInteractionEnabled = YES;
        [self addSubview:_label];

        _stopBtn = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - stopW, (frame.size.height - stopW) / 2.0, stopW, stopW)];
        _stopBtn.tag = KZ_STOP_TAG;
        _stopBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _stopBtn.layer.cornerRadius = 5.0;
        _stopBtn.userInteractionEnabled = YES;
        // 里面的小方块
        UIView *sq = [[UIView alloc] initWithFrame:CGRectMake(7, 7, 8, 8)];
        sq.backgroundColor = [UIColor whiteColor];
        sq.layer.cornerRadius = 1.5;
        sq.userInteractionEnabled = NO;
        [_stopBtn addSubview:sq];
        [self addSubview:_stopBtn];

        UITapGestureRecognizer *tapStop = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onStop)];
        [_stopBtn addGestureRecognizer:tapStop];
        UITapGestureRecognizer *tapPause = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onPause)];
        [_label addGestureRecognizer:tapPause];

        [self kzStart];
    }
    return self;
}
- (void)onStop { KZStopRecording(); }
- (void)onPause { KZTogglePause(); }
- (void)kzStart {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        self.label.text = KZElapsedText();
        self.label.alpha = gPaused ? 0.45 : 1.0;
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)kzStop { [self.timer invalidate]; self.timer = nil; }
- (void)dealloc { [self kzStop]; }
@end

#pragma mark - 自建 element

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
    if (!_eye) { _eye = KZMakeEye(KZEyeSide()); PLog(@"[prov] 写轮眼 %.0f", _eye.side); }
    return _eye;
}
- (KZEyeDot *)minEye {
    if (!_minEye) _minEye = KZMakeEye(KZEyeSide() * 0.68);
    return _minEye;
}
- (KZTimerView *)timerView {
    if (!_timerView) {
        CGFloat h = 22;
        _timerView = [[KZTimerView alloc] initWithFrame:CGRectMake(0, 0, 68, h)];
        PLog(@"[prov] 计时+停止 68x22");
    }
    return _timerView;
}

- (UIView *)leadingView { KZOnce(@"lead", @"[prov] leadingView"); return [self eye]; }
- (UIView *)expandedLeadingView { return [self eye]; }
- (UIView *)minimalView { KZOnce(@"min", @"[prov] minimalView"); return [self minEye]; }
- (UIView *)trailingView { KZOnce(@"trail", @"[prov] trailingView"); return [self timerView]; }
- (UIView *)expandedTrailingView { return [self timerView]; }

- (NSInteger)layoutMode { return _layoutMode; }
- (NSInteger)preferredLayoutMode { return 2; }
- (NSInteger)maximumSupportedLayoutMode { return 2; }
- (NSInteger)minimumSupportedLayoutMode { return 0; }
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason { _layoutMode = mode; }

- (CGSize)sizeThatFitsSize:(CGSize)size forProvidedView:(UIView *)view inLayoutMode:(NSInteger)mode {
    if (view == _eye) return CGSizeMake(_eye.side, _eye.side);
    if (view == _minEye) return CGSizeMake(_minEye.side, _minEye.side);
    if (view == _timerView) return CGSizeMake(68, 22);
    return CGSizeMake(22, 22);
}
- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode suggestedOutsets:(NSDirectionalEdgeInsets)sug maximumOutsets:(NSDirectionalEdgeInsets)mx { return sug; }
- (BOOL)isProvidedViewConcentric:(UIView *)view inLayoutMode:(NSInteger)mode { return YES; }
- (BOOL)isMinimalPresentationPossible { return YES; }
- (BOOL)isInteractiveDismissalEnabled { return NO; }
- (BOOL)isRequestingMenuPresentation { return NO; }

- (BOOL)handleElementViewEvent:(long long)event {
    PLog(@"[tap] handleElementViewEvent %lld", event);
    if ((unsigned long long)event == 1) { KZStopRecording(); return YES; }   // leading = 写轮眼 → 停止
    if ((unsigned long long)event == 2) { KZTogglePause(); return YES; }     // trailing → 暂停
    if ((unsigned long long)event == 3) { KZStopRecording(); return YES; }   // minimal → 停止
    return NO;
}

- (void)setActivityHost:(id)host {}
- (id)activityHost { return nil; }
- (void)setElementHost:(id)host {}
- (id)elementHost { return nil; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

#pragma mark - 假 assertion

@interface KZDummyAssertion : NSObject
@end
@implementation KZDummyAssertion
- (BOOL)isValid { return YES; }
- (void)invalidate {}
- (void)invalidateWithReason:(id)r { PLog(@"[sup] dummy invalidate %@", r); }
- (id)element { return nil; }
- (id)invalidationReason { return nil; }
@end

#pragma mark - 状态

static id gManager = nil;
static id gProvider = nil;
static id gAssertion = nil;
static BOOL gSuppressOn = NO;

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
    if (!s.length) return NO;
    NSString *l = s.lowercaseString;
    return [l containsString:@"screenrecording"] ||
           [l containsString:@"recordingindicator"] ||
           [l containsString:@"sbrecording"];
}

#pragma mark - hook registerElement（两个类都要）

static id (*origRegVC)(id, SEL, id);
static id kzRegVC(id self, SEL _cmd, id element) {
    if (gSuppressOn && KZIsRecordingElem(element)) {
        PLog(@"[sup] VC 拦截录屏 element 注册：%@", KZElemIdent(element) ?: @"?");
        return [[KZDummyAssertion alloc] init];
    }
    return origRegVC ? origRegVC(self, _cmd, element) : nil;
}

static id (*origRegMgr)(id, SEL, id);
static id kzRegMgr(id self, SEL _cmd, id element) {
    if (gSuppressOn && KZIsRecordingElem(element) && element != gProvider) {
        PLog(@"[sup] Manager 拦截录屏 element 注册：%@", KZElemIdent(element) ?: @"?");
        return [[KZDummyAssertion alloc] init];
    }
    return origRegMgr ? origRegMgr(self, _cmd, element) : nil;
}

static void (*origPromote)(id, SEL);
static void kzPromote(id self, SEL _cmd) {
    if (!gManager) {
        gManager = self;
        PLog(@"[init] manager = %@", NSStringFromClass([self class]));
    }
    @try { if (origPromote) origPromote(self, _cmd); } @catch (...) {}
}

#pragma mark - 强制移除系统录屏 element

static void KZPurgeSystemRecordingElements(void) {
    if (!gManager) return;
    SEL rg = NSSelectorFromString(@"registeredElements");
    if (![gManager respondsToSelector:rg]) return;
    NSArray *list = ((id (*)(id, SEL))objc_msgSend)(gManager, rg);
    if (![list isKindOfClass:[NSArray class]]) return;

    for (id e in [list copy]) {
        if (e == gProvider) continue;
        if (!KZIsRecordingElem(e)) continue;

        SEL ae = NSSelectorFromString(@"elementAssertionForElement:");
        id as = nil;
        if ([gManager respondsToSelector:ae]) {
            @try { as = ((id (*)(id, SEL, id))objc_msgSend)(gManager, ae, e); } @catch (...) {}
        }
        SEL rm = NSSelectorFromString(@"_removeAssertionForElement:");
        if ([gManager respondsToSelector:rm]) {
            @try { ((void (*)(id, SEL, id))objc_msgSend)(gManager, rm, e); } @catch (...) {}
        }
        if (as) {
            SEL inv = NSSelectorFromString(@"invalidate");
            if ([as respondsToSelector:inv]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(as, inv); } @catch (...) {}
            }
        }
        PLog(@"[sup] 已强制移除系统录屏 element %@（assertion=%@）",
             KZElemIdent(e) ?: @"?", as ? NSStringFromClass([as class]) : @"nil");
    }
}

#pragma mark - 注册 / 注销

static void KZRemoveOwnElement(void) {
    if (!gManager || !gProvider) return;
    SEL rm = NSSelectorFromString(@"_removeAssertionForElement:");
    if ([gManager respondsToSelector:rm]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(gManager, rm, gProvider); } @catch (...) {}
    }
    if (gAssertion) {
        SEL inv = NSSelectorFromString(@"invalidate");
        if ([gAssertion respondsToSelector:inv]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(gAssertion, inv); } @catch (...) {}
        }
    }
}

static void KZUnregister(void) {
    if (gProvider) {
        KZRemoveOwnElement();
        PLog(@"[reg] 已移除自己的 element");
    }
    gAssertion = nil;
    gProvider = nil;
    gSuppressOn = NO;
}

static void KZRegister(void) {
    if (gProvider || !gManager) return;
    if (!KZPrefBool(@"enabled", YES)) return;
    @try {
        gProvider = [[KZElementProvider alloc] init];

        SEL reg = NSSelectorFromString(@"registerElement:");
        id a = ((id (*)(id, SEL, id))objc_msgSend)(gManager, reg, gProvider);
        gAssertion = a;
        gSuppressOn = (a != nil);
        PLog(@"[reg] 注册 -> %@（抑制=%@）", a ? NSStringFromClass([a class]) : @"nil", gSuppressOn ? @"开" : @"关");

        SEL rg = NSSelectorFromString(@"registeredElements");
        if ([gManager respondsToSelector:rg]) {
            NSArray *rs = ((id (*)(id, SEL))objc_msgSend)(gManager, rg);
            NSMutableString *m = [NSMutableString string];
            for (id e in rs) [m appendFormat:@"%@ ", KZElemIdent(e) ?: @"?"];
            PLog(@"[reg] registeredElements=%lu -> %@", (unsigned long)rs.count, m);
        }

        if (gSuppressOn) KZPurgeSystemRecordingElements();

        SEL setL = NSSelectorFromString(@"setLayoutMode:reason:forTargetWithOverrider:");
        if ([gManager respondsToSelector:setL]) {
            @try { ((void (*)(id, SEL, long, long, id))objc_msgSend)(gManager, setL, 2, 0, gProvider); } @catch (...) {}
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

#pragma mark - hooks

static BOOL gHookDone = NO;
static void KZInstallHooks(void) {
    if (gHookDone) return;
    int n = 0;
    SEL reg = NSSelectorFromString(@"registerElement:");

    Class vc = NSClassFromString(@"SBSystemApertureViewController");
    if (vc && [vc instancesRespondToSelector:reg]) {
        MSHookMessageEx(vc, reg, (IMP)kzRegVC, (IMP *)&origRegVC);
        n++;
        PLog(@"[hook] SBSystemApertureViewController registerElement:");
    }
    Class mgr = NSClassFromString(@"SAUISystemApertureManager");
    if (mgr && [mgr instancesRespondToSelector:reg]) {
        MSHookMessageEx(mgr, reg, (IMP)kzRegMgr, (IMP *)&origRegMgr);
        n++;
        PLog(@"[hook] SAUISystemApertureManager registerElement:");
    }
    if (mgr) {
        SEL prom = NSSelectorFromString(@"invalidatePromotedElements");
        if ([mgr instancesRespondToSelector:prom]) {
            MSHookMessageEx(mgr, prom, (IMP)kzPromote, (IMP *)&origPromote);
        }
    }
    if (n) { gHookDone = YES; PLog(@"[hook] 共 %d 个 registerElement", n); }
}

#pragma mark - 主循环

static NSTimer *gTimer = nil;
static BOOL gWasCaptured = NO;

static void KZTick(void) {
    KZInstallHooks();
    BOOL cap = KZCaptured();
    if (cap && !gWasCaptured) {
        gWasCaptured = YES;
        gStartAt = CFAbsoluteTimeGetCurrent();
        gPaused = NO; gPausedAt = 0; gPausedTotal = 0;
        gSeen = nil;
        PLog(@"[state] 录屏开始");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!KZCaptured()) return;
            KZRegister();
            // 注册后持续清理系统录屏 element（防它重建）
            for (int i = 0; i < 12; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.4 + i * 0.35) * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (KZCaptured() && gSuppressOn) KZPurgeSystemRecordingElements();
                });
            }
        });
    } else if (!cap && gWasCaptured) {
        gWasCaptured = NO;
        gStartAt = 0;
        gPaused = NO;
        gSeen = nil;
        KZUnregister();
        PLog(@"[state] 录屏结束");
    } else if (cap && gSuppressOn) {
        // 录屏中定期清理（系统可能在暂停/恢复时重建）
        static int tickCount = 0;
        if (++tickCount % 4 == 0) KZPurgeSystemRecordingElements();
    }
}

static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSeen = nil;
        PLog(@"[apply] scale=%.2f offX=%.1f dur=%.2f", KZPrefNum(@"scale", 1.0),
             KZPrefNum(@"offX", 0.0), KZPrefNum(@"duration", 1.5));
        if (gProvider) {
            KZUnregister();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (KZCaptured()) { KZRegister(); }
            });
        }
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.45 (purge system element, precise taps)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZInstallHooks();
        if (!gTimer || !gTimer.valid) {
            gTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                @try { KZTick(); } @catch (NSException *e) { PLog(@"[tick] %@", e.reason); }
            }];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        }
    });
}