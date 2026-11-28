#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <dlfcn.h>
#import "kzpresets_b64.h"

#define KZ_DOMAIN "com.minis.kzprobe"
#define KZ_PREF_DOMAIN "com.minis.kzsa"
#define KZ_NOTIFY "com.minis.kzsa.changed"
#define KZ_EYE_TAG 0x4B5A
#define KZ_VER "1.53"

#pragma mark - 日志

static NSMutableString *gDump = nil;
static void KZFlush(void) {
    if (!gDump) return;
    CFPreferencesSetAppValue(CFSTR("dump"), (__bridge CFStringRef)[gDump copy], CFSTR(KZ_DOMAIN));
    CFPreferencesSetAppValue(CFSTR("ver"), (__bridge CFStringRef)KZ_VER, CFSTR(KZ_DOMAIN));
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

#pragma mark - 素材（8 套内置 + 自定义导入）

static UIImage *KZBase64Image(const char *b64) {
    if (!b64) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:b64]
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return d.length > 200 ? [UIImage imageWithData:d] : nil;
}

// preset 0..7 = 内置 8 套；8+ = 用户导入的数组下标
static NSArray *KZCustomList(void);

static UIImage *KZImageForPreset(NSInteger preset) {
    static NSMutableArray *cache = nil;
    if (!cache) cache = [NSMutableArray array];
    @synchronized (cache) {
        while ((NSInteger)cache.count < kKZPresetCount) [cache addObject:[NSNull null]];

        NSInteger n = kKZPresetCount;
        if (preset >= 0 && preset < n) {
            id c = cache[preset];
            if (c != [NSNull null]) return c;
            UIImage *img = KZBase64Image(kKZPresetB64[preset]);
            if (img) { cache[preset] = img; return img; }
            return nil;
        }
        // 自定义（数组）
        NSArray *customs = KZCustomList();
        NSInteger ci = preset - kKZPresetCount;
        if (ci >= 0 && ci < (NSInteger)customs.count) {
            NSString *b64 = customs[ci];
            if ([b64 isKindOfClass:[NSString class]] && b64.length > 200) {
                NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
                UIImage *u = d.length > 200 ? [UIImage imageWithData:d] : nil;
                if (u) return u;
            }
        }
        // 回退第一套
        id c0 = cache.count ? cache[0] : [NSNull null];
        if (c0 != [NSNull null]) return c0;
        UIImage *img = KZBase64Image(kKZPresetB64[0]);
        if (img && cache.count) cache[0] = img;
        return img;
    }
}

static NSArray *KZCustomList(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("eyeCustoms"), CFSTR(KZ_PREF_DOMAIN));
    id obj = v ? (__bridge_transfer id)v : nil;
    if ([obj isKindOfClass:[NSArray class]]) return obj;
    // 兼容旧版单张
    NSString *b64 = KZPrefStr(@"eyeImage");
    if (b64.length > 200) return @[b64];
    return @[];
}

static NSInteger KZPreset(void) {
    double p = KZPrefNum(@"eyePreset", 0);
    NSInteger v = (NSInteger)round(p);
    NSInteger max = kKZPresetCount + (NSInteger)KZCustomList().count;
    if (v < 0 || v >= max) v = 0;
    return v;
}

#pragma mark - 录屏状态

static BOOL KZCaptured(void) {
    @try {
        for (UIScreen *s in [UIScreen screens]) if (s.isCaptured) return YES;
    } @catch (...) {}
    return NO;
}

// 暂停时 isCaptured 会短暂变 NO，但录屏其实还在 → 用 RPScreenRecorder.isRecording 兜底
static BOOL KZRecorderRecording(void) {
    @try {
        Class rp = NSClassFromString(@"RPScreenRecorder");
        if (!rp) return NO;
        SEL sh = NSSelectorFromString(@"sharedRecorder");
        if (![rp respondsToSelector:sh]) return NO;
        id rec = ((id (*)(id, SEL))objc_msgSend)(rp, sh);
        SEL ir = NSSelectorFromString(@"isRecording");
        if (rec && [rec respondsToSelector:ir]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(rec, ir);
        }
    } @catch (...) {}
    return NO;
}
static BOOL KZRecordingActive(void) { return KZCaptured() || KZRecorderRecording(); }

// 倒计时保护：录屏开始后 3.3 秒内不注入，避免盖住系统 3-2-1 动画
static double gActiveSince = 0;
static double gEyeGate = 2.55;
static BOOL KZEyeAllowed(void) {
    if (gActiveSince <= 0) return NO;
    return (CACurrentMediaTime() - gActiveSince) >= gEyeGate;
}

