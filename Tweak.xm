#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import "kzeye_b64.h"

#define KZ_DOMAIN "com.minis.kzprobe"
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

static UIView *KZEye(CGRect frame) {
    if (frame.size.width < 4) frame = CGRectMake(0, 0, 22, 22);
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = frame.size.width / 2.0;
    v.layer.masksToBounds = YES;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImage *img = nil;
    {
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
    iv.frame = v.bounds;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
    id cur = nil;
    @try { cur = [container valueForKey:@"providedView"]; } @catch (...) {}
    if ([cur isKindOfClass:[UIView class]] && [(UIView *)cur viewWithTag:0x4B5A]) return;
    PLog(@"[replace] 命中 %.0fx%.0f", container.bounds.size.width, container.bounds.size.height);
    UIView *eye = KZEye(container.bounds);
    eye.tag = 0x4B5A;
    if (origSetPV) origSetPV(container, @selector(setProvidedView:), eye);
}

static void KZScheduleReplace(UIView *container) {
    __weak UIView *wc = container;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

%ctor {
    PLog(@"ctor v1.2 (delayed replace)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { KZTryInstall(); }];
    });
}
