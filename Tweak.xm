#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdarg.h>

#define KZ_LOG @"/var/mobile/KZprobe.log"

static void PLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], body];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:KZ_LOG error:nil];
    if ([attr fileSize] > 120 * 1024) {
        [line writeToFile:KZ_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:KZ_LOG];
    if (!fh) {
        [line writeToFile:KZ_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (...) {}
    }
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

static void KZDump(NSString *tag) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];

    NSArray *windows = [[UIApplication sharedApplication] windows];
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
    PLog(@"springboard launched, probe armed");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            KZProbeTick();
        }];
    });
    return r;
}

%end

%ctor {
    PLog(@"probe ctor (v0.1)");
}