#pragma mark - 写轮眼视图

@interface KZEyeDot : UIView
@property (nonatomic, strong) UIImageView *img;
@property (nonatomic) CGFloat side;
@property (nonatomic) double spinDur;
@property (nonatomic) NSInteger preset;
@end

@implementation KZEyeDot
- (void)layoutSubviews {
    [super layoutSubviews];
    self.img.frame = self.bounds;
    self.layer.cornerRadius = CGRectGetWidth(self.bounds) / 2.0;
}
- (void)kzApplyImage {
    self.img.image = KZImageForPreset(self.preset);
    self.backgroundColor = self.img.image ? [UIColor blackColor] : [UIColor redColor];
}
- (void)kzAnim {
    [self.img.layer removeAnimationForKey:@"kzspin"];
    if (self.spinDur <= 0) self.spinDur = 1.5;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = self.spinDur;
    spin.repeatCount = INFINITY;
    spin.removedOnCompletion = NO;
    [self.img.layer addAnimation:spin forKey:@"kzspin"];
}
@end

// 尺寸：不再受宿主高度限制（1.42 实测证明祖先不裁剪），允许溢出到岛外
static CGFloat KZEyeSide(void) {
    double sc = KZPrefNum(@"scale", 1.0);
    if (sc < 0.05) sc = 1.0;
    if (sc > 3.0) sc = 3.0;
    CGFloat side = 24.0 * sc;
    if (side < 8) side = 8;
    if (side > 46) side = 46;      // 展开态岛高约 44，再大就超出硬件合理范围
    return side;
}

static KZEyeDot *KZMakeEye(CGFloat side) {
    KZEyeDot *v = [[KZEyeDot alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    v.tag = KZ_EYE_TAG;
    v.side = side;
    v.preset = KZPreset();
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = side / 2.0;
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;
    v.autoresizingMask = UIViewAutoresizingNone;

    UIImageView *iv = [[UIImageView alloc] initWithFrame:v.bounds];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.img = iv;
    [v addSubview:iv];

    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.05) dur = 1.5;
    v.spinDur = dur;
    [v kzApplyImage];
    [v kzAnim];
    return v;
}

// 只动眼睛，不动宿主、不改系统子视图
static void KZLayoutEye(KZEyeDot *eye, UIView *host) {
    if (!eye || !host) return;
    CGRect b = host.bounds;
    CGFloat side = KZEyeSide();
    double offx = KZPrefNum(@"offX", 0.0);
    double offy = KZPrefNum(@"offY", 0.0);

    eye.frame = CGRectMake((CGRectGetWidth(b) - side) / 2.0 + offx,
                           (CGRectGetHeight(b) - side) / 2.0 + offy, side, side);
    eye.layer.cornerRadius = side / 2.0;
    eye.img.frame = eye.bounds;

    NSInteger p = KZPreset();
    if (p != eye.preset) { eye.preset = p; [eye kzApplyImage]; }

    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.05) dur = 1.5;
    if (fabs(dur - eye.spinDur) > 0.001) {
        eye.spinDur = dur;
        [eye kzAnim];
    } else if (![eye.img.layer animationForKey:@"kzspin"]) {
        [eye kzAnim];
    }
}

#pragma mark - element 判定

static NSString *KZElemIdent(id elem) {
    if (!elem) return nil;
    @try {
        id v = [elem valueForKey:@"elementIdentifier"];
        if ([v isKindOfClass:[NSString class]]) return v;
    } @catch (...) {}
    return nil;
}
static BOOL KZIsRecording(id elem) {
    NSString *s = KZElemIdent(elem);
    return s.length > 0 && [s.lowercaseString containsString:@"screenrecording"];
}

#pragma mark - 主动扫描：不依赖系统再次调用 getter

static void KZInjectInto(UIView *host, NSString *slot);
static UIView *KZPillAncestor(UIView *v);
static NSHashTable *gLeadingPills;

// 从 SystemAperture 控制器直接拿 registeredElements —— 比扫视图树可靠
static id KZFindRecordingElementViaManager(void) {
    @try {
        id app = [UIApplication sharedApplication];
        SEL cs = NSSelectorFromString(@"systemApertureControllerForMainDisplay");
        if (![app respondsToSelector:cs]) return nil;
        id vc = ((id (*)(id, SEL))objc_msgSend)(app, cs);
        if (!vc) return nil;

        id mgr = nil;
        Ivar iv = class_getInstanceVariable([vc class], "_systemApertureManager");
        if (iv) mgr = object_getIvar(vc, iv);
        if (!mgr) {
            @try { mgr = [vc valueForKey:@"systemApertureManager"]; } @catch (...) {}
        }
        if (!mgr) return nil;

        SEL rg = NSSelectorFromString(@"registeredElements");
        if (![mgr respondsToSelector:rg]) return nil;
        NSArray *els = ((id (*)(id, SEL))objc_msgSend)(mgr, rg);
        if (![els isKindOfClass:[NSArray class]]) return nil;

        for (id e in els) {
            if (KZIsRecording(e)) return e;
        }
    } @catch (...) {}
    return nil;
}

static NSArray<UIWindow *> *KZAllWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                [out addObjectsFromArray:((UIWindowScene *)sc).windows];
            }
        }
    } @catch (...) {}
    return out;
}

// 沿类继承链找 ivar（class_getInstanceVariable 在某些类上拿不到父类的）
static id KZProviderOf(UIView *v) {
    Class c = [v class];
    while (c && c != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(c, "_elementViewProvider");
        if (iv) {
            id p = object_getIvar(v, iv);
            if (p) return p;
        }
        c = class_getSuperclass(c);
    }
    @try { return [v valueForKey:@"elementViewProvider"]; } @catch (...) {}
    return nil;
}

// 往上找药丸容器（同一个容器 = 同一个岛）
static UIView *KZPillAncestor(UIView *v) {
    UIView *cur = v;
    NSInteger hops = 0;
    while (cur && hops++ < 14) {
        NSString *cn = NSStringFromClass(cur.class);
        if ([cn rangeOfString:@"SBSystemApertureContainerView"].location != NSNotFound &&
            [cn rangeOfString:@"ContentView"].location == NSNotFound) {
            return cur;
        }
        cur = cur.superview;
    }
    return nil;
}


// 扫全树里所有 accessory view，判定属于录屏 element 的就注入
static NSInteger KZScanAccessories(void) {
    NSInteger found = 0;

    // 首选：直接问 manager 要录屏 element，再主动调它的三个 getter
    id rec = KZFindRecordingElementViaManager();
    if (rec) {
        NSArray *sels = @[ @"leadingView", @"expandedLeadingView", @"minimalView" ];
        for (NSString *name in sels) {
            SEL sel = NSSelectorFromString(name);
            if ([rec respondsToSelector:sel]) {
                @try { ((id (*)(id, SEL))objc_msgSend)(rec, sel); found++; } @catch (...) {}
            }
        }
        if (found > 0) return found;
    }

    NSMutableArray *stack = [NSMutableArray array];
    for (UIWindow *w in KZAllWindows()) [stack addObject:w];

    NSMutableArray *hosts = [NSMutableArray array];
    NSInteger guard = 0;
    while (stack.count && guard++ < 6000) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"SBSystemApertureSceneElementAccessoryView"]) {
            [hosts addObject:v];
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }

    for (UIView *host in hosts) {
        if (!host.window) continue;
        id provider = KZProviderOf(host);
        if (!KZIsRecording(provider)) continue;
        if (!gLeadingPills) gLeadingPills = [NSHashTable weakObjectsHashTable];
        UIView *pill = KZPillAncestor(host);

        // 同一个药丸里已经有写轮眼 → 说明这是右半边的槽位，跳过（避免一个岛里两个素材）
        BOOL alreadyHasEye = NO;
        for (UIView *s in host.subviews) {
            if (s.tag == KZ_EYE_TAG) { alreadyHasEye = YES; break; }
        }
        BOOL pillTaken = (pill && [gLeadingPills containsObject:pill] && !alreadyHasEye);
        if (pillTaken) {
            // 把之前误注入的素材摘掉
            for (UIView *s in [host.subviews copy]) {
                if (s.tag == KZ_EYE_TAG) [s removeFromSuperview];
            }
            continue;
        }
        KZInjectInto(host, @"scan");
        if (pill && !alreadyHasEye) [gLeadingPills addObject:pill];
        found++;
    }
    return found;
}

// 每 tick 主动去问 element 要一遍视图 —— getter 里会走我们的 hook 完成注入。
// 这样即使系统重建了 accessory、或暂停后不再自动取视图，素材也能自己回来。
static void KZRescanInject(void) { KZScanAccessories(); }

#pragma mark - 注入（纯叠加：红点被盖住，系统内容一律保留）

static NSHashTable *gHosts = nil;
static void KZTrack(UIView *v) {
    if (!gHosts) gHosts = [NSHashTable weakObjectsHashTable];
    [gHosts addObject:v];
}

