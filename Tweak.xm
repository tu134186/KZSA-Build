#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import "kzeye_b64.h"

#define KZ_DOMAIN "com.minis.kzprobe"

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

static id gManager = nil;
static id gProvider = nil;
static __unsafe_unretained id gActivityHost = nil;
static __unsafe_unretained id gElementHost = nil;
static BOOL gLaunched = NO;
static double gLaunchAt = 0;
static double gCtorAt = 0;
static void KZRegisterOnce(void);
static void KZProbeAuthority(id mgr);
static void KZReportOrder(void);
static BOOL (*origNeg)(id, SEL, id);
static BOOL kzNeg(id self, SEL _cmd, id elem);
static id (*origElemVC)(id, SEL, id);
static id kzElemVC(id self, SEL _cmd, id elem);

// 只在 manager 被创建时抓实例，不做任何遍历
static id (*origInit)(id, SEL, id);
static id kzInit(id self, SEL _cmd, id authority) {
    id r = nil;
    @try {
        r = origInit ? origInit(self, _cmd, authority) : nil;
    } @catch (...) {
        PLog(@"[init] 原实现抛出异常，已忽略");
        r = self;
    }
    if (r && !gManager) {
        gManager = r;
        PLog(@"[init] 抓到 manager: %@", NSStringFromClass([r class]));
    }
    return r;
}

static void (*origWillLayout)(id, SEL);
static void kzWillLayout(id self, SEL _cmd) {
    if (!gManager) {
        gManager = self;
        PLog(@"[init] 从 hostWillPerformLayout 抓到: %@", NSStringFromClass([self class]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KZRegisterOnce(); });
    }
    @try { if (origWillLayout) origWillLayout(self, _cmd); } @catch (...) {}
}

static void (*origPromote)(id, SEL);
static void kzPromote(id self, SEL _cmd) {
    if (!gManager) {
        gManager = self;
        PLog(@"[init] 从 invalidatePromotedElements 抓到: %@", NSStringFromClass([self class]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KZRegisterOnce(); });
    }
    @try { if (origPromote) origPromote(self, _cmd); } @catch (...) {}
}


#pragma mark - element provider


#pragma mark - SystemAperture 私有协议（公开 SDK 没有，自己声明）

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

@interface KZElementProvider : NSObject <SAElement, SAElementViewProviding, SAActivityBehavior, SAUILayoutSpecifying>

@end

@implementation KZElementProvider

- (NSString *)elementIdentifier { return @"KZSharinganElement"; }
- (NSString *)identifier { return @"KZSharinganElement"; }
- (NSString *)description { return @"KZSharinganElement"; }

static UIImage *KZEyeImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:kKZeyeB64]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d) img = [UIImage imageWithData:d];
        if (!img) img = [UIImage imageWithContentsOfFile:@"/Library/KZTheme/eye/tomoe2.png"];
        if (!img) img = [UIImage imageWithContentsOfFile:@"/Library/KZTheme/eye/tomoe.png"];
        PLog(@"[prov] eye image = %@", img ? [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height] : @"nil");
    });
    return img;
}

- (UIView *)kzMakeView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = 11.0;
    v.layer.masksToBounds = YES;
    UIImage *img = KZEyeImage();
    if (!img) v.backgroundColor = [UIColor redColor];
    if (img) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.frame = v.bounds;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        [v addSubview:iv];
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(M_PI * 2.0);
        spin.duration = 1.5;
        spin.repeatCount = INFINITY;
        [iv.layer addAnimation:spin forKey:@"kzspin"];
    }
    return v;
}

- (UIView *)leadingView { PLog(@"[prov] leadingView"); return [self kzMakeView]; }
- (UIView *)trailingView { return nil; }
- (UIView *)minimalView { PLog(@"[prov] minimalView"); return [self kzMakeView]; }
- (UIView *)expandedLeadingView { return [self kzMakeView]; }
- (UIView *)expandedTrailingView { return nil; }

