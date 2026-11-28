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
__attribute__((unused)) static BOOL KZPrefBool(NSString *key, BOOL dflt) {
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

#pragma mark - 写轮眼视图（固定尺寸，不随容器拉伸，不吃点击）

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
    KZEyeCircleView *v = [[KZEyeCircleView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    v.kzSide = side;
    v.kzOffX = offx;
    PLog(@"[eye] side=%.1f offX=%.1f", side, offx);
    v.tag = KZ_EYE_TAG;
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = side / 2.0;
    v.layer.masksToBounds = YES;
    v.userInteractionEnabled = NO;
    v.autoresizingMask = UIViewAutoresizingNone;

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

#pragma mark - o2Pro 式：把系统录屏 element 的 viewProvider 换成我们的

@interface KZVCProvider : NSObject
@property (nonatomic, strong) id systemElement;
@property (nonatomic, strong) UIView *eye;
@end

static char kKZEyeKey;

@implementation KZVCProvider

- (UIView *)kzEye {
    if (!_eye) _eye = KZMakeEye();
    return _eye;
}

// SAElementIdentifying
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
// SAElement / SAElementViewProviding
- (id)element { return self.systemElement; }
- (id)viewProvider { return self; }
- (BOOL)_canShowWhileLocked { return YES; }

// 视图：左边给写轮眼，minimal 也给写轮眼；其余（trailing 等）转发给系统 element
- (UIView *)leadingView {
    KZOnce(@"lead", @"[prov] leadingView = 写轮眼");
    return [self kzEye];
}
- (UIView *)expandedLeadingView {
    KZOnce(@"explead", @"[prov] expandedLeadingView = 写轮眼");
    return [self kzEye];
}
- (UIView *)minimalView {
    KZOnce(@"min", @"[prov] minimalView = 写轮眼");
    return [self kzEye];
}
- (UIView *)trailingView {
    UIView *o = nil;
    @try { if ([self.systemElement respondsToSelector:@selector(trailingView)]) o = [self.systemElement trailingView]; } @catch (...) {}
    return o;
}
- (UIView *)expandedTrailingView {
    UIView *o = nil;
    @try { if ([self.systemElement respondsToSelector:_cmd]) o = [self.systemElement expandedTrailingView]; } @catch (...) {}
    return o;
}

// 布局：跟随系统 element
- (NSInteger)layoutMode { return [self.systemElement respondsToSelector:_cmd] ? (NSInteger)[self.systemElement layoutMode] : 0; }
- (NSInteger)preferredLayoutMode { return [self.systemElement respondsToSelector:_cmd] ? (NSInteger)[self.systemElement preferredLayoutMode] : 1; }
- (NSInteger)maximumSupportedLayoutMode { return [self.systemElement respondsToSelector:_cmd] ? (NSInteger)[self.systemElement maximumSupportedLayoutMode] : 3; }
- (NSInteger)minimumSupportedLayoutMode { return 0; }
- (void)setLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    @try {
        if ([self.systemElement respondsToSelector:_cmd])
            ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(self.systemElement, _cmd, mode, reason);
    } @catch (...) {}
}

- (CGSize)sizeThatFitsSize:(CGSize)size forProvidedView:(UIView *)view inLayoutMode:(NSInteger)mode {
    if (view == self.eye || view.tag == KZ_EYE_TAG) return CGSizeMake(22, 22);
    @try {
        if ([self.systemElement respondsToSelector:_cmd]) {
            NSMethodSignature *sig = [self.systemElement methodSignatureForSelector:_cmd];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:self.systemElement];
                [inv setSelector:_cmd];
                [inv setArgument:&size atIndex:2];
                [inv setArgument:&view atIndex:3];
                [inv setArgument:&mode atIndex:4];
                [inv invoke];
                CGSize out = CGSizeZero;
                [inv getReturnValue:&out];
                return out;
            }
        }
    } @catch (...) {}
    return CGSizeMake(22, 22);
}

