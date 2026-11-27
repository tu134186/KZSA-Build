#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <stdarg.h>

#define KZ_LOG @"/var/mobile/KZprobe.log"
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

static NSMutableSet *gSeen = nil;

static NSString *KZContext(UIView *v) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *keys = @[ @"elementIdentifier", @"identifier", @"bundleIdentifier",
                       @"sceneIdentifier", @"element", @"sceneElement", @"dataSource", @"clientStorage" ];
    UIView *cur = v;
    int depth = 0;
    while (cur && depth < 14) {
        for (NSString *k in keys) {
            @try {
                id val = [cur valueForKey:k];
                if (!val) continue;
                NSString *desc = [val isKindOfClass:[NSString class]] ? (NSString *)val
                                                                     : [NSString stringWithFormat:@"%@", val];
                if ([val respondsToSelector:@selector(elementIdentifier)]) {
                    @try {
                        id inner = [val valueForKey:@"elementIdentifier"];
                        if (inner) desc = [desc stringByAppendingFormat:@" elemId=%@", inner];
                    } @catch (...) {}
                }
                if (desc.length && desc.length < 260) {
                    [out addObject:[NSString stringWithFormat:@"%@.%@=%@", NSStringFromClass([cur class]), k, desc]];
                }
            } @catch (...) {}
        }
        cur = cur.superview;
        depth++;
    }
    return [out componentsJoinedByString:@" | "];
}

#import <objc/runtime.h>

static BOOL gDumped = NO;

static void KZDumpIvars(UIView *v, NSString *tag) {
    UIView *cur = v;
    for (int i = 0; i < 8 && cur; i++) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([cur class], &count);
        NSMutableString *line = [NSMutableString string];
        for (unsigned k = 0; k < count && k < 40; k++) {
            const char *name = ivar_getName(ivars[k]);
            const char *type = ivar_getTypeEncoding(ivars[k]);
            [line appendFormat:@"%s%s ", name ? name : "?", type ? type : "?"];
        }
        if (ivars) free(ivars);
        PLog(@"[ivars %@] %@ :: %@", tag, NSStringFromClass([cur class]), line);
        cur = cur.superview;
    }
}

static void KZDumpTree(UIView *v, NSString *tag, int depth) {
    if (depth > 3) return;
    PLog(@"[tree %@] %@(%.0fx%.0f)%@", tag, NSStringFromClass([v class]),
         v.frame.size.width, v.frame.size.height, v.isHidden ? @" hidden" : @"");
    for (UIView *s in v.subviews) KZDumpTree(s, tag, depth + 1);
}

static UIView *gEye = nil;
static UIView * __attribute__((unused)) KZEye(CGRect frame) {
    if (gEye) return gEye;
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = frame.size.width / 2.0;
    v.layer.masksToBounds = YES;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImage *img = [UIImage imageWithContentsOfFile:KZ_EYE];
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

    gEye = v;
    return v;
}

static void (*origSetPV)(id, SEL, UIView *) = NULL;

static void KZSetPV(id self, SEL _cmd, UIView *view) {
    UIView *container = (UIView *)self;
    NSString *ctx = KZContext(container);
    if (!gSeen) gSeen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f|%@", NSStringFromClass([view class]),
                     view.frame.size.width, view.frame.size.height, ctx];
    if (![gSeen containsObject:key]) {
        [gSeen addObject:key];
        PLog(@"[setPV] provided=%@ %.1fx%.1f ctx=%@", NSStringFromClass([view class]),
             view.frame.size.width, view.frame.size.height, ctx.length ? ctx : @"(空)");
    }

    if (view && view.frame.size.height > 20 && !gDumped) {
        gDumped = YES;
        KZDumpIvars(container, @"pv");
        KZDumpTree(view, @"pv", 0);
    }
    if (origSetPV) origSetPV(self, _cmd, view);
}

static BOOL gInstalled = NO;

static void KZTryInstall(void) {
    if (gInstalled) return;
    Class c = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (!c) return;
    MSHookMessageEx(c, @selector(setProvidedView:), (IMP)KZSetPV, (IMP *)&origSetPV);
    gInstalled = YES;
    PLog(@"[hook] 已挂钩 %@ setProvidedView:", NSStringFromClass(c));
}

%ctor {
    PLog(@"ctor v0.5 (dynamic hook)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            KZTryInstall();
        }];
    });
}