static void KZInjectInto(UIView *host, NSString *slot) {
    if (!host) return;
    KZTrack(host);
    if (!KZPrefBool(@"enabled", YES)) return;
    if (!KZEyeAllowed()) return;    // 3-2-1 倒计时期间不动系统界面

    KZEyeDot *eye = nil;
    for (UIView *s in host.subviews) {
        if (s.tag == KZ_EYE_TAG && [s isKindOfClass:[KZEyeDot class]]) { eye = (KZEyeDot *)s; break; }
    }
    if (!eye) {
        eye = KZMakeEye(KZEyeSide());
        [host addSubview:eye];
        KZOnce([NSString stringWithFormat:@"inj-%@", slot],
               [NSString stringWithFormat:@"[inject] %@ ← %@ %.0fx%.0f",
                slot, NSStringFromClass(host.class),
                CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds)]);
    } else if (eye.superview != host) {
        [eye removeFromSuperview];
        [host addSubview:eye];
    }
    [host bringSubviewToFront:eye];
    eye.hidden = NO;
    KZLayoutEye(eye, host);

    UIView *pill = KZPillAncestor(host);
    if (pill) {
        if (!gLeadingPills) gLeadingPills = [NSHashTable weakObjectsHashTable];
        [gLeadingPills addObject:pill];
    }
}

#pragma mark - hooks

