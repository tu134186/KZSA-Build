#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <notify.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <spawn.h>
extern char **environ;

#define KZ_DOMAIN @"com.minis.kzsa"
#define KZ_NOTIFY "com.minis.kzsa.changed"

static NSString *KZPrefStr(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)KZ_DOMAIN);
    if (!v) return nil;
    NSString *s = [NSString stringWithFormat:@"%@", (__bridge id)v];
    CFRelease(v);
    return s;
}
static void KZPrefSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)KZ_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)KZ_DOMAIN);
}
static void KZPrefClear(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)KZ_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)KZ_DOMAIN);
}
static void KZPost(void) { notify_post(KZ_NOTIFY); }

@interface PSSpecifier (KZ)
- (id)performGetter;
- (void)performSetterWithValue:(id)value;
- (void)setCellClass:(Class)cls;
@end

#pragma mark - 一行：标签 + − 滑块 + 数值

@interface KZStepperCell : PSTableCell
@end

@implementation KZStepperCell {
    UISlider *_slider;
    UILabel *_value;
    UIButton *_minus;
    UIButton *_plus;
    double _min, _max, _step;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _min = [[specifier propertyForKey:@"min"] doubleValue];
        _max = [[specifier propertyForKey:@"max"] doubleValue];
        _step = [[specifier propertyForKey:@"step"] doubleValue];
        if (_step <= 0) _step = 0.05;
        if (_max <= _min) { _min = 0; _max = 1; }

        _value = [[UILabel alloc] init];
        _value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _value.textColor = [UIColor secondaryLabelColor];
        _value.textAlignment = NSTextAlignmentRight;

        _slider = [[UISlider alloc] init];
        _slider.minimumValue = (float)_min;
        _slider.maximumValue = (float)_max;
        [_slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];

        _minus = [self mkBtn:@"\u2212"];
        [_minus addTarget:self action:@selector(stepDown) forControlEvents:UIControlEventTouchUpInside];
        _plus = [self mkBtn:@"+"];
        [_plus addTarget:self action:@selector(stepUp) forControlEvents:UIControlEventTouchUpInside];

        for (UIView *v in @[ _value, _slider, _minus, _plus ]) [self.contentView addSubview:v];
        [self refreshCellContentsWithSpecifier:specifier];
    }
    return self;
}

- (UIButton *)mkBtn:(NSString *)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 11;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    return b;
}

- (double)cur {
    id v = [self.specifier performGetter];
    if (!v) v = [self.specifier propertyForKey:@"default"];
    double d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : _min;
    if (d < _min) d = _min;
    if (d > _max) d = _max;
    return d;
}

- (void)write:(double)v {
    if (v < _min) v = _min;
    if (v > _max) v = _max;
    [self.specifier performSetterWithValue:@(v)];
    _slider.value = (float)v;
    _value.text = [NSString stringWithFormat:@"%.2f", v];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_slider) return;
    double d = [self cur];
    _slider.value = (float)d;
    _value.text = [NSString stringWithFormat:@"%.2f", d];
}

- (void)sliderMoved:(UISlider *)s { [self write:round(s.value / _step) * _step]; }
- (void)stepDown { [self write:[self cur] - _step]; }
- (void)stepUp   { [self write:[self cur] + _step]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    self.titleLabel.hidden = YES;
    CGRect b = self.contentView.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    _value.frame = CGRectMake(w - 96, (h - 20) / 2.0, 84, 20);
    _minus.frame = CGRectMake(96, (h - 22) / 2.0, 22, 22);
    _plus.frame = CGRectMake(w - 96 - 22 - 10 - 0, (h - 22) / 2.0, 22, 22);
    _slider.frame = CGRectMake(96 + 22 + 10, (h - 30) / 2.0, w - 96 - 22 - 10 - 22 - 10 - 90, 30);
}

@end

#pragma mark - 控制器

@interface KZRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@end

@implementation KZRootListController

- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        Class stepper = NSClassFromString(@"KZStepperCell");
        for (PSSpecifier *s in _specifiers) {
            if ([s propertyForKey:@"action"]) [s setTarget:self];
            if ([s propertyForKey:@"step"] && stepper) {
                [s setProperty:stepper forKey:@"cellClass"];
                if ([s respondsToSelector:@selector(setCellClass:)]) [s setCellClass:stepper];
            }
        }
        [self decorate];
    }
    return _specifiers;
}

- (void)decorate {
    NSString *img = KZPrefStr(@"eyeImage");
    NSString *txt = (img.length > 200) ? @"自定义图片" : @"内置写轮眼";
    for (PSSpecifier *s in self.specifiers) {
        if ([[s propertyForKey:@"key"] isEqualToString:@"eyeName"]) {
            [s setName:[NSString stringWithFormat:@"当前：%@", txt]];
        }
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    KZPrefSet(key, value);
    KZPost();
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id v = key ? KZPrefStr(key) : nil;
    if (!v) v = [specifier propertyForKey:@"default"];
    return v;
}

- (void)storeImage:(UIImage *)img {
    if (!img || !img.CGImage) return;
    UIImage *norm = img;
    if (img.imageOrientation != UIImageOrientationUp) {
        UIGraphicsBeginImageContextWithOptions(img.size, NO, 1.0);
        [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
        norm = UIGraphicsGetImageFromCurrentImageContext() ?: img;
        UIGraphicsEndImageContext();
    }
    CGImageRef cg = norm.CGImage;
    if (!cg) return;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    size_t side = w < h ? w : h;
    CGImageRef sq = CGImageCreateWithImageInRect(cg, CGRectMake((double)(w - side) / 2.0, (double)(h - side) / 2.0, (double)side, (double)side));
    if (!sq) return;
    UIImage *sqImg = [UIImage imageWithCGImage:sq scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(sq);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(320, 320), NO, 1.0);
    [sqImg drawInRect:CGRectMake(0, 0, 320, 320)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *png = UIImagePNGRepresentation(out ?: sqImg);
    if (!png) return;
    KZPrefSet(@"eyeImage", [png base64EncodedStringWithOptions:0]);
    KZPost();
    [self decorate];
    [self.tableView reloadData];
}

- (void)importPhoto {
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{ [self storeImage:img]; }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)importFile {
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypePNG, UTTypeImage ]];
    dp.delegate = self;
    dp.allowsMultipleSelection = NO;
    [self presentViewController:dp animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    BOOL ok = [u startAccessingSecurityScopedResource];
    NSData *d = [NSData dataWithContentsOfURL:u];
    if (ok) [u stopAccessingSecurityScopedResource];
    if (d) [self storeImage:[UIImage imageWithData:d]];
}

- (void)openFolder {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"shareddocuments:///Library/KZTheme"]
                                       options:@{} completionHandler:nil];
}

- (void)respring {
    pid_t pid = 0;
    char *argv[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ);
}

- (void)resetAll {
    KZPrefClear(@"eyeImage");
    KZPrefClear(@"scale");
    KZPrefClear(@"scaleR");
    KZPrefClear(@"offX");
    KZPrefClear(@"offXR");
    KZPrefClear(@"duration");
    KZPrefClear(@"leftOn");
    KZPrefClear(@"rightOn");
    KZPrefClear(@"enabled");
    KZPost();
    [self decorate];
    [self.tableView reloadData];
}

- (void)applyNow { KZPost(); }

@end