// 未实现的选择器转发给系统 element（保持系统行为）
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
    id target = self.systemElement;
    if (target) {
        @try {
            if ([target respondsToSelector:inv.selector]) { [inv invokeWithTarget:target]; return; }
        } @catch (...) {}
    }
    NSUInteger len = [[inv methodSignature] methodReturnLength];
    if (len > 0) { void *buf = calloc(1, len); [inv setReturnValue:buf]; free(buf); }
}
@end

#pragma mark - hook：manager 给录屏 element 建 VC 之后，把它的 provider 换掉

static NSString *KZElemIdent(id elem) {
    @try {
        id eid = [elem valueForKey:@"elementIdentifier"];
        if ([eid isKindOfClass:[NSString class]]) return eid;
    } @catch (...) {}
    return nil;
}
static BOOL KZIsRecording(id elem) {
    NSString *eid = KZElemIdent(elem);
    return eid.length > 0 && [eid.lowercaseString containsString:@"screenrecording"];
}

static id (*origElemVC2)(id, SEL, id, BOOL);
static id kzElemVC2(id self, SEL _cmd, id elem, BOOL create) {
    id vc = nil;
    @try { vc = origElemVC2 ? origElemVC2(self, _cmd, elem, create) : nil; } @catch (...) {}
    if (!vc || !KZIsRecording(elem)) return vc;

    @try {
        // 已经换过就不要再换（同一个 element 只用一份 provider）
        id cur = KZElemIdent(elem);
        KZOnce([NSString stringWithFormat:@"vc-%@", cur],
               [NSString stringWithFormat:@"[vc] 录屏 element VC=%@（开始替换 provider）", NSStringFromClass([vc class])]);
        Ivar iv = class_getInstanceVariable([vc class], "_elementViewProvider");
        if (!iv) { PLog(@"[vc] 没有 _elementViewProvider ivar"); return vc; }
        id old = object_getIvar(vc, iv);
        if ([old isKindOfClass:[KZVCProvider class]]) return vc;   // 已经是我们的

        KZVCProvider *p = [[KZVCProvider alloc] init];
        p.systemElement = elem;
        object_setIvar(vc, iv, p);
        objc_setAssociatedObject(vc, &kKZEyeKey, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 缓存里的视图如果已经建好，直接让 VC 重新取一次
        @try {
            if ([vc respondsToSelector:NSSelectorFromString(@"setNeedsLayout")]) [vc setNeedsLayout];
            if ([vc respondsToSelector:NSSelectorFromString(@"_configureAlertAssertionIfNecessary")]) {}
        } @catch (...) {}
        PLog(@"[vc] provider 已换成 KZVCProvider（原 %@）", old ? NSStringFromClass([old class]) : @"nil");
    } @catch (NSException *e) {
        PLog(@"[vc] 替换异常 %@", e.reason);
    }
    return vc;
}

static BOOL gHooked = NO;
static void KZInstall(void) {
    if (gHooked) return;
    Class c = NSClassFromString(@"SAUISystemApertureManager");
    if (!c) { KZOnce(@"noclass", @"[hook] 找不到 SAUISystemApertureManager"); return; }
    SEL s = NSSelectorFromString(@"_elementViewControllerForElement:creatingIfNecessary:");
    if (![c instancesRespondToSelector:s]) { KZOnce(@"nosel", @"[hook] 私有 VC 方法不存在"); gHooked = YES; return; }
    MSHookMessageEx(c, s, (IMP)kzElemVC2, (IMP *)&origElemVC2);
    gHooked = YES;
    PLog(@"[hook] 已 hook _elementViewControllerForElement:creatingIfNecessary:");
}

static void KZReapply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSeen = nil;
        KZInstall();
        PLog(@"[apply] 重新应用（scale=%.2f duration=%.2f）", KZPrefNum(@"scale", 1.0), KZPrefNum(@"duration", 1.5));
    });
}
static void KZNotifyCB(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef i) {
    KZReapply();
}

%ctor {
    PLog(@"ctor v1.39 (o2pro + prefs)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, KZNotifyCB,
                                    CFSTR(KZ_NOTIFY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { KZInstall(); } @catch (...) {}
        }];
    });
}