#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdarg.h>

#define KZ_LOG @"/var/mobile/KZprobe.log"
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
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], body];
    if (gDump.length < 60000) [gDump appendString:line];
    KZFlush();
}

static NSString *KZChain(UIView *v) {
    NSMutableArray *parts = [NSMutableArray array];
    UIView *cur = v;
    int n = 0;
    while (cur && n < 9) {
        [parts addObject:[NSString stringWithFormat:@"%@(%.1f,%.1f %.1fx%.1f)",
                          NSStringFromClass([cur class]),
                          cur.frame.origin.x, cur.frame.origin.y,
                          cur.frame.size.width, cur.frame.size.height]];
        cur = cur.superview;
        n++;
    }
    return [parts componentsJoinedByString:@" < "];
}

static NSString *KZIdOf(UIView *v) {
    NSArray *keys = @[ @"elementIdentifier", @"identifier", @"accessoryIdentifier" ];
    for (NSString *k in keys) {
        @try {
            id val = [v valueForKey:k];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length]) return val;
        } @catch (...) {}
    }
    return @"-";
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

static void KZDump(NSString *tag) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];

    NSArray *windows = KZWindows();
    int found = 0;
    for (UIWindow *w in windows) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        while (stack.count) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([v class]);

            BOOL hit = [cn containsString:@"ProvidedViewContainer"] ||
                       [cn containsString:@"SceneElementAccessory"] ||
                       [cn containsString:@"AccessoryPortal"];
            if (hit) {
                CGRect r = [v convertRect:v.bounds toView:nil];
                NSString *sig = [NSString stringWithFormat:@"%@|%@|%@", cn, KZIdOf(v), NSStringFromCGRect(r)];
                if (![seen containsObject:sig]) {
                    [seen addObject:sig];
                    id pv = nil;
                    @try { pv = [v valueForKey:@"providedView"]; } @catch (...) {}
                    NSString *pvDesc = pv ? [NSString stringWithFormat:@"%@ %.1fx%.1f",
                                             NSStringFromClass([pv class]),
                                             [pv isKindOfClass:[UIView class]] ? ((UIView *)pv).frame.size.width : 0.0,
                                             [pv isKindOfClass:[UIView class]] ? ((UIView *)pv).frame.size.height : 0.0]
                                          : @"nil";
                    PLog(@"[%@] %@ id=%@ screen=%@ provided=%@", tag, cn, KZIdOf(v), NSStringFromCGRect(r), pvDesc);
                    PLog(@"      chain: %@", KZChain(v));
                    found++;
                }
            }
            for (UIView *s in v.subviews) [stack addObject:s];
        }
    }
    if (found) PLog(@"--- 本次新增 %d 条 ---", found);
}

static void KZProbeTick(void) {
    KZDump(@"tick");
}

%hook SpringBoard

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL r = %orig;
    PLog(@"springboard launched (hook fired)");
    return r;
}

%end

%ctor {
    PLog(@"probe ctor (v0.3)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PLog(@"timer started");
        [NSTimer scheduledTimerWithTimeInterval:1.2 repeats:YES block:^(NSTimer *t) {
            KZProbeTick();
        }];
    });
}
