#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import "kzeye_b64.h"

#define KZ_DOMAIN "com.minis.kzprobe"

static NSMutableString *gDump = nil;
static void KZFlush(void) {
    if (!gDump) gDump = [NSMutableString string];
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

static NSString *KZElemId(id elem) {
    @try {
        id eid = [elem valueForKey:@"elementIdentifier"];
        if ([eid isKindOfClass:[NSString class]]) return eid;
    } @catch (...) {}
    return nil;
}

static UIImage *KZEyeImage(void) {
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

// 固定 22×22 的小圆：不管容器多大都居中保持原尺寸，不吃点击
@interface KZEyeCircleView : UIView
@end
@implementation KZEyeCircleView
- (void)setFrame:(CGRect)frame {
    CGFloat side = 22.0;
    CGRect f = frame;
    f.origin.x += (frame.size.width - side) / 2.0;
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
    UIView *v = [[KZEyeCircleView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = 11.0;
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

    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(0.0);
    spin.toValue = @(M_PI * 2.0);
    spin.duration = 1.5;
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

static BOOL KZIsRecordingElement(id self) {
    NSString *eid = KZElemId(self);
    return eid.length > 0 && [eid.lowercaseString containsString:@"screenrecording"];
}

// —— 每个 element 一份视图，存在关联对象上（暂停/恢复会换 element 实例）
static char kEyeKey;
static UIView *KZEyeFor(id self) {
    UIView *v = objc_getAssociatedObject(self, &kEyeKey);
    if (!v) {
        v = KZMakeEye();
        objc_setAssociatedObject(self, &kEyeKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return v;
}

// —— 倒计时期间不替换：第一次看到录屏 element 时记时间，满 3.6s 才开始给写轮眼
static double gFirstSeen = 0;
static double KZStartTime(id self) {
    static char kTKey;
    NSNumber *n = objc_getAssociatedObject(self, &kTKey);
    if (n) return n.doubleValue;
    double t = CACurrentMediaTime();
    objc_setAssociatedObject(self, &kTKey, @(t), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gFirstSeen == 0) gFirstSeen = t;
    return t;
}

static BOOL KZCountdownDone(id self) {
    double t = KZStartTime(self);
    BOOL done = (CACurrentMediaTime() - t) >= 3.6;
    static NSMutableSet *logged = nil;
    if (!logged) logged = [NSMutableSet set];
    NSString *k = [NSString stringWithFormat:@"cd-%d", done];
    if (![logged containsObject:k]) {
        [logged addObject:k];
        PLog(@"[lead] 倒计时 %@（%.1fs）", done ? @"已结束，开始显示写轮眼" : @"中，保持系统界面", CACurrentMediaTime() - t);
    }
    return done;
}

// 只替换 minimalView（收起时那个小点），leading/expanded 完全留给系统：
// 这样 3-2-1 倒计时、暂停按钮、数字、绿勾都是原生的，不会被盖住
static UIView *(*origMinimal)(id, SEL);
static UIView *kzMinimal(id self, SEL _cmd) {
    UIView *o = origMinimal ? origMinimal(self, _cmd) : nil;
    @try {
        if (KZIsRecordingElement(self) && KZCountdownDone(self)) {
            KZOnce(@"minimal", @"[lead] 提供写轮眼 via minimalView");
            return KZEyeFor(self);
        }
    } @catch (...) {}
    return o;
}

static BOOL gHooked = NO;
static void KZInstall(void) {
    if (gHooked) return;
    Class c = NSClassFromString(@"SBSystemApertureSceneElement");
    if (!c) { KZOnce(@"noclass", @"[hook] 找不到 SBSystemApertureSceneElement"); return; }
    SEL s3 = NSSelectorFromString(@"minimalView");
    if ([c instancesRespondToSelector:s3]) {
        MSHookMessageEx(c, s3, (IMP)kzMinimal, (IMP *)&origMinimal);
        gHooked = YES;
        PLog(@"[hook] 只 hook minimalView（leading 留给系统）");
    }
}

%ctor {
    PLog(@"ctor v1.36 (minimal only, countdown safe)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { KZInstall(); } @catch (...) {}
        }];
    });
}