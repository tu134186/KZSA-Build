#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import "kzeye_b64.h"
#import "kzduck_b64.h"

#define KZ_DOMAIN "com.minis.kzprobe"
#define KZ_PREF_DOMAIN "com.minis.kzsa"
#define KZ_NOTIFY "com.minis.kzsa.changed"
#define KZ_EYE @"/Library/KZTheme/eye/tomoe2.png"
#define KZ_EYE_ALT @"/Library/KZTheme/eye/tomoe.png"

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

static NSMutableSet *gLogged = nil;

// 沿父视图链找 _elementViewProvider，取其 elementIdentifier
static NSString *KZElementId(UIView *v) {
    UIView *cur = v;
    int depth = 0;
    while (cur && depth < 12) {
        Ivar iv = class_getInstanceVariable([cur class], "_elementViewProvider");
        if (iv) {
            @try {
                id elem = object_getIvar(cur, iv);
                if (elem) {
                    id eid = nil;
                    @try { eid = [elem valueForKey:@"elementIdentifier"]; } @catch (...) {}
                    if ([eid isKindOfClass:[NSString class]] && [eid length]) return eid;
                }
            } @catch (...) {}
        }
        cur = cur.superview;
        depth++;
    }
    return nil;
}

static NSString *KZPrefStr(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KZ_PREF_DOMAIN));
    if (!v) return nil;
    NSString *s = [NSString stringWithFormat:@"%@", (__bridge id)v];
    CFRelease(v);
    return s;
}

static double KZPrefNum(NSString *key, double dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KZ_PREF_DOMAIN));
    if (!v) return dflt;
    double d = [(__bridge NSNumber *)v doubleValue];
    CFRelease(v);
    return d > 0 ? d : dflt;
}

static UIImage *KZUserImage(void) {
    NSString *b64 = KZPrefStr(@"eyeImage");
    if (b64.length < 200) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (d.length < 200) return nil;
    return [UIImage imageWithData:d];
}

static UIImage *KZDuckImage(void) {
    NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:kKZduckB64]
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return d.length > 200 ? [UIImage imageWithData:d] : nil;
}

static BOOL gUseDuck = NO;
static UIView *KZEye(CGRect frame) {
    if (frame.size.width < 4) frame = CGRectMake(0, 0, 22, 22);
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = frame.size.width / 2.0;
    v.layer.masksToBounds = YES;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImage *img = gUseDuck ? KZDuckImage() : KZUserImage();
    if (!img) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:kKZeyeB64]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d.length > 200) img = [UIImage imageWithData:d];
    }
    if (!img) img = [UIImage imageWithContentsOfFile:KZ_EYE];
    if (!img) img = [UIImage imageWithContentsOfFile:KZ_EYE_ALT];
    if (!img) {
        PLog(@"[img] 读不到素材");
        return v;
    }
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    CGFloat pad = v.bounds.size.width * 0.032;
    iv.frame = CGRectInset(v.bounds, -pad, -pad);
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:iv];

    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = KZPrefNum(@"duration", 1.5);
    spin.repeatCount = INFINITY;
    [iv.layer addAnimation:spin forKey:@"kzspin"];

    CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breathe.fromValue = @(1.0);
    breathe.toValue = @(1.06);
    breathe.duration = 1.1;
    breathe.autoreverses = YES;
    breathe.repeatCount = INFINITY;
    [v.layer addAnimation:breathe forKey:@"kzbreathe"];

    return v;
}

static void (*origSetPV)(id, SEL, UIView *) = NULL;

static BOOL KZIsRecording(UIView *container) {
    NSString *eid = KZElementId(container);
    if (!eid) return NO;
    return [eid.lowercaseString containsString:@"screenrecording"];
}

static void KZScheduleReplace(UIView *container);

static void KZSetPV(id self, SEL _cmd, UIView *view) {
    if (origSetPV) origSetPV(self, _cmd, view);
    KZScheduleReplace((UIView *)self);
}

static void KZTryReplace(UIView *container) {
    if (!container || !container.window) return;
    if (container.bounds.size.width < 4) return;
    if (!KZIsRecording(container)) return;

    id provided = nil;
    @try { provided = [container valueForKey:@"providedView"]; } @catch (...) {}
    if (![provided isKindOfClass:[UIView class]]) return;
    UIView *pv = (UIView *)provided;
    if ([pv viewWithTag:0x4B5A]) return;

    CGRect b = pv.bounds;
    BOOL narrow = (b.size.height - b.size.width) > 1.5;
    gUseDuck = !narrow;   // 窄槽（左侧贴边）放写轮眼，方槽（独立圆）放小鸭子
    PLog(@"[slot] %.0fx%.0f -> %@", b.size.width, b.size.height, narrow ? @"写轮眼" : @"小鸭子");
    CGFloat side = MIN(b.size.width, b.size.height);
    if (side < 4) side = 22;
    double scale = KZPrefNum(@"scale", 1.0);
    if (scale < 0.4) scale = 1.0;
    side = side * scale;
    UIView *eye = KZEye(CGRectMake(0, 0, side, side));
    eye.tag = 0x4B5A;
    eye.frame = CGRectMake((b.size.width - side) / 2.0, (b.size.height - side) / 2.0, side, side);
    eye.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [pv addSubview:eye];
    [pv bringSubviewToFront:eye];
    PLog(@"[add] 已附加到 %@ %.0fx%.0f subviews=%lu", NSStringFromClass([pv class]),
         pv.bounds.size.width, pv.bounds.size.height, (unsigned long)pv.subviews.count);
}

static NSMutableSet *gScheduled = nil;
static void KZScheduleReplace(UIView *container) {
    if (!container) return;
    if (!gScheduled) gScheduled = [NSMutableSet set];
    NSString *k = [NSString stringWithFormat:@"%p", container];
    if ([gScheduled containsObject:k]) return;
    [gScheduled addObject:k];
    __weak UIView *wc = container;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZTryReplace(wc);
    });
}

static void (*origDidMove)(id, SEL);
static void KZDidMove(id self, SEL _cmd) {
    if (origDidMove) origDidMove(self, _cmd);
    KZScheduleReplace((UIView *)self);
}

static BOOL gH1 = NO, gH2 = NO;
static void KZTryInstall(void) {
    Class c = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (!c) return;
    if (!gH1) {
        MSHookMessageEx(c, @selector(setProvidedView:), (IMP)KZSetPV, (IMP *)&origSetPV);
        gH1 = YES;
        PLog(@"[hook] setProvidedView: ok");
    }
    if (!gH2) {
        MSHookMessageEx(c, @selector(didMoveToWindow), (IMP)KZDidMove, (IMP *)&origDidMove);
        gH2 = YES;
        PLog(@"[hook] didMoveToWindow ok");
    }
}

static NSArray<UIWindow *> *KZWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            [out addObjectsFromArray:((UIWindowScene *)sc).windows];
        }
    }
    return out;
}

static void KZRemoveEyes(UIView *v) {
    for (UIView *s in [v.subviews copy]) {
        if (s.tag == 0x4B5A) [s removeFromSuperview];
        else KZRemoveEyes(s);
    }
}

static void KZScan(UIView *v) {
    Class cls = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (cls && [v isKindOfClass:cls]) KZTryReplace(v);
    for (UIView *s in [v.subviews copy]) KZScan(s);
}

static void KZReapply(void) {
    if (gScheduled) [gScheduled removeAllObjects];
    for (UIWindow *w in KZWindows()) {
        KZRemoveEyes(w);
        KZScan(w);
    }
    PLog(@"[reapply] 已重新应用");
}

static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ KZReapply(); });
}

%ctor {
    PLog(@"ctor v1.8 (eye left / duck right)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { KZTryInstall(); }];
    });
}
