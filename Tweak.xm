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
    PLog(@"%@", msg);
}

#pragma mark - 偏好

static id KZPrefRaw(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KZ_PREF_DOMAIN));
    return v ? (__bridge_transfer id)v : nil;
}
static double KZPrefNum(NSString *key, double dflt) {
    id v = KZPrefRaw(key);
    if (![v isKindOfClass:[NSNumber class]]) {
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
        return dflt;
    }
    return [v doubleValue];
}
static BOOL KZPrefBool(NSString *key, BOOL dflt) {
    id v = KZPrefRaw(key);
    if (![v isKindOfClass:[NSNumber class]]) return dflt;
    return [v boolValue];
}
static NSString *KZPrefStr(NSString *key) {
    id v = KZPrefRaw(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL KZEnabled(void) { return KZPrefBool(@"enabled", YES); }

#pragma mark - 素材

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
    });
    return img;
}

#pragma mark - 窗口 / 视图工具

static NSArray<UIWindow *> *KZWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            [out addObjectsFromArray:((UIWindowScene *)sc).windows];
        }
    }
    return out;
}

static BOOL KZClassContains(UIView *v, NSString *s) {
    if (!v) return NO;
    return [NSStringFromClass(v.class) rangeOfString:s].location != NSNotFound;
}

static id KZIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static NSString *KZElemIdentOf(UIView *v) {
    UIView *cur = v;
    int hops = 0;
    while (cur && hops++ < 12) {
        id provider = KZIvar(cur, "_elementViewProvider");
        if (provider) {
            id eid = nil;
            @try { eid = [provider valueForKey:@"elementIdentifier"]; } @catch (...) {}
            if ([eid isKindOfClass:[NSString class]] && [eid length]) return eid;
        }
        cur = cur.superview;
    }
    return nil;
}

static BOOL KZIsScreenRecordingId(NSString *eid) {
    return eid.length > 0 && [eid.lowercaseString containsString:@"screenrecording"];
}

#pragma mark - 找录屏 element（6.20 方式 B：视图树扫描）

static UIView *KZFindRecordingElementInTree(UIView *root, NSInteger depth) {
    if (!root || depth > 16) return nil;
    if (KZClassContains(root, @"SAUIElementView")) {
        if (KZIsScreenRecordingId(KZElemIdentOf(root))) return root;
    }
    for (UIView *sub in [root.subviews copy]) {
        UIView *hit = KZFindRecordingElementInTree(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIView *gElement = nil;

static UIView *KZFindRecordingElement(void) {
    if (gElement && gElement.window) return gElement;
    gElement = nil;
    for (UIWindow *w in KZWindows()) {
        UIView *e = KZFindRecordingElementInTree(w, 0);
        if (e && e.window) {
            gElement = e;
            PLog(@"[find] element=%@", NSStringFromClass(e.class));
            return e;
        }
    }
    return nil;
}

#pragma mark - 找挂载宿主（6.20 方式：portal 叶子优先）

static BOOL KZIsAccessoryPortal(UIView *v) {
    if (!v) return NO;
    return [NSStringFromClass(v.class) isEqualToString:@"SBSystemApertureSceneElementAccessoryPortalView"];
}
static BOOL KZIsAccessoryView(UIView *v) {
    if (!v) return NO;
    return [NSStringFromClass(v.class) isEqualToString:@"SBSystemApertureSceneElementAccessoryView"];
}
static BOOL KZIsRedIndicator(UIView *v) {
    if (!v) return NO;
    NSString *n = NSStringFromClass(v.class);
    return [n rangeOfString:@"RecordingIndicator"].location != NSNotFound;
}

static void KZCollect(UIView *root, NSMutableArray *out, NSInteger depth) {
    if (!root || depth > 18) return;
    if ((KZIsAccessoryPortal(root) || KZIsAccessoryView(root) || KZIsRedIndicator(root)) &&
        root.window && !root.hidden && root.alpha > 0.01) {
        [out addObject:root];
    }
    for (UIView *sub in [root.subviews copy]) KZCollect(sub, out, depth + 1);
}

static BOOL KZHostUsable(UIView *v) {
    if (!v || !v.window || v.hidden || v.alpha <= 0.01) return NO;
    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    return (w >= 6.0 && h >= 6.0 && w <= 60.0 && h <= 60.0);
}

static UIView *KZBestHost(UIView *element) {
    if (!element || !element.window) return nil;
    UIWindow *w = element.window;
    NSMutableArray *items = [NSMutableArray array];
    KZCollect(w, items, 0);
    if (!items.count) return nil;
    CGRect er = [element convertRect:element.bounds toView:w];
    CGPoint ec = CGPointMake(CGRectGetMidX(er), CGRectGetMidY(er));
    UIView *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (UIView *v in items) {
        if (!KZHostUsable(v)) continue;
        CGRect r = [v convertRect:v.bounds toView:w];
        CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        CGFloat dx = c.x - ec.x, dy = c.y - ec.y;
        CGFloat score = dx * dx + dy * dy;
        if (KZIsAccessoryPortal(v)) score -= 400.0;   // 6.20：优先 portal 叶子
        if (KZIsRedIndicator(v)) score -= 200.0;
        if (score < bestScore) { bestScore = score; best = v; }
    }
    return best;
}

#pragma mark - 写轮眼视图

static UIView *gEye = nil;

static UIView *KZMakeEye(void) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.tag = KZ_EYE_TAG;
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = 11.0;
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;

    UIImage *img = KZEyeImage();
    if (!img) {
        v.backgroundColor = [UIColor redColor];
        PLog(@"[img] 读不到素材");
        return v;
    }
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = v.bounds;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:iv];
    KZOnce(@"img", [NSString stringWithFormat:@"[img] eye = %.0fx%.0f", img.size.width, img.size.height]);
    return v;
}

static void KZEyeApplyAnimation(UIView *eye) {
    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.2) dur = 1.5;
    UIView *target = eye.subviews.firstObject ?: eye;
    if (![target.layer animationForKey:@"kzspin"]) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(M_PI * 2.0);
        spin.duration = dur;
        spin.repeatCount = INFINITY;
        [target.layer addAnimation:spin forKey:@"kzspin"];
    } else {
        CABasicAnimation *spin = (CABasicAnimation *)[target.layer animationForKey:@"kzspin"];
        if (fabs(spin.duration - dur) > 0.01) {
            [target.layer removeAnimationForKey:@"kzspin"];
            CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            a.fromValue = @(0.0);
            a.toValue = @(M_PI * 2.0);
            a.duration = dur;
            a.repeatCount = INFINITY;
            [target.layer addAnimation:a forKey:@"kzspin"];
        }
    }
}

#pragma mark - 挂载 / 同步 / 移除

static UIView *gHost = nil;
static double gMountedAt = 0;

static void KZRemoveEye(void) {
    if (gEye) {
        [gEye removeFromSuperview];
        gEye = nil;
    }
    gHost = nil;
    gMountedAt = 0;
    gElement = nil;
    KZOnce(@"removed", @"[mount] 已移除写轮眼");
}

static BOOL KZCaptured(void) {
    @try {
        for (UIScreen *s in [UIScreen screens]) if (s.isCaptured) return YES;
    } @catch (...) {}
    return NO;
}

static void KZSync(void) {
    if (!KZEnabled() || !KZCaptured()) {
        if (gEye) KZRemoveEye();
        return;
    }
    // 倒计时 3-2-1 期间不动系统界面（6.20 也是等原生红点出现后才接管）
    UIView *element = KZFindRecordingElement();
    if (!element) return;
    if (gMountedAt == 0) {
        gMountedAt = CACurrentMediaTime();
        return;
    }
    if (CACurrentMediaTime() - gMountedAt < 3.4) return;

    UIView *host = KZBestHost(element);
    if (!host) return;

    if (!gEye) gEye = KZMakeEye();

    if (gEye.superview != host) {
        [gEye removeFromSuperview];
        [host addSubview:gEye];
        [host bringSubviewToFront:gEye];
        PLog(@"[mount] 挂到 %@ %.0fx%.0f", NSStringFromClass(host.class),
             CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds));
    }
    gHost = host;
    gEye.hidden = NO;

    CGRect b = host.bounds;
    UIWindow *w = host.window;
    CGRect screen = w ? [host convertRect:b toView:w] : b;
    CGFloat midX = w ? CGRectGetMidX(w.bounds) : 0;
    BOOL isLeft = CGRectGetMidX(screen) < midX;

    if (isLeft && !KZPrefBool(@"leftOn", YES)) { gEye.hidden = YES; return; }
    if (!isLeft && !KZPrefBool(@"rightOn", YES)) { gEye.hidden = YES; return; }

    double scale = isLeft ? KZPrefNum(@"scale", 1.0) : KZPrefNum(@"scaleR", 0.95);
    if (scale < 0.3) scale = 1.0;
    double offx = isLeft ? KZPrefNum(@"offX", 0.0) : KZPrefNum(@"offXR", 0.0);

    CGFloat base = MIN(CGRectGetWidth(b), CGRectGetHeight(b));
    if (base < 4) base = 22;
    CGFloat side = base * scale;
    gEye.frame = CGRectMake((CGRectGetWidth(b) - side) / 2.0 + offx,
                            (CGRectGetHeight(b) - side) / 2.0, side, side);
    gEye.layer.cornerRadius = side / 2.0;
    KZEyeApplyAnimation(gEye);
}

static NSTimer *gTimer = nil;
static void KZStart(void) {
    if (gTimer && gTimer.valid) return;
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.10 repeats:YES block:^(NSTimer *t) {
        @try { KZSync(); } @catch (NSException *e) { PLog(@"[tick] 异常 %@", e.reason); }
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
    PLog(@"[tick] 轮询启动");
}

static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        KZRemoveEye();
        gSeen = nil;
        KZSync();
        PLog(@"[apply] 已重新应用（scale=%.2f duration=%.2f）", KZPrefNum(@"scale", 1.0), KZPrefNum(@"duration", 1.5));
    });
}

static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.37 (6.20 attach + prefs)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZStart();
    });
}