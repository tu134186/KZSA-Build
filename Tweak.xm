#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

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
static void KZRegisterOnce(void);

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

@interface KZElementProvider : NSObject

@end

@implementation KZElementProvider

- (NSString *)elementIdentifier { return @"KZSharinganElement"; }
- (NSString *)identifier { return @"KZSharinganElement"; }
- (NSString *)description { return @"KZSharinganElement"; }

- (UIView *)kzMakeView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = 11.0;
    v.layer.masksToBounds = YES;
    UIImage *img = [UIImage imageWithContentsOfFile:@"/Library/KZTheme/eye/tomoe2.png"];
    if (!img) img = [UIImage imageWithContentsOfFile:@"/Library/KZTheme/eye/tomoe.png"];
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
- (NSInteger)minimumLayoutMode { return 0; }

- (NSString *)clientIdentifier { return @"com.minis.kzsa"; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

static id gProvider = nil;
static id gAssertion = nil;

static void KZRegisterOnce(void) {
    static BOOL done = NO;
    if (done || !gManager) return;
    done = YES;
    @try {
        gProvider = [[KZElementProvider alloc] init];
        SEL reg = NSSelectorFromString(@"registerElement:");
        ((void (*)(id, SEL, id))objc_msgSend)(gManager, reg, gProvider);
        PLog(@"[reg] registerElement 完成");
        SEL as = NSSelectorFromString(@"_assertionForElementCreatingIfNecessary:");
        id a = ((id (*)(id, SEL, id))objc_msgSend)(gManager, as, gProvider);
        gAssertion = a;
        PLog(@"[reg] assertion = %@", a ? NSStringFromClass([a class]) : @"nil");
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
    }
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
    PLog(@"springboard launched (v1.19)");
    return r;
}

%end

%ctor {
    PLog(@"ctor v1.25 (authority probe)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try {
                KZTryHook();
                KZReport();
            } @catch (...) {
                PLog(@"[tick] 异常已忽略");
            }
        }];
    });
}
