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
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return dflt;
}
static BOOL KZPrefBool(NSString *key, BOOL dflt) {
    id v = KZPrefRaw(key);
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : dflt;
}
static NSString *KZPrefStr(NSString *key) {
    id v = KZPrefRaw(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

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
        if (img) PLog(@"[img] eye = %.0fx%.0f", img.size.width, img.size.height);
        else PLog(@"[img] 读不到素材");
    });
    return img;
}

#pragma mark - 写轮眼视图

// 固定尺寸（可被设置改变），始终居中，不吃点击
@interface KZEyeCircleView : UIView
@property (nonatomic) CGFloat kzSide;
@property (nonatomic) CGFloat kzOffX;
@end
@implementation KZEyeCircleView
- (void)setFrame:(CGRect)frame {
    CGFloat side = self.kzSide > 0 ? self.kzSide : 22.0;
    CGRect f = frame;
    f.origin.x += (frame.size.width - side) / 2.0 + self.kzOffX;
    f.origin.y += (frame.size.height - side) / 2.0;
    f.size = CGSizeMake(side, side);
    [super setFrame:f];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *s in self.subviews) s.frame = self.bounds;
}
@end

static UIView *KZMakeEye(void) {
    double sc = KZPrefNum(@"scale", 1.0);
    if (sc < 0.3 || sc > 2.5) sc = 1.0;
    CGFloat side = 22.0 * sc;
    CGFloat offx = KZPrefNum(@"offX", 0.0);
    double dur = KZPrefNum(@"duration", 1.5);
    if (dur < 0.2) dur = 1.5;

    KZEyeCircleView *v = [[KZEyeCircleView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    v.kzSide = side;
    v.kzOffX = offx;
    v.tag = KZ_EYE_TAG;
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = side / 2.0;
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;
    v.autoresizingMask = UIViewAutoresizingNone;
    PLog(@"[eye] side=%.1f offX=%.1f dur=%.2f", side, offx, dur);

    UIImage *img = KZEyeImage();
    if (!img) {
        v.backgroundColor = [UIColor redColor];
        return v;
    }
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = v.bounds;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingNone;
    [v addSubview:iv];

    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = dur;
    spin.repeatCount = INFINITY;
    [iv.layer addAnimation:spin forKey:@"kzspin"];
    return v;
}

#pragma mark - 代理 provider（替换系统录屏 element 的 viewProvider）

static NSInteger gGen = 0;   // 每次改设置 +1，代理据此重建视图

@interface KZVCProvider : NSObject
@property (nonatomic, strong) id systemElement;
@property (nonatomic, strong) UIView *eye;
@property (nonatomic) NSInteger gen;
@end

@implementation KZVCProvider

- (UIView *)kzEye {
    if (!KZPrefBool(@"enabled", YES)) return nil;
    if (_eye && _gen == gGen) return _eye;
    if (_eye) [_eye removeFromSuperview];
    _eye = KZMakeEye();
    _gen = gGen;
    return _eye;
}

- (NSString *)elementIdentifier {
    NSString *s = nil;
    @try { s = [self.systemElement valueForKey:@"elementIdentifier"]; } @catch (...) {}
    return s ?: @"KZSharinganElement";
}
- (NSString *)clientIdentifier {
    NSString *s = nil;
    @try { s = [self.systemElement valueForKey:@"clientIdentifier"]; } @catch (...) {}
    return s ?: @"com.minis.kzsa";
}
- (id)element { return self.systemElement; }
- (id)viewProvider { return self; }
- (BOOL)_canShowWhileLocked { return YES; }

- (UIView *)leadingView {
    if (!KZPrefBool(@"leftOn", YES)) return [self kzOriginal:@selector(leadingView)];
    UIView *e = [self kzEye];
    if (e) KZOnce(@"lead", @"[prov] leadingView = 写轮眼");
    return e ?: [self kzOriginal:@selector(leadingView)];
}
- (UIView *)expandedLeadingView {
    if (!KZPrefBool(@"leftOn", YES)) return [self kzOriginal:@selector(expandedLeadingView)];
    UIView *e = [self kzEye];
    return e ?: [self kzOriginal:@selector(expandedLeadingView)];
}
- (UIView *)minimalView {
    if (!KZPrefBool(@"leftOn", YES)) return [self kzOriginal:@selector(minimalView)];
    UIView *e = [self kzEye];
    if (e) KZOnce(@"min", @"[prov] minimalView = 写轮眼");
    return e ?: [self kzOriginal:@selector(minimalView)];
}
// trailing 一律交给系统：保留计时 / 暂停按钮
- (UIView *)trailingView { return [self kzOriginal:@selector(trailingView)]; }
- (UIView *)expandedTrailingView { return [self kzOriginal:@selector(expandedTrailingView)]; }

- (UIView *)kzOriginal:(SEL)sel {
    id t = self.systemElement;
    if (!t) return nil;
    @try {
        if ([t respondsToSelector:sel]) {
            id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            return fn(t, sel);
        }
    } @catch (...) {}
    return nil;
}

- (NSInteger)layoutMode { return [self kzInt:@selector(layoutMode) dflt:0]; }
- (NSInteger)preferredLayoutMode { return [self kzInt:@selector(preferredLayoutMode) dflt:1]; }
- (NSInteger)maximumSupportedLayoutMode { return [self kzInt:@selector(maximumSupportedLayoutMode) dflt:3]; }
- (NSInteger)minimumSupportedLayoutMode { return [self kzInt:@selector(minimumSupportedLayoutMode) dflt:0]; }
- (NSInteger)kzInt:(SEL)sel dflt:(NSInteger)d {
    id t = self.systemElement;
    if (t && [t respondsToSelector:sel]) {
        @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(t, sel); } @catch (...) {}
    }
    return d;
}
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    id t = self.systemElement;
    if (t && [t respondsToSelector:_cmd]) {
        @try { ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(t, _cmd, mode, reason); } @catch (...) {}
    }
}