- (NSInteger)preferredLayoutMode { PLog(@"[prov] preferredLayoutMode"); return 2; }
- (NSInteger)maximumSupportedLayoutMode { PLog(@"[prov] maxLayoutMode"); return 3; }
- (NSInteger)minimumSupportedLayoutMode { return 0; }
- (NSInteger)minimumLayoutMode { return 0; }
- (NSInteger)layoutMode { return 2; }
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    PLog(@"[prov] setLayoutMode:%ld reason:%ld", (long)mode, (long)reason);
}
// 下面是 SAUILayoutSpecifying 里的结构化返回方法：不显式实现的话，
// forwardInvocation 会用 "@@:" 顶替，返回结构体时长度不匹配会崩（1.27 补）
- (CGSize)sizeThatFitsSize:(CGSize)size forProvidedView:(UIView *)view inLayoutMode:(NSInteger)mode {
    if (size.width > 10000.0 || size.height > 10000.0) PLog(@"[prov] sizeThatFits inf mode=%ld", (long)mode);
    else PLog(@"[prov] sizeThatFits %.0fx%.0f mode=%ld", size.width, size.height, (long)mode);
    return CGSizeMake(22, 22);
}
- (BOOL)isProvidedViewConcentric:(UIView *)view inLayoutMode:(NSInteger)mode { return YES; }
- (BOOL)isInteractiveDismissalEnabled { return NO; }
- (BOOL)isMinimalPresentationPossible { return YES; }
- (BOOL)isRequestingMenuPresentation { return NO; }
- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode suggestedOutsets:(NSDirectionalEdgeInsets)suggested maximumOutsets:(NSDirectionalEdgeInsets)maximum {
    return suggested;
}

- (NSString *)clientIdentifier { return @"com.minis.kzsa"; }

// 1.29：manager 的 _elementViewControllerForElement:creatingIfNecessary: 里，
// 如果 element 既没有 alert 也没有 activity 行为，会直接返回 nil（这就是 1.27 的 [vc] ... -> nil）
- (BOOL)hasActivityBehavior { PLog(@"[prov] hasActivityBehavior"); return YES; }
- (BOOL)hasAlertBehavior { return NO; }
- (id)activityHost { return gActivityHost; }
- (id)elementHost { return gElementHost; }
- (void)setElementHost:(id)host { gElementHost = host; PLog(@"[prov] setElementHost %@", host ? NSStringFromClass([host class]) : @"nil"); }
- (void)setActivityHost:(id)host { gActivityHost = host; PLog(@"[prov] setActivityHost %@", host ? NSStringFromClass([host class]) : @"nil"); }

// SAElement 要求 viewProvider；SAElementViewProviding 要求 element —— 两个都必须返回 self，
// 否则 manager 拿到 nil 会直接跳过这个 element（1.27 补上）
- (id)viewProvider { PLog(@"[prov] viewProvider"); return self; }
- (id)element { PLog(@"[prov] element"); return self; }
- (BOOL)_canShowWhileLocked { return YES; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

static id gAssertion = nil;
static __unsafe_unretained id gAuthority = nil;
static id (*origElemVCC)(id, SEL, id, BOOL);
static int gVCNilCount = 0;
static BOOL gVCGaveUp = NO;
static NSArray *(*origProbeOrder)(id, SEL, NSArray *, NSArray *);

static NSString *KZElemID(id elem) {
    @try {
        SEL es = NSSelectorFromString(@"elementIdentifier");
        if (elem && [elem respondsToSelector:es]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(elem, es);
            if ([v isKindOfClass:[NSString class]]) return v;
        }
    } @catch (NSException *e) {}
    return @"?";
}

// 1.27：authority 是 <SAElementConsidering>，它的 order 方法决定谁能进入 promoted 列表
static NSArray *kzOrder(id self, SEL _cmd, NSArray *temporal, NSArray *prev) {
    NSArray *r = temporal;
    @try { if (origProbeOrder) r = origProbeOrder(self, _cmd, temporal, prev); } @catch (...) {}
    BOOL inT = (gProvider && [temporal containsObject:gProvider]);
    BOOL inR = (gProvider && [r containsObject:gProvider]);
    PLog(@"[au] order temporal=%lu contains=%d out=%lu contains=%d",
         (unsigned long)temporal.count, inT, (unsigned long)r.count, inR);
    if (gProvider && !inR) {
        @try {
            r = [(r ?: @[]) arrayByAddingObject:gProvider];
            PLog(@"[au] 追加 KZElement -> %lu", (unsigned long)r.count);
        } @catch (NSException *e) { PLog(@"[au] 追加异常 %@", e.reason); }
    }
    return r;
}

static id kzElemVCC(id self, SEL _cmd, id elem, BOOL create) {
    id r = nil;
    @try { r = origElemVCC ? origElemVCC(self, _cmd, elem, create) : nil; } @catch (...) {}
    PLog(@"[vc] _elemVC(%@) create=%d -> %@", KZElemID(elem), create, r ? NSStringFromClass([r class]) : @"nil");

    // 安全网：我们的 element 如果一直造不出 VC，会让系统录屏 element 也被卡住不显示。
    // 连续 8 次仍为 nil 就释放 assertion，把系统恢复原状（下个版本再修）。
    if (create && !r && elem == gProvider) {
        gVCNilCount++;
        PLog(@"[vc] KZ 的 VC 仍为 nil（第 %d 次）", gVCNilCount);
        if (gVCNilCount >= 8 && !gVCGaveUp) {
            gVCGaveUp = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    SEL inv = NSSelectorFromString(@"invalidate");
                    if (gAssertion && [gAssertion respondsToSelector:inv]) {
                        ((void (*)(id, SEL))objc_msgSend)(gAssertion, inv);
                        PLog(@"[vc] 已放弃并 invalidate assertion，恢复系统录屏");
                    }
                } @catch (NSException *e) { PLog(@"[vc] invalidate 异常 %@", e.reason); }
            });
        }
    }
    return r;
}

