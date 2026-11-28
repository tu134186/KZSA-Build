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
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
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

#pragma mark - 写轮眼视图

@interface KZEyeDot : UIView
@property (nonatomic, strong) UIImageView *img;
@end
@implementation KZEyeDot
- (void)layoutSubviews {
    [super layoutSubviews];
    self.img.frame = self.bounds;
}
@end

static KZEyeDot *KZMakeEye(void) {
    KZEyeDot *v = [[KZEyeDot alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.tag = KZ_EYE_TAG;
    v.backgroundColor = [UIColor blackColor];
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;
    v.autoresizingMask = UIViewAutoresizingNone;

    UIImage *img = KZEyeImage();
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingNone;
    v.img = iv;
    [v addSubview:iv];
    if (!img) v.backgroundColor = [UIColor redColor];
    return v;
}

// 按当前设置刷新（尺寸 / 偏移 / 转速 / 素材）；尺寸上限压到容器高度
static void KZRefreshEye(KZEyeDot *eye) {
    double sc = KZPrefNum(@"scale", 1.0);
    if (sc < 0.3 || sc > 3.0) sc = 1.0;
    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.2) dur = 1.5;
    double offx = KZPrefNum(@"offX", 0.0);
    double offy = KZPrefNum(@"offY", 0.0);

    UIView *host = eye.superview;
    CGRect b = host ? host.bounds : CGRectMake(0, 0, 22, 22);
    CGFloat hh = CGRectGetHeight(b);
    if (hh <= 0) hh = 22;
    CGFloat side = 22.0 * sc;
    if (side > hh) side = hh;          // 不超出容器高度，避免被裁
    if (side < 8) side = 8;

    // 左对齐到容器内，再叠加用户偏移（容器本身就是贴左的槽位）
    CGFloat x = (CGRectGetWidth(b) - side) / 2.0 + offx;
    CGFloat y = (hh - side) / 2.0 + offy;
    eye.frame = CGRectMake(x, y, side, side);
    eye.layer.cornerRadius = side / 2.0;
    eye.img.image = KZEyeImage();

    [eye.img.layer removeAnimationForKey:@"kzspin"];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = dur;
    spin.repeatCount = INFINITY;
    [eye.img.layer addAnimation:spin forKey:@"kzspin"];
}

#pragma mark - 判定

static NSString *KZElemIdent(id elem) {
    if (!elem) return nil;
    @try {
        id e = [elem valueForKey:@"elementIdentifier"];
        if ([e isKindOfClass:[NSString class]]) return e;
    } @catch (...) {}
    return nil;
}
static BOOL KZIsRecording(id elem) {
    NSString *s = KZElemIdent(elem);
    return s.length > 0 && [s.lowercaseString containsString:@"screenrecording"];
}

#pragma mark - 注入到 accessory（o2Pro 的 setLeadingView 路线）

static NSHashTable *gHosts = nil;
static void KZTrack(UIView *v) {
    if (!gHosts) gHosts = [NSHashTable weakObjectsHashTable];
    [gHosts addObject:v];
}

// 只在 accessory 小到「就是一个红点」时才隐藏系统内容；
// 容器变宽（展开态）时保留系统内容，这样计时/停止不会被我们盖掉
static void KZHideDotOnly(UIView *host, UIView *keep) {
    CGFloat w = CGRectGetWidth(host.bounds), h = CGRectGetHeight(host.bounds);
    BOOL dotSized = (w <= 34.0 && h <= 34.0);
    for (UIView *s in host.subviews) {
        if (s == keep || s.tag == KZ_EYE_TAG) continue;
        if (dotSized) {
            if (s.alpha > 0.0) {
                s.alpha = 0.0;
                KZOnce([NSString stringWithFormat:@"hide-%@", NSStringFromClass(s.class)],
                       [NSString stringWithFormat:@"[inject] 隐藏红点 %@（%@）", NSStringFromClass(s.class),
                        [NSString stringWithFormat:@"%.0fx%.0f", w, h]]);
            }
        } else if (s.alpha < 0.01) {
            s.alpha = 1.0;   // 展开态恢复系统内容
        }
    }
}

static void KZInject(UIView *host, NSString *slot) {
    if (!host) return;
    if (!KZPrefBool(@"enabled", YES) || !KZPrefBool(@"leftOn", YES)) return;
    KZTrack(host);

    KZEyeDot *eye = nil;
    for (UIView *s in host.subviews) {
        if (s.tag == KZ_EYE_TAG && [s isKindOfClass:[KZEyeDot class]]) { eye = (KZEyeDot *)s; break; }
    }
    if (!eye) {
        eye = KZMakeEye();
        [host addSubview:eye];
        KZOnce([NSString stringWithFormat:@"inject-%@", slot],
               [NSString stringWithFormat:@"[inject] %@ 注入 %@（容器 %.0fx%.0f）", slot,
                NSStringFromClass(host.class),
                CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds)]);
    } else if (eye.superview != host) {
        [eye removeFromSuperview];
        [host addSubview:eye];
    }
    [host bringSubviewToFront:eye];
    eye.hidden = NO;

    KZHideDotOnly(host, eye);
    KZRefreshEye(eye);
}

