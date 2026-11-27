#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
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

static int gDumpCount = 0;
static NSMutableSet *gSeen = nil;

static void KZDumpAncestors(UIView *v, NSString *tag) {
    UIView *cur = v;
    int depth = 0;
    while (cur && depth < 10) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([cur class], &count);
        NSMutableString *line = [NSMutableString string];
        for (unsigned k = 0; k < count && k < 45; k++) {
            const char *nm = ivar_getName(ivars[k]);
            const char *tp = ivar_getTypeEncoding(ivars[k]);
            NSString *val = @"";
            if (tp && tp[0] == '@') {
                @try {
                    id obj = object_getIvar(cur, ivars[k]);
                    if (obj) {
                        NSString *d;
                        if ([obj isKindOfClass:[NSString class]]) {
                            d = (NSString *)obj;
                        } else {
                            d = NSStringFromClass([obj class]);
                            if ([obj respondsToSelector:@selector(elementIdentifier)]) {
                                @try {
                                    id eid = [obj valueForKey:@"elementIdentifier"];
                                    if (eid) d = [d stringByAppendingFormat:@" elemId=%@", eid];
                                } @catch (...) {}
                            }
                        }
                        if (d.length > 90) d = [d substringToIndex:90];
                        val = [NSString stringWithFormat:@"=%@", d];
                    }
                } @catch (...) {}
            }
            [line appendFormat:@"%s%@  ", nm ? nm : "?", val];
        }
        if (ivars) free(ivars);
        PLog(@"[anc%d %@] %@ :: %@", depth, tag, NSStringFromClass([cur class]), line);
        cur = cur.superview;
        depth++;
    }
}

static void (*origDidMove)(id, SEL);
static void KZDidMove(id self, SEL _cmd) {
    if (origDidMove) origDidMove(self, _cmd);
    UIView *container = (UIView *)self;
    if (!container.window) return;
    if (gDumpCount >= 4) return;
    int idx = gDumpCount++;
    __weak UIView *wc = container;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *c = wc;
        if (!c) return;
        PLog(@"[moved#%d] %@ %.1fx%.1f inWindow=%d", idx, NSStringFromClass([c class]),
             c.bounds.size.width, c.bounds.size.height, c.window ? 1 : 0);
        KZDumpAncestors(c, [NSString stringWithFormat:@"m%d", idx]);
    });
}

static void (*origSetPV)(id, SEL, UIView *) = NULL;
static void KZSetPV(id self, SEL _cmd, UIView *view) {
    if (view) {
        if (!gSeen) gSeen = [NSMutableSet set];
        UIView *container = (UIView *)self;
        NSString *key = [NSString stringWithFormat:@"%p", container];
        if (![gSeen containsObject:key] && gSeen.count < 8) {
            [gSeen addObject:key];
            PLog(@"[setPV] %@ provided=%@", NSStringFromClass([container class]), NSStringFromClass([view class]));
        }
    }
    if (origSetPV) origSetPV(self, _cmd, view);
}

static BOOL gHook1 = NO, gHook2 = NO;
static void KZTryInstall(void) {
    Class c = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (!c) return;
    if (!gHook1) {
        MSHookMessageEx(c, @selector(setProvidedView:), (IMP)KZSetPV, (IMP *)&origSetPV);
        gHook1 = YES;
        PLog(@"[hook] setProvidedView: ok");
    }
    if (!gHook2) {
        MSHookMessageEx(c, @selector(didMoveToWindow), (IMP)KZDidMove, (IMP *)&origDidMove);
        gHook2 = YES;
        PLog(@"[hook] didMoveToWindow ok");
    }
}

%ctor {
    PLog(@"ctor v0.8");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { KZTryInstall(); }];
    });
}