static void KZProbeAuthority(id mgr) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    @try {
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList([mgr class], &ic);
        NSMutableString *s = [NSMutableString string];
        for (unsigned i = 0; i < ic && i < 24; i++) {
            const char *n = ivar_getName(ivs[i]);
            [s appendFormat:@"%s ", n ? n : "?"];
        }
        if (ivs) free(ivs);
        PLog(@"[au] manager(%s) ivars: %@", class_getName([mgr class]), s);

        Ivar iv = class_getInstanceVariable([mgr class], "_elementAuthority");
        id au = iv ? object_getIvar(mgr, iv) : nil;
        PLog(@"[au] _elementAuthority = %@", au ? NSStringFromClass([au class]) : @"nil");
        if (!au) {
            iv = class_getInstanceVariable([mgr class], "_delegate");
            au = iv ? object_getIvar(mgr, iv) : nil;
            PLog(@"[au] _delegate = %@", au ? NSStringFromClass([au class]) : @"nil");
        }
        if (!au) return;
        gAuthority = au;

        unsigned int mc = 0;
        Method *ms = class_copyMethodList([au class], &mc);
        NSMutableString *m = [NSMutableString string];
        for (unsigned i = 0; i < mc && i < 20; i++) [m appendFormat:@"%@ ", NSStringFromSelector(method_getName(ms[i]))];
        if (ms) free(ms);
        PLog(@"[au] methods(%u): %@", mc, m);

        SEL os = NSSelectorFromString(@"elementsOrderedByPromotionFromTemporallyOrderedElements:withPreviousOrdering:");
        if (class_getInstanceMethod([au class], os)) {
            MSHookMessageEx([au class], os, (IMP)kzOrder, (IMP *)&origProbeOrder);
            PLog(@"[au] hook order 成功");
        } else {
            PLog(@"[au] order 方法不存在");
        }

        SEL vcs = NSSelectorFromString(@"_elementViewControllerForElement:creatingIfNecessary:");
        if (class_getInstanceMethod([mgr class], vcs)) {
            MSHookMessageEx([mgr class], vcs, (IMP)kzElemVCC, (IMP *)&origElemVCC);
            PLog(@"[vc] hook _elementVC 成功");
        } else {
            PLog(@"[vc] _elementVC 不存在");
        }
    } @catch (NSException *e) { PLog(@"[au] 异常 %@", e.reason); }
}

