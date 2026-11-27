#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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
    NSString *line = [NSString stringWithFormat:@"%@\n", body];
    if (gDump.length < 60000) [gDump appendString:line];
    KZFlush();
}

static NSMutableSet *gSeenCtx = nil;
static NSMutableSet *gReplaced = nil;

// 沿父视图往上找 element 的标识信息
static NSString *KZContext(UIView *v) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *keys = @[ @"elementIdentifier", @"identifier", @"bundleIdentifier",
                       @"sceneIdentifier", @"element", @"sceneElement", @"dataSource" ];
    UIView *cur = v;
    int depth = 0;
    while (cur && depth < 14) {
        for (NSString *k in keys) {
            @try {
                id val = [cur valueForKey:k];
                if (!val) continue;
                NSString *desc;
                if ([val isKindOfClass:[NSString class]]) {
                    desc = (NSString *)val;
                } else {
                    desc = [NSString stringWithFormat:@"%@", val];
                    if ([val respondsToSelector:@selector(elementIdentifier)]) {
                        @try {
                            id inner = [val valueForKey:@"elementIdentifier"];
                            if (inner) desc = [desc stringByAppendingFormat:@" elemId=%@", inner];
                        } @catch (...) {}
                    }
                }
                if (desc.length && [desc length] < 300) {
                    [out addObject:[NSString stringWithFormat:@"%@.%@=%@", NSStringFromClass([cur class]), k, desc]];
                }
            } @catch (...) {}
        }
        cur = cur.superview;
        depth++;
    }
    return [out componentsJoinedByString:@" | "];
}

static UIView *gEyeView = nil;
static UIView *KZEyeView(void) {
    if (gEyeView) return gEyeView;

    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    v.backgroundColor = [UIColor blackColor];
    v.layer.cornerRadius = 11.0;
    v.layer.masksToBounds = YES;

    UIImage *img = [UIImage imageWithContentsOfFile:KZ_EYE];
    if (!img) img = [UIImage imageWithContentsOfFile:KZ_EYE_ALT];
    if (img) {
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
    } else {
        PLog(@"[img] 读不到 %@", KZ_EYE);
    }
    gEyeView = v;
    return v;
}

@interface _SAUIProvidedViewContainerView : UIView
- (void)setProvidedView:(UIView *)view;
@end

%hook _SAUIProvidedViewContainerView

- (void)setProvidedView:(UIView *)view {
    NSString *ctx = KZContext((UIView *)self);
    NSString *key = [NSString stringWithFormat:@"%p|%@|%@", self, NSStringFromClass([view class]), ctx];
    if (!gSeenCtx) gSeenCtx = [NSMutableSet set];
    if (ctx.length && ![gSeenCtx containsObject:key]) {
        [gSeenCtx addObject:key];
        PLog(@"[setPV] so=%@ provided=%@ %.1fx%.1f ctx=%@",
             NSStringFromClass([self class]), NSStringFromClass([view class]),
             view.frame.size.width, view.frame.size.height, ctx);
    }
    NSString *low = ctx.lowercaseString;
    if (view && ([low containsString:@"recording"] || [low containsString:@"replay"])) {
        if (!gReplaced) gReplaced = [NSMutableSet set];
        NSString *tag = [NSString stringWithFormat:@"%p", self];
        if (![gReplaced containsObject:tag]) {
            [gReplaced addObject:tag];
            PLog(@"[replace] 命中屏幕录制 element，换入写轮眼视图");
        }
        %orig(KZEyeView());
        return;
    }
    %orig(view);
}

%end

%ctor {
    PLog(@"ctor v0.4 (eye replace)");
}