static id (*origLeading)(id, SEL);
static id kzLeading(id self, SEL _cmd) {
    id v = nil;
    @try { v = origLeading ? origLeading(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecording(self) && [v isKindOfClass:[UIView class]]) KZInjectInto((UIView *)v, @"leadingView");
    return v;
}
static id (*origExpLeading)(id, SEL);
static id kzExpLeading(id self, SEL _cmd) {
    id v = nil;
    @try { v = origExpLeading ? origExpLeading(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecording(self) && [v isKindOfClass:[UIView class]]) KZInjectInto((UIView *)v, @"expandedLeadingView");
    return v;
}
static id (*origMinimal)(id, SEL);
static id kzMinimal(id self, SEL _cmd) {
    id v = nil;
    @try { v = origMinimal ? origMinimal(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecording(self) && [v isKindOfClass:[UIView class]]) KZInjectInto((UIView *)v, @"minimalView");
    return v;
}

// 只对录屏 element 请求更宽的布局：拉长后左侧槽位右移，避开挖孔不裁角
static NSInteger (*origPref)(id, SEL);
static NSInteger kzPref(id self, SEL _cmd) {
    NSInteger v = 0;
    @try { v = origPref ? origPref(self, _cmd) : 0; } @catch (...) {}
    if (KZIsRecording(self)) {
        NSInteger out = MAX(v, 2);
        KZOnce([NSString stringWithFormat:@"pref-%ld", (long)out],
               [NSString stringWithFormat:@"[layout] preferred %ld -> %ld", (long)v, (long)out]);
        return out;
    }
    return v;
}
static NSInteger (*origMax)(id, SEL);
static NSInteger kzMax(id self, SEL _cmd) {
    NSInteger v = 0;
    @try { v = origMax ? origMax(self, _cmd) : 0; } @catch (...) {}
    if (KZIsRecording(self)) {
        NSInteger out = MAX(v, 3);
        KZOnce([NSString stringWithFormat:@"max-%ld", (long)out],
               [NSString stringWithFormat:@"[layout] max %ld -> %ld", (long)v, (long)out]);
        return out;
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
    SEL s3 = NSSelectorFromString(@"minimalView");
    SEL s4 = NSSelectorFromString(@"preferredLayoutMode");
    SEL s5 = NSSelectorFromString(@"maximumSupportedLayoutMode");
    if ([c instancesRespondToSelector:s1]) { MSHookMessageEx(c, s1, (IMP)kzLeading, (IMP *)&origLeading); n++; }
    if ([c instancesRespondToSelector:s2]) { MSHookMessageEx(c, s2, (IMP)kzExpLeading, (IMP *)&origExpLeading); n++; }
    if ([c instancesRespondToSelector:s3]) { MSHookMessageEx(c, s3, (IMP)kzMinimal, (IMP *)&origMinimal); n++; }
    if ([c instancesRespondToSelector:s4]) { MSHookMessageEx(c, s4, (IMP)kzPref, (IMP *)&origPref); n++; }
    if ([c instancesRespondToSelector:s5]) { MSHookMessageEx(c, s5, (IMP)kzMax, (IMP *)&origMax); n++; }
    if (n) { gHooked = YES; PLog(@"[hook] hook 了 %d 个方法", n); }
}

#pragma mark - 保活 / 清理

static NSTimer *gTimer = nil;
static BOOL gWasActive = NO;
static double gLastActiveAt = 0;

// 递归扫全窗口，把所有 tag==KZ_EYE_TAG 的视图摘掉（不依赖 gHosts 记录）
static void KZSweepEyes(UIView *v, NSInteger depth) {
    if (!v || depth > 24) return;
    for (UIView *s in [v.subviews copy]) {
        if (s.tag == KZ_EYE_TAG) { [s removeFromSuperview]; continue; }
        KZSweepEyes(s, depth + 1);
    }
}
static void KZRemoveAllEyes(void) {
    for (UIWindow *w in KZAllWindows()) KZSweepEyes(w, 0);
    [gHosts removeAllObjects];
    if (gLeadingPills) [gLeadingPills removeAllObjects];
}

static void KZTick(void) {
    KZInstall();

    // 总开关：关掉立刻清除；重新打开立刻重扫注入
    static BOOL gSwitchWasOn = YES;
    BOOL on = KZPrefBool(@"enabled", YES);
    if (!on) {
        if (gSwitchWasOn) {
            gSwitchWasOn = NO;
            KZRemoveAllEyes();
            PLog(@"[switch] 总开关关闭，已移除全部素材");
        }
        return;
    }
    if (!gSwitchWasOn) {
        gSwitchWasOn = YES;
        gSeen = nil;
        PLog(@"[switch] 总开关开启，重新注入");
        if (KZRecordingActive()) KZScanAccessories();
    }

    BOOL active = KZRecordingActive();
    double now = CACurrentMediaTime();

    if (active) {
        gLastActiveAt = now;
        if (!gWasActive) {
            gWasActive = YES;
            gActiveSince = now;
            gSeen = nil;
            if (gLeadingPills) [gLeadingPills removeAllObjects];
            PLog(@"[state] 录屏开始（倒计时保护 %.1fs）", gEyeGate);
        }
    } else if (gWasActive && (now - gLastActiveAt) > 3.0) {
        // 连续 3 秒都检测不到录屏才算结束 —— 暂停时 isCaptured 会短暂掉一下，不能立刻清
        gWasActive = NO;
        gActiveSince = 0;
        gSeen = nil;
        if (gHosts && gHosts.count) {
            for (UIView *h in [[gHosts allObjects] copy]) {
                for (UIView *s in [h.subviews copy]) {
                    if (s.tag == KZ_EYE_TAG) [s removeFromSuperview];
                }
            }
            [gHosts removeAllObjects];
            if (gLeadingPills) [gLeadingPills removeAllObjects];
            KZOnce(@"clean", @"[inject] 录屏结束，已移除素材");
        }
        PLog(@"[state] captured=0");
        return;
    }

    if (!gWasActive) return;

    // 倒计时没走完，什么都不做（但 host 已经在 KZInjectInto 里登记过了）
    if (!KZEyeAllowed()) return;

    // 每 tick 主动扫描并注入：不依赖系统再次调用 getter
    KZRescanInject();
    if (gHosts) {
        for (UIView *h in [[gHosts allObjects] copy]) {
            if (!h.window) continue;
            KZInjectInto(h, @"tick");
        }
    }
}

// 改设置：原地刷新（不销毁，避免素材消失）
static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSeen = nil;
        if (!KZPrefBool(@"enabled", YES)) {
            KZRemoveAllEyes();
            PLog(@"[switch] 通知：总开关关闭，已移除全部素材");
            return;
        }
        if (gHosts && KZEyeAllowed()) {
            for (UIView *h in [[gHosts allObjects] copy]) {
                KZInjectInto(h, @"reapply");
            }
        }
        PLog(@"[apply] scale=%.2f offX=%.1f offY=%.1f dur=%.2f preset=%ld",
             KZPrefNum(@"scale", 1.0), KZPrefNum(@"offX", 0.0), KZPrefNum(@"offY", 0.0),
             KZPrefNum(@"duration", 1.5), (long)KZPreset());
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    {
        Dl_info di; NSString *path = @"?";
        if (dladdr((void *)&KZTick, &di) && di.dli_fname) path = [NSString stringWithUTF8String:di.dli_fname];
        PLog(@"ctor v" KZ_VER " (fast gate, file import, dumpV) dylib=%@", path);
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        KZInstall();
        if (!gTimer || !gTimer.valid) {
            gTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
                @try { KZTick(); } @catch (NSException *e) { PLog(@"[tick] %@", e.reason); }
            }];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        }
    });
}