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

static BOOL gLeadMissing = NO;
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
    if (gLeadMissing) KZScheduleReplace((UIView *)self);
}

static void KZTryReplace(UIView *container) {
    if (!gLeadMissing) return;

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
    if (!narrow) return;
    if (!KZPrefBool(@"leftOn", YES)) return;
    gUseDuck = !narrow;
    PLog(@"[slot] %.0fx%.0f -> %@", b.size.width, b.size.height, narrow ? @"写轮眼" : @"小鸭子");
    CGFloat side = MAX(b.size.width, b.size.height);
    if (side < 4) side = 22;
    double scale = narrow ? KZPrefDouble(@"scale", 1.0) : KZPrefDouble(@"scaleR", 0.95);
    if (scale < 0.3) scale = 1.0;
    side = side * scale;
    double offx = narrow ? KZPrefDouble(@"offX", 0.0) : KZPrefDouble(@"offXR", 0.0);
    UIView *eye = KZEye(CGRectMake(0, 0, side, side));
    eye.tag = 0x4B5A;
    eye.frame = CGRectMake((b.size.width - side) / 2.0 + offx, (b.size.height - side) / 2.0, side, side);
    eye.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [pv addSubview:eye];
    [pv bringSubviewToFront:eye];
    PLog(@"[add] 已附加到 %@ %.0fx%.0f subviews=%lu", NSStringFromClass([pv class]),
         pv.bounds.size.width, pv.bounds.size.height, (unsigned long)pv.subviews.count);
}

static NSMutableSet *gScheduled = nil;
static void __attribute__((unused)) KZScheduleReplace(UIView *container) {
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

}

// —— 布局模式：让录屏 element 请求更宽的布局
static NSMutableSet *gModeSeen = nil;
static NSString *KZElemId(id elem) {
    NSString *eid = nil;
    @try { eid = [elem valueForKey:@"elementIdentifier"]; } @catch (...) {}
    return [eid isKindOfClass:[NSString class]] ? eid : nil;
}
static void KZModeLog(id elem, NSString *name, NSInteger before, NSInteger after) {
    NSString *eid = KZElemId(elem);
    if (![eid.lowercaseString containsString:@"screenrecording"]) return;
    if (!gModeSeen) gModeSeen = [NSMutableSet set];
    NSString *k = [NSString stringWithFormat:@"%@-%ld-%ld", name, (long)before, (long)after];
    if ([gModeSeen containsObject:k]) return;
    [gModeSeen addObject:k];
    PLog(@"[mode] %@ before=%ld after=%ld", name, (long)before, (long)after);
}

static NSInteger (*origPrefMode)(id, SEL);
static NSInteger myPrefMode(id self, SEL _cmd) {
    NSInteger v = origPrefMode ? origPrefMode(self, _cmd) : 0;
    NSInteger out = MAX(v, 2);
    KZModeLog(self, @"preferredLayoutMode", v, out);
    return out;
}
static NSInteger (*origMaxMode)(id, SEL);
static NSInteger myMaxMode(id self, SEL _cmd) {
    NSInteger v = origMaxMode ? origMaxMode(self, _cmd) : 0;
    NSInteger out = MAX(v, 3);
    KZModeLog(self, @"maximumSupportedLayoutMode", v, out);
    return out;
}
static NSInteger (*origMinMode)(id, SEL);
static NSInteger myMinMode(id self, SEL _cmd) {
    NSInteger v = origMinMode ? origMinMode(self, _cmd) : 0;
    KZModeLog(self, @"minimumLayoutMode", v, v);
    return v;
}

// —— 给录屏 element 提供 trailing 视图（小鸭子），让系统加宽并给第二个位置
static UIView *KZSharinganView(void) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    double scale = KZPrefDouble(@"scale", 1.0);
    if (scale < 0.3) scale = 1.0;
    double offx = KZPrefDouble(@"offX", 0.0);
    CGFloat side = 22.0 * scale;
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake((22 - side) / 2.0 + offx, 0, side, side)];
    circle.backgroundColor = [UIColor blackColor];
    circle.layer.cornerRadius = side / 2.0;
    circle.layer.masksToBounds = YES;
    circle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;

    UIImage *img = KZUserImage();
    if (!img) img = [UIImage imageWithContentsOfFile:KZ_EYE];
    if (!img) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:kKZeyeB64]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d.length > 200) img = [UIImage imageWithData:d];
    }
    if (img) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        CGFloat pad = circle.bounds.size.width * 0.032;
        iv.frame = CGRectInset(circle.bounds, -pad, -pad);
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [circle addSubview:iv];
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(M_PI * 2.0);
        spin.duration = KZPrefDouble(@"duration", 1.5);
        spin.repeatCount = INFINITY;
        [iv.layer addAnimation:spin forKey:@"kzspin"];
    }
    [v addSubview:circle];
    return v;
}

static UIView *gDuckView = nil;
static UIView * __attribute__((unused)) KZDuckView(void) {
    if (gDuckView) return gDuckView;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIImage *img = KZDuckImage();
    if (img) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.frame = v.bounds;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v addSubview:iv];
        CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        bob.fromValue = @(-1.2);
        bob.toValue = @(1.2);
        bob.duration = 0.9;
        bob.autoreverses = YES;
        bob.repeatCount = INFINITY;
        [iv.layer addAnimation:bob forKey:@"kzbob"];
    }
    gDuckView = v;
    return v;
}

