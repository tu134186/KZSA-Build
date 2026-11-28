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

// 1.35：固定 22×22、不跟随容器拉伸、不拦截点击 —— 否则展开大岛时会把整个岛盖住、暂停按钮点不到
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

static UIView *KZEyeView(void) {
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

#pragma mark - 给系统录屏 element 提供视图（不再注册第二个 element）

static UIView *gLeadView = nil;
static UIView *(*origLead)(id, SEL);
static UIView *kzLead(id self, SEL _cmd) {
    UIView *o = origLead ? origLead(self, _cmd) : nil;
    @try {
        if (KZIsRecordingElement(self)) {
            KZOnce(@"lead", @"[lead] 提供写轮眼 via leadingView");
            if (!gLeadView) gLeadView = KZEyeView();
            return gLeadView;
        }
    } @catch (...) {}
    return o;
}

static UIView *(*origExpLead)(id, SEL);
static UIView *kzExpLead(id self, SEL _cmd) {
    UIView *o = origExpLead ? origExpLead(self, _cmd) : nil;
    @try {
        if (KZIsRecordingElement(self)) {
            KZOnce(@"explead", @"[lead] 提供写轮眼 via expandedLeadingView");
            if (!gLeadView) gLeadView = KZEyeView();
            return gLeadView;
        }
    } @catch (...) {}
    return o;
}

static UIView *gMinView = nil;
static UIView *(*origMinimal)(id, SEL);
static UIView *kzMinimal(id self, SEL _cmd) {
    UIView *o = origMinimal ? origMinimal(self, _cmd) : nil;
    @try {
        if (KZIsRecordingElement(self)) {
            KZOnce(@"minimal", @"[lead] 提供写轮眼 via minimalView");
            if (!gMinView) gMinView = KZEyeView();
            return gMinView;
        }
    } @catch (...) {}
    return o;
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
    if ([c instancesRespondToSelector:s1]) { MSHookMessageEx(c, s1, (IMP)kzLead, (IMP *)&origLead); n++; }
    if ([c instancesRespondToSelector:s2]) { MSHookMessageEx(c, s2, (IMP)kzExpLead, (IMP *)&origExpLead); n++; }
    if ([c instancesRespondToSelector:s3]) { MSHookMessageEx(c, s3, (IMP)kzMinimal, (IMP *)&origMinimal); n++; }
    if (n > 0) {
        gHooked = YES;
        PLog(@"[hook] 已 hook %d 个视图方法", n);
    }
}

%ctor {
    PLog(@"ctor v1.35 (fixed size view)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { KZInstall(); } @catch (...) {}
        }];
    });
}