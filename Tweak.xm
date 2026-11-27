#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <substrate.h>

#define KZ_DOMAIN "com.minis.kzprobe"
#define KZ_PREF_DOMAIN "com.minis.kzsa"
#define KZ_EYE @"/Library/KZTheme/eye/tomoe2.png"
#define KZ_EYE_ALT @"/Library/KZTheme/eye/tomoe.png"

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

#pragma mark - 偏好

static BOOL KZPrefBool(NSString *key, BOOL dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KZ_PREF_DOMAIN));
    if (!v) return dflt;
    BOOL b = [(__bridge NSNumber *)v boolValue];
    CFRelease(v);
    return b;
}
static double KZPrefDouble(NSString *key, double dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KZ_PREF_DOMAIN));
    if (!v) return dflt;
    double d = [(__bridge NSNumber *)v doubleValue];
    CFRelease(v);
    return d;
}
static UIImage *KZUserImage(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("eyeImage"), CFSTR(KZ_PREF_DOMAIN));
    if (!v) return nil;
    NSString *b64 = [NSString stringWithFormat:@"%@", (__bridge id)v];
    CFRelease(v);
    if (b64.length < 200) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return d.length > 200 ? [UIImage imageWithData:d] : nil;
}

#pragma mark - 视图

static UIView *KZSharinganView(void) {
    double scale = KZPrefDouble(@"scale", 1.0);
    if (scale < 0.3) scale = 1.0;
    double offx = KZPrefDouble(@"offX", 0.0);
    CGFloat side = MIN(22.0 * scale, 22.0);

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    box.backgroundColor = [UIColor clearColor];

    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(offx, 0, side, side)];
    circle.backgroundColor = [UIColor blackColor];
    circle.layer.cornerRadius = side / 2.0;
    circle.layer.masksToBounds = YES;
    [box addSubview:circle];

    UIImage *img = KZUserImage();
    if (!img) img = [UIImage imageWithContentsOfFile:KZ_EYE];
    if (!img) img = [UIImage imageWithContentsOfFile:KZ_EYE_ALT];
    if (img) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        CGFloat pad = side * 0.032;
        iv.frame = CGRectInset(circle.bounds, -pad, -pad);
        iv.contentMode = UIViewContentModeScaleAspectFill;
        [circle addSubview:iv];

        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(M_PI * 2.0);
        spin.duration = KZPrefDouble(@"duration", 1.5);
        spin.repeatCount = INFINITY;
        [iv.layer addAnimation:spin forKey:@"kzspin"];
    }
    return box;
}

#pragma mark - 自己的 element provider

@interface KZElementProvider : NSObject
@property (nonatomic, strong) UIView *sharedView;
@end

@implementation KZElementProvider

- (NSString *)elementIdentifier { return @"KZSharinganElement"; }
- (NSString *)identifier { return @"KZSharinganElement"; }

- (UIView *)leadingView {
    PLog(@"[prov] leadingView");
    return KZSharinganView();
}
- (UIView *)trailingView {
    PLog(@"[prov] trailingView");
    return nil;
}
- (UIView *)minimalView {
    PLog(@"[prov] minimalView");
    return KZSharinganView();
}
- (UIView *)expandedLeadingView {
    PLog(@"[prov] expandedLeadingView");
    return KZSharinganView();
}
- (UIView *)expandedTrailingView { return nil; }

- (NSInteger)preferredLayoutMode {
    PLog(@"[prov] preferredLayoutMode");
    return 2;
}
- (NSInteger)maximumSupportedLayoutMode {
    PLog(@"[prov] maximumSupportedLayoutMode");
    return 3;
}
- (NSInteger)minimumLayoutMode {
    PLog(@"[prov] minimumLayoutMode");
    return 0;
}

- (void)_setDelegate:(id)d { PLog(@"[prov] _setDelegate:"); }

@end

#pragma mark - 找 manager 并注册

static id gProvider = nil;
static id gAssertion = nil;

static id KZManagerFromObject(id obj, int depth) {
    if (!obj || depth > 8) return nil;
    NSString *cn = NSStringFromClass([obj class]);
    if ([cn containsString:@"Aperture"]) {
        NSArray *keys = @[ @"_systemApertureManager", @"systemApertureManager", @"_manager" ];
        for (NSString *k in keys) {
            @try {
                id m = [obj valueForKey:k];
                if (m && [NSStringFromClass([m class]) containsString:@"Aperture"]) {
                    PLog(@"[find] %@.%@ = %@", cn, k, NSStringFromClass([m class]));
                    return m;
                }
            } @catch (...) {}
        }
    }
    if ([obj isKindOfClass:[UIWindow class]]) {
        id m = KZManagerFromObject([(UIWindow *)obj rootViewController], depth + 1);
        if (m) return m;
    }
    if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        id m = KZManagerFromObject(vc.view, depth + 1);
        if (m) return m;
        for (UIViewController *c in vc.childViewControllers) {
            m = KZManagerFromObject(c, depth + 1);
            if (m) return m;
        }
        m = KZManagerFromObject(vc.presentedViewController, depth + 1);
        if (m) return m;
    }
    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        for (UIView *sub in v.subviews) {
            id m = KZManagerFromObject(sub, depth + 1);
            if (m) return m;
        }
        id m = KZManagerFromObject([v nextResponder], depth + 1);
        if (m) return m;
    }
    return nil;
}

static id KZFindManager(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)sc).windows];
        }
    }
    PLog(@"[find] windows=%lu", (unsigned long)windows.count);
    for (UIWindow *w in windows) {
        id m = KZManagerFromObject(w, 0);
        if (m) return m;
    }

    // 退路：从类方法里找 shared 实例
    NSArray *names = @[ @"SBSystemApertureController", @"SBSystemApertureViewController",
                        @"SAUISystemApertureManager", @"SBSystemApertureManager" ];
    NSArray *sels = @[ @"sharedInstance", @"sharedController", @"sharedManager", @"_sharedInstance" ];
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        for (NSString *sn in sels) {
            SEL sel = NSSelectorFromString(sn);
            if ([c respondsToSelector:sel]) {
                id inst = ((id (*)(id, SEL))objc_msgSend)(c, sel);
                if (inst) {
                    PLog(@"[find] %@.%@ = %@", n, sn, NSStringFromClass([inst class]));
                    id m = KZManagerFromObject(inst, 0);
                    if (m) return m;
                    if ([NSStringFromClass([inst class]) containsString:@"Aperture"]) return inst;
                }
            }
        }
    }
    return nil;
}

static void KZRegister(void) {
    if (gProvider) return;
    id mgr = KZFindManager();
    if (!mgr) {
        PLog(@"[reg] manager 没找到");
        return;
    }
    PLog(@"[reg] manager = %@", NSStringFromClass([mgr class]));

    gProvider = [[KZElementProvider alloc] init];

    SEL reg = NSSelectorFromString(@"registerElement:");
    if ([mgr respondsToSelector:reg]) {
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, reg, gProvider);
        PLog(@"[reg] registerElement: 已调用");
    } else {
        PLog(@"[reg] 没有 registerElement:");
    }

    SEL as = NSSelectorFromString(@"_assertionForElementCreatingIfNecessary:");
    if ([mgr respondsToSelector:as]) {
        id a = ((id (*)(id, SEL, id))objc_msgSend)(mgr, as, gProvider);
        gAssertion = a;
        PLog(@"[reg] assertion = %@", a ? NSStringFromClass([a class]) : @"nil");
    } else {
        SEL as2 = NSSelectorFromString(@"elementAssertionForElement:");
        if ([mgr respondsToSelector:as2]) {
            id a = ((id (*)(id, SEL, id))objc_msgSend)(mgr, as2, gProvider);
            gAssertion = a;
            PLog(@"[reg] (alt) assertion = %@", a ? NSStringFromClass([a class]) : @"nil");
        } else {
            PLog(@"[reg] 没有 assertion 接口");
        }
    }
}

%hook SpringBoard

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL r = %orig;
    PLog(@"springboard launched");
    return r;
}

%end

%ctor {
    PLog(@"ctor v1.18 (find manager)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!KZPrefBool(@"enabled", YES)) return;
        KZRegister();
    });
}