static NSMutableSet *gTrailSeen = nil;

static void __attribute__((unused)) KZTrailLog(NSString *name) {
    if (!gTrailSeen) gTrailSeen = [NSMutableSet set];
    if ([gTrailSeen containsObject:name]) return;
    [gTrailSeen addObject:name];
    PLog(@"[trail] 提供鸭子 via %@", name);
}

static UIView *(*origLeadView)(id, SEL);
static UIView *myLeadView(id self, SEL _cmd) {
    UIView *orig = origLeadView ? origLeadView(self, _cmd) : nil;
    NSString *eid = KZElemId(self);
    if ([eid.lowercaseString containsString:@"screenrecording"] && KZPrefBool(@"leftOn", YES)) {
        if (!gTrailSeen) gTrailSeen = [NSMutableSet set];
        if (![gTrailSeen containsObject:@"leading"]) {
            [gTrailSeen addObject:@"leading"];
            PLog(@"[lead] 提供写轮眼 via leadingView");
        }
        return KZSharinganView();
    }
    return orig;
}

static UIView *(*origExpLeadView)(id, SEL);
static UIView *myExpLeadView(id self, SEL _cmd) {
    UIView *orig = origExpLeadView ? origExpLeadView(self, _cmd) : nil;
    NSString *eid = KZElemId(self);
    if ([eid.lowercaseString containsString:@"screenrecording"] && KZPrefBool(@"leftOn", YES)) {
        return KZSharinganView();
    }
    return orig;
}

static UIView *(*origTrailView)(id, SEL);
static UIView *myTrailView(id self, SEL _cmd) {
    UIView *orig = origTrailView ? origTrailView(self, _cmd) : nil;
    return orig;
}

static UIView *(*origExpTrailView)(id, SEL);
static UIView *myExpTrailView(id self, SEL _cmd) {
    UIView *orig = origExpTrailView ? origExpTrailView(self, _cmd) : nil;
    return orig;
}

static BOOL gH1 = NO, gH2 = NO, gH3 = NO, gH4 = NO, gH5 = NO;
static void KZInstallModeHooks(void) {
    Class c = NSClassFromString(@"SBSystemApertureSceneElement");
    if (!c) return;
    if (!gH3) {
        SEL s1 = NSSelectorFromString(@"preferredLayoutMode");
        SEL s2 = NSSelectorFromString(@"maximumSupportedLayoutMode");
        SEL s3 = NSSelectorFromString(@"minimumLayoutMode");
        if ([c instancesRespondToSelector:s1]) MSHookMessageEx(c, s1, (IMP)myPrefMode, (IMP *)&origPrefMode);
        if ([c instancesRespondToSelector:s2]) MSHookMessageEx(c, s2, (IMP)myMaxMode, (IMP *)&origMaxMode);
        if ([c instancesRespondToSelector:s3]) MSHookMessageEx(c, s3, (IMP)myMinMode, (IMP *)&origMinMode);
        gH3 = YES;
        PLog(@"[mode] hooks installed");
    }
    if (!gH4) {
        SEL s1 = NSSelectorFromString(@"trailingView");
        SEL s2 = NSSelectorFromString(@"expandedTrailingView");
        int n = 0;
        if ([c instancesRespondToSelector:s1]) { MSHookMessageEx(c, s1, (IMP)myTrailView, (IMP *)&origTrailView); n++; }
        if ([c instancesRespondToSelector:s2]) { MSHookMessageEx(c, s2, (IMP)myExpTrailView, (IMP *)&origExpTrailView); n++; }
        gH4 = YES;
        PLog(@"[trail] hooks installed on %d selectors", n);
    }
    if (!gH5) {
        SEL l1 = NSSelectorFromString(@"leadingView");
        SEL l2 = NSSelectorFromString(@"expandedLeadingView");
        int m = 0;
        if ([c instancesRespondToSelector:l1]) { MSHookMessageEx(c, l1, (IMP)myLeadView, (IMP *)&origLeadView); m++; }
        if ([c instancesRespondToSelector:l2]) { MSHookMessageEx(c, l2, (IMP)myExpLeadView, (IMP *)&origExpLeadView); m++; }
        gH5 = YES;
        if (m == 0) gLeadMissing = YES;
        PLog(@"[lead] hooks installed on %d selectors", m);
    }
}

static void KZTryInstall(void) {
    KZInstallModeHooks();
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

static void KZDumpClasses(NSString *filter) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        const char *nm = class_getName(classes[i]);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (![name containsString:filter]) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(classes[i], &mc);
        NSMutableString *line = [NSMutableString string];
        for (unsigned k = 0; k < mc && k < 40; k++) {
            [line appendFormat:@"%s ", sel_getName(method_getName(ms[k]))];
        }
        if (ms) free(ms);
        PLog(@"[cls] %@ (%u methods) :: %@", name, mc, line);
    }
    free(classes);
}

%ctor {
    PLog(@"ctor v1.16 (api dump)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZDumpClasses(@"SAUISystemAperture");
        KZDumpClasses(@"SAUIElement");
        KZDumpClasses(@"_SAUIAssertion");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { KZTryInstall(); }];
    });
}