static void KZRegisterOnce(void) {
    static BOOL done = NO;
    if (done || !gManager) return;
    // 1.28：必须等 SpringBoard 启动完成后再注册，否则会在启动过程中创建 element/VC 把 SpringBoard 搞崩
    if (!gLaunched) return;
    if (gLaunchAt > 0 && CACurrentMediaTime() - gLaunchAt < 2.0) return;
    done = YES;
    @try {
        gProvider = [[KZElementProvider alloc] init];
        KZProbeAuthority(gManager);
        SEL reg = NSSelectorFromString(@"registerElement:");
        ((void (*)(id, SEL, id))objc_msgSend)(gManager, reg, gProvider);
        PLog(@"[reg] registerElement 完成");
        SEL as = NSSelectorFromString(@"_assertionForElementCreatingIfNecessary:");
        id a = ((id (*)(id, SEL, id))objc_msgSend)(gManager, as, gProvider);
        gAssertion = a;
        PLog(@"[reg] assertion = %@", a ? NSStringFromClass([a class]) : @"nil");
        SEL rg = NSSelectorFromString(@"registeredElements");
        if ([gManager respondsToSelector:rg]) {
            NSArray *regs = ((id (*)(id, SEL))objc_msgSend)(gManager, rg);
            PLog(@"[reg] registeredElements=%lu contains=%d authority=%d", (unsigned long)regs.count, [regs containsObject:gProvider], gAuthority != nil);
        }
            SEL setL = NSSelectorFromString(@"setLayoutMode:reason:forTargetWithOverrider:");
            if ([gManager respondsToSelector:setL]) {
                @try {
                    ((void(*)(id,SEL,long,long,id))objc_msgSend)(gManager, setL, 2, 0, gProvider);
                    PLog(@"[reg] setLayoutMode:2 已调用");
                } @catch (NSException *e) { PLog(@"[reg] setLayoutMode 异常: %@", e.reason); }
            } else {
                PLog(@"[reg] setLayoutMode 不存在");
            }
            SEL inval = NSSelectorFromString(@"invalidatePromotedElements");
            if ([gManager respondsToSelector:inval]) {
                @try { ((void(*)(id,SEL))objc_msgSend)(gManager, inval); PLog(@"[reg] invalidate 已调用"); }
                @catch (NSException *e) { PLog(@"[reg] invalidate 异常"); }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KZReportOrder(); });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KZReportOrder(); });
            }
    } @catch (NSException *e) {
        PLog(@"[reg] 异常: %@", e.reason);
    }
}

static BOOL gHooked = NO;
static BOOL gHooked2 = NO;
static void KZTryHook(void) {
    if (gHooked) return;
    Class c = NSClassFromString(@"SAUISystemApertureManager");
    if (!c) return;
    SEL sel = NSSelectorFromString(@"initWithElementAuthority:");
    if (![c instancesRespondToSelector:sel]) {
        PLog(@"[hook] 没有 initWithElementAuthority:");
        gHooked = YES;
        return;
    }
    MSHookMessageEx(c, sel, (IMP)kzInit, (IMP *)&origInit);
    gHooked = YES;
    PLog(@"[hook] 已 hook initWithElementAuthority:");
    if (!gHooked2) {
        SEL s1 = NSSelectorFromString(@"hostWillPerformLayout");
        SEL s2 = NSSelectorFromString(@"invalidatePromotedElements");
        BOOL ok1 = [c instancesRespondToSelector:s1];
        BOOL ok2 = [c instancesRespondToSelector:s2];
        if (ok1) MSHookMessageEx(c, s1, (IMP)kzWillLayout, (IMP *)&origWillLayout);
        if (ok2) MSHookMessageEx(c, s2, (IMP)kzPromote, (IMP *)&origPromote);
        gHooked2 = YES;
        PLog(@"[hook] hostWillPerformLayout:%d invalidatePromotedElements:%d", ok1, ok2);

        SEL nSel = NSSelectorFromString(@"elementRequestsNegativeResponse:");
        if (class_getInstanceMethod(c, nSel)) {
            MSHookMessageEx(c, nSel, (IMP)kzNeg, (IMP *)&origNeg);
            PLog(@"[auth] hook negativeResponse");
        } else PLog(@"[auth] negativeResponse 不存在");

        SEL vSel = NSSelectorFromString(@"elementViewControllerForElement:");
        if (class_getInstanceMethod(c, vSel)) {
            MSHookMessageEx(c, vSel, (IMP)kzElemVC, (IMP *)&origElemVC);
            PLog(@"[auth] hook elementViewControllerForElement");
        } else PLog(@"[auth] elementViewControllerForElement 不存在");
    }
}