static id (*origLeading)(id, SEL);
static id kzLeading(id self, SEL _cmd) {
    id v = nil;
    @try { v = origLeading ? origLeading(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecording(self) && [v isKindOfClass:[UIView class]]) KZInject((UIView *)v, @"leadingView");
    return v;
}
static id (*origExpLeading)(id, SEL);
static id kzExpLeading(id self, SEL _cmd) {
    id v = nil;
    @try { v = origExpLeading ? origExpLeading(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecording(self) && [v isKindOfClass:[UIView class]]) KZInject((UIView *)v, @"expandedLeadingView");
    return v;
}

// 布局模式：默认跟随系统（岛保持原生大小，红点位置被我们顶替）
// 设了 wideIsland=1 才强制拉长（拉长后右侧会是空的，除非系统自己有 trailing 内容）
static NSInteger (*origPref)(id, SEL);
static NSInteger kzPref(id self, SEL _cmd) {
    NSInteger v = 0;
    @try { v = origPref ? origPref(self, _cmd) : 0; } @catch (...) {}
    if (KZIsRecording(self) && KZPrefBool(@"wideIsland", NO)) {
        KZOnce(@"pref", [NSString stringWithFormat:@"[layout] preferred %ld -> 2（wideIsland）", (long)v]);
        return 2;
    }
    return v;
}
static NSInteger (*origMax)(id, SEL);
static NSInteger kzMax(id self, SEL _cmd) {
    NSInteger v = 0;
    @try { v = origMax ? origMax(self, _cmd) : 0; } @catch (...) {}
    if (KZIsRecording(self)) {
        KZOnce(@"max", [NSString stringWithFormat:@"[layout] max %ld（保持系统值）", (long)v]);
    }
    return v;
}

static BOOL gHooked = NO;
static void KZInstall(void) {
    if (gHooked) return;
    Class c = NSClassFromString(@"SBSystemApertureSceneElement");
    if (!c) { KZOnce(@"noclass", @"[hook] 找不到 SBSystemApertureSceneElement"); return; }
    int n = 0;
    SEL s1 = NSSelectorFromString(@"leadingView");
    SEL s2 = NSSelectorFromString(@"expandedLeadingView");
    SEL s3 = NSSelectorFromString(@"preferredLayoutMode");
    SEL s4 = NSSelectorFromString(@"maximumSupportedLayoutMode");
    if ([c instancesRespondToSelector:s1]) { MSHookMessageEx(c, s1, (IMP)kzLeading, (IMP *)&origLeading); n++; }
    if ([c instancesRespondToSelector:s2]) { MSHookMessageEx(c, s2, (IMP)kzExpLeading, (IMP *)&origExpLeading); n++; }
    if ([c instancesRespondToSelector:s3]) { MSHookMessageEx(c, s3, (IMP)kzPref, (IMP *)&origPref); n++; }
    if ([c instancesRespondToSelector:s4]) { MSHookMessageEx(c, s4, (IMP)kzMax, (IMP *)&origMax); n++; }
    if (n) { gHooked = YES; PLog(@"[hook] 已 hook %d 个方法", n); }
}

#pragma mark - 保活

static NSTimer *gTimer = nil;
static BOOL KZCaptured(void) {
    @try {
        for (UIScreen *s in [UIScreen screens]) if (s.isCaptured) return YES;
    } @catch (...) {}
    return NO;
}

static void KZTick(void) {
    BOOL cap = KZCaptured();
    if (!cap || !KZPrefBool(@"enabled", YES)) {
        if (gHosts && gHosts.count) {
            for (UIView *h in [[gHosts allObjects] copy]) {
                @try {
                    for (UIView *s in [h.subviews copy]) {
                        if (s.tag == KZ_EYE_TAG) [s removeFromSuperview];
                        else if (s.alpha < 0.01) s.alpha = 1.0;
                    }
                } @catch (...) {}
            }
            [gHosts removeAllObjects];
            KZOnce(@"cleaned", @"[inject] 录屏结束，已还原");
        }
        return;
    }
    if (!gHosts) return;
    for (UIView *h in [[gHosts allObjects] copy]) {
        for (UIView *s in h.subviews) {
            if (s.tag == KZ_EYE_TAG && [s isKindOfClass:[KZEyeDot class]]) {
                KZRefreshEye((KZEyeDot *)s);
            }
        }
        KZHideDotOnly(h, nil);
    }
}

static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gHosts) {
            for (UIView *h in [[gHosts allObjects] copy]) {
                for (UIView *s in h.subviews) {
                    if (s.tag == KZ_EYE_TAG && [s isKindOfClass:[KZEyeDot class]]) KZRefreshEye((KZEyeDot *)s);
                }
            }
        }
        PLog(@"[apply] 刷新 scale=%.2f offX=%.1f offY=%.1f dur=%.2f wide=%d",
             KZPrefNum(@"scale", 1.0), KZPrefNum(@"offX", 0.0), KZPrefNum(@"offY", 0.0),
             KZPrefNum(@"duration", 1.5), KZPrefBool(@"wideIsland", NO));
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.43 (inject, keep system content when wide)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZInstall();
        if (!gTimer || !gTimer.valid) {
            gTimer = [NSTimer scheduledTimerWithTimeInterval:0.20 repeats:YES block:^(NSTimer *t) {
                @try { KZInstall(); KZTick(); } @catch (NSException *e) { PLog(@"[tick] %@", e.reason); }
            }];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        }
    });
}