- (CGSize)sizeThatFitsSize:(CGSize)size forProvidedView:(UIView *)view inLayoutMode:(NSInteger)mode {
    if (view.tag == KZ_EYE_TAG) {
        CGFloat side = [(KZEyeCircleView *)view kzSide];
        if (side <= 0) side = 22;
        return CGSizeMake(side, side);
    }
    id t = self.systemElement;
    if (t && [t respondsToSelector:_cmd]) {
        NSMethodSignature *sig = [t methodSignatureForSelector:_cmd];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:t]; [inv setSelector:_cmd];
            [inv setArgument:&size atIndex:2];
            [inv setArgument:&view atIndex:3];
            [inv setArgument:&mode atIndex:4];
            @try {
                [inv invoke];
                CGSize out = CGSizeZero;
                [inv getReturnValue:&out];
                return out;
            } @catch (...) {}
        }
    }
    return CGSizeMake(22, 22);
}

- (BOOL)respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel]) return YES;
    if (!self.systemElement) return NO;
    @try { return [self.systemElement respondsToSelector:sel]; } @catch (...) { return NO; }
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (!sig && self.systemElement) {
        @try { sig = [self.systemElement methodSignatureForSelector:sel]; } @catch (...) {}
    }
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    id t = self.systemElement;
    if (t) {
        @try {
            if ([t respondsToSelector:inv.selector]) { [inv invokeWithTarget:t]; return; }
        } @catch (...) {}
    }
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

// 每个 element 一份代理（element 弱引用，回收即释放）
static NSMapTable *gProxies = nil;
static KZVCProvider *KZProxyFor(id element) {
    if (!element) return nil;
    if (!gProxies) gProxies = [NSMapTable weakToStrongObjectsMapTable];
    KZVCProvider *p = [gProxies objectForKey:element];
    if (!p) {
        p = [[KZVCProvider alloc] init];
        p.systemElement = element;
        p.gen = -1;
        [gProxies setObject:p forKey:element];
        PLog(@"[prov] 新建代理 for %@", NSStringFromClass([element class]));
    }
    return p;
}

static BOOL KZIsRecordingElement(id element) {
    if (!element) return NO;
    NSString *n = NSStringFromClass([element class]);
    if ([n rangeOfString:@"SBSystemApertureSceneElement"].location == NSNotFound) return NO;
    NSString *eid = nil;
    @try { eid = [element valueForKey:@"elementIdentifier"]; } @catch (...) {}
    return [eid isKindOfClass:[NSString class]] && [eid.lowercaseString containsString:@"screenrecording"];
}

#pragma mark - hook：VC 每次取 provider 都返回代理

static id (*origEVP)(id, SEL);
static id kzEVP(id self, SEL _cmd) {
    id orig = nil;
    @try { orig = origEVP ? origEVP(self, _cmd) : nil; } @catch (...) {}
    if (KZIsRecordingElement(orig)) {
        KZVCProvider *p = KZProxyFor(orig);
        if (p) {
            KZOnce(@"evp", @"[vc] elementViewProvider -> KZVCProvider（代理）");
            return p;
        }
    }
    return orig;
}

static BOOL gHooked = NO;
static void KZInstall(void) {
    if (gHooked) return;
    int n = 0;
    SEL s = NSSelectorFromString(@"elementViewProvider");
    for (NSString *cn in @[ @"SAUIElementViewController", @"SAUILayoutSpecifyingElementViewController" ]) {
        Class c = NSClassFromString(cn);
        if (c && [c instancesRespondToSelector:s]) {
            MSHookMessageEx(c, s, (IMP)kzEVP, (IMP *)&origEVP);
            n++;
        }
    }
    if (n) {
        gHooked = YES;
        PLog(@"[hook] hook elementViewProvider x%d", n);
    }
}

static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gGen++;
        if (gProxies) {
            for (id key in [[gProxies keyEnumerator] allObjects]) {
                KZVCProvider *p = [gProxies objectForKey:key];
                if (p.eye) { [p.eye removeFromSuperview]; p.eye = nil; }
                p.gen = -1;
            }
        }
        gSeen = nil;
        PLog(@"[apply] 重新应用 gen=%ld scale=%.2f offX=%.1f dur=%.2f", (long)gGen,
             KZPrefNum(@"scale", 1.0), KZPrefNum(@"offX", 0.0), KZPrefNum(@"duration", 1.5));
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.40 (elementViewProvider proxy)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { KZInstall(); } @catch (...) {}
        }];
    });
}