static void KZReportOrder(void) {
    if (!gManager) return;
    @try {
        SEL s = NSSelectorFromString(@"orderedElementViewControllers");
        if (![gManager respondsToSelector:s]) { PLog(@"[reg] orderedVC 方法不存在"); return; }
        NSArray *vcs = ((id (*)(id, SEL))objc_msgSend)(gManager, s);
        NSMutableString *m = [NSMutableString string];
        for (id vc in vcs) {
            @try {
                SEL evp = NSSelectorFromString(@"elementViewProvider");
                id vp = [vc respondsToSelector:evp] ? ((id (*)(id, SEL))objc_msgSend)(vc, evp) : nil;
                SEL es = NSSelectorFromString(@"element");
                id el = (vp && [vp respondsToSelector:es]) ? ((id (*)(id, SEL))objc_msgSend)(vp, es) : nil;
                [m appendFormat:@"%@ ", KZElemID(el)];
            } @catch (NSException *e) { [m appendString:@"? "]; }
        }
        PLog(@"[reg] orderedVC=%lu ids=%@", (unsigned long)vcs.count, m);
    } @catch (NSException *e) { PLog(@"[reg] orderedVC 异常 %@", e.reason); }
}

// 定期把能力检查写一次（只读，不调用）
static void KZReport(void) {
    if (!gManager) return;
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSArray *sels = @[ @"registerElement:", @"_assertionForElementCreatingIfNecessary:",
                       @"elementAssertionForElement:", @"registeredElements", @"orderedElementViewControllers" ];
    NSMutableString *line = [NSMutableString string];
    for (NSString *s in sels) {
        BOOL ok = [gManager respondsToSelector:NSSelectorFromString(s)];
        [line appendFormat:@"%@:%@ ", s, ok ? @"YES" : @"NO"];
    }
    PLog(@"[cap] %@", line);
}

%hook SpringBoard

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL r = %orig;
    gLaunched = YES;
    gLaunchAt = CACurrentMediaTime();
    PLog(@"[boot] SpringBoard didFinishLaunching");
    return r;
}

%end

%ctor {
    gCtorAt = CACurrentMediaTime();
    PLog(@"ctor v1.30 (visible + order diag)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try {
                // 兜底：万一 didFinishLaunching 的 hook 没触发，10s 后也认为启动完成
                if (!gLaunched && gCtorAt > 0 && CACurrentMediaTime() - gCtorAt > 10.0) {
                    gLaunched = YES;
                    gLaunchAt = CACurrentMediaTime();
                    PLog(@"[boot] fallback 启动判定（didFinishLaunching 未触发）");
                }
                KZTryHook();
                KZRegisterOnce();
                KZReport();
            } @catch (...) {
                PLog(@"[tick] 异常已忽略");
            }
        }];
    });
}


static BOOL kzNeg(id self, SEL _cmd, id elem) {
    BOOL r = origNeg ? origNeg(self, _cmd, elem) : NO;
    NSString *eid = @"?";
    @try {
        SEL es = NSSelectorFromString(@"elementIdentifier");
        if (elem && [elem respondsToSelector:es]) {
            eid = ((id (*)(id, SEL))objc_msgSend)(elem, es);
        }
    } @catch (NSException *e) {}
    PLog(@"[auth] negativeResponse(%@)=%d", eid, r);
    return r;
}

static id kzElemVC(id self, SEL _cmd, id elem) {
    id r = origElemVC ? origElemVC(self, _cmd, elem) : nil;
    NSString *eid = @"?";
    @try {
        SEL es = NSSelectorFromString(@"elementIdentifier");
        if (elem && [elem respondsToSelector:es]) {
            eid = ((id (*)(id, SEL))objc_msgSend)(elem, es);
        }
    } @catch (NSException *e) {}
    PLog(@"[auth] elementVC(%@) -> %@", eid, r ? NSStringFromClass([r class]) : @"nil");
    return r;
}
