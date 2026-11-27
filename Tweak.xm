#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

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

static id gManager = nil;

// 只在 manager 被创建时抓实例，不做任何遍历
static id (*origInit)(id, SEL, id);
static id kzInit(id self, SEL _cmd, id authority) {
    id r = nil;
    @try {
        r = origInit ? origInit(self, _cmd, authority) : nil;
    } @catch (...) {
        PLog(@"[init] 原实现抛出异常，已忽略");
        r = self;
    }
    if (r && !gManager) {
        gManager = r;
        PLog(@"[init] 抓到 manager: %@", NSStringFromClass([r class]));
    }
    return r;
}

static BOOL gHooked = NO;
static void KZTryHook(void) {
    if (gHooked) return;
    Class c = NSClassFromString(@"SAUISystemApertureManager");
    if (!c) return;
    SEL sel = NSSelectorFromString(@"initWithElementAuthority:");
    if (![c instancesRespondToSelector:sel]) {
        PLog(@"[hook] 没有 initWithElementAuthority:");
        gHooked = YES;
        return;
    }
    MSHookMessageEx(c, sel, (IMP)kzInit, (IMP *)&origInit);
    gHooked = YES;
    PLog(@"[hook] 已 hook initWithElementAuthority:");
}

// 定期把能力检查写一次（只读，不调用）
static void KZReport(void) {
    if (!gManager) return;
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSArray *sels = @[ @"registerElement:", @"_assertionForElementCreatingIfNecessary:",
                       @"elementAssertionForElement:", @"registeredElements", @"orderedElementViewControllers" ];
    NSMutableString *line = [NSMutableString string];
    for (NSString *s in sels) {
        BOOL ok = [gManager respondsToSelector:NSSelectorFromString(s)];
        [line appendFormat:@"%@:%@ ", s, ok ? @"YES" : @"NO"];
    }
    PLog(@"[cap] %@", line);
}

%hook SpringBoard

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL r = %orig;
    PLog(@"springboard launched (v1.19)");
    return r;
}

%end

%ctor {
    PLog(@"ctor v1.19 (capture manager)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try {
                KZTryHook();
                KZReport();
            } @catch (...) {
                PLog(@"[tick] 异常已忽略");
            }
        }];
    });
}
