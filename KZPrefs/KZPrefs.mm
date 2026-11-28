#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <notify.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "kzpresets_b64.h"

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

#pragma mark - 滑块行

@interface KZStepperCell : PSTableCell
@end

@implementation KZStepperCell {
    UISlider *_slider;
    UILabel *_value;
    UILabel *_name;
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

        _name = [[UILabel alloc] init];
        _name.font = [UIFont systemFontOfSize:17];
        _name.text = [specifier propertyForKey:@"label"];

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

        for (UIView *v in @[ _name, _value, _slider, _minus, _plus ]) [self.contentView addSubview:v];
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
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    CGRect b = self.contentView.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    CGFloat valueW = 56, gap = 10, btn = 22;
    CGFloat valueX = w - 16 - valueW;
    CGFloat plusX = valueX - gap - btn;
    CGFloat sliderX = 96 + btn + gap;
    CGFloat sliderW = plusX - gap - sliderX;
    _name.frame = CGRectMake(16, (h - 21) / 2.0, sliderX - 16 - 8, 21);
    _minus.frame = CGRectMake(96, (h - btn) / 2.0, btn, btn);
    _slider.frame = CGRectMake(sliderX, (h - 30) / 2.0, MAX(sliderW, 40), 30);
    _plus.frame = CGRectMake(plusX, (h - btn) / 2.0, btn, btn);
    _value.frame = CGRectMake(valueX, (h - 20) / 2.0, valueW, 20);
}

@end

#pragma mark - 素材选择（两行网格）

static UIImage *KZPBase64(const char *b64) {
    if (!b64) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:b64]
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return d.length > 200 ? [UIImage imageWithData:d] : nil;
}

static NSArray *_kzPresetCache = nil;

static void KZPresetInvalidateCache(void) { _kzPresetCache = nil; }

static NSArray<UIImage *> *KZPresetImages(void) {
    if (_kzPresetCache) return _kzPresetCache;
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < kKZPresetCount; i++) {
        UIImage *u = KZPBase64(kKZPresetB64[i]);
        [a addObject:u ?: [UIImage new]];
    }
    NSString *b64 = KZPrefStr(@"eyeImage");
    UIImage *custom = nil;
    if (b64.length > 200) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d.length > 200) custom = [UIImage imageWithData:d];
    }
    [a addObject:custom ?: [UIImage new]];
    _kzPresetCache = a;
    return a;
}

static NSArray<NSString *> *KZPresetNames(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < kKZPresetCount; i++) [a addObject:[NSString stringWithUTF8String:kKZPresetNames[i]]];
    [a addObject:@"自定义"];
    return a;
}

static BOOL KZHasCustomImage(void) { return KZPrefStr(@"eyeImage").length > 200; }

@interface KZPresetCell : PSTableCell
@end

@implementation KZPresetCell {
    NSMutableArray<UIButton *> *_btns;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        _btns = [NSMutableArray array];

        NSArray<UIImage *> *imgs = KZPresetImages();
        NSArray<NSString *> *names = KZPresetNames();
        for (NSInteger i = 0; i < imgs.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = i;
            b.layer.cornerRadius = 24;
            b.layer.masksToBounds = YES;
            b.backgroundColor = [UIColor blackColor];
            b.imageView.contentMode = UIViewContentModeScaleAspectFill;
            [b setImage:imgs[i] forState:UIControlStateNormal];

            UILabel *lb = [[UILabel alloc] init];
            lb.text = names[i];
            lb.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
            lb.textColor = [UIColor secondaryLabelColor];
            lb.textAlignment = NSTextAlignmentCenter;
            lb.tag = 100;
            lb.userInteractionEnabled = NO;
            [b addSubview:lb];

            // 用外层包装实现「缩略图 + 下面文字」一起点击
            UIControl *wrap = [[UIControl alloc] init];
            wrap.tag = i;
            [wrap addSubview:b];
            [wrap addTarget:self action:@selector(pickWrap:) forControlEvents:UIControlEventTouchUpInside];
            [self.contentView addSubview:wrap];
            [_btns addObject:b];
            b.userInteractionEnabled = NO;
        }
        [self refreshCellContentsWithSpecifier:specifier];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_btns.count) return;
    NSInteger cur = (NSInteger)round([KZPrefStr(@"eyePreset") doubleValue]);
    for (UIButton *b in _btns) {
        BOOL sel = (b.tag == cur);
        b.layer.borderWidth = sel ? 2.5 : 0.0;
        b.layer.borderColor = sel ? [UIColor systemBlueColor].CGColor : [UIColor clearColor].CGColor;
        b.alpha = sel ? 1.0 : 0.85;
    }
}

- (void)pickWrap:(UIControl *)w {
    NSInteger idx = w.tag;
    if (idx == kKZPresetCount && !KZHasCustomImage()) {
        // 没有自定义图时点「自定义」→ 直接去导入
        [self sendActionToController:@"importPhoto"];
        return;
    }
    KZPrefSet(@"eyePreset", @(idx));
    KZPost();
    [self refreshCellContentsWithSpecifier:self.specifier];
}

- (void)sendActionToController:(NSString *)sel {
    UIResponder *r = self;
    while (r && ![r isKindOfClass:[PSListController class]]) r = r.nextResponder;
    if ([r isKindOfClass:[PSListController class]]) {
        SEL s = NSSelectorFromString(sel);
        if ([r respondsToSelector:s]) {
            ((void (*)(id, SEL))objc_msgSend)(r, s);
        }
    }
}

- (void)setHighlighted:(BOOL)h animated:(BOOL)a { [super setHighlighted:NO animated:NO]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    CGRect b = self.contentView.bounds;
    CGFloat pad = 12;
    CGFloat cols = 5;
    CGFloat avail = b.size.width - pad * 2;
    CGFloat gap = 8;
    CGFloat cellW = (avail - gap * (cols - 1)) / cols;
    CGFloat thumb = MIN(48.0, cellW);

    for (NSInteger i = 0; i < (NSInteger)_btns.count; i++) {
        UIButton *btn = _btns[i];
        UIControl *wrap = (UIControl *)btn.superview;
        NSInteger row = i / (NSInteger)cols;
        NSInteger col = i % (NSInteger)cols;
        CGFloat x = pad + col * (cellW + gap);
        CGFloat y = 6 + row * 72;
        wrap.frame = CGRectMake(x, y, cellW, 66);
        btn.frame = CGRectMake((cellW - thumb) / 2.0, 0, thumb, thumb);
        UILabel *lb = [btn viewWithTag:100];
        lb.frame = CGRectMake(-4, thumb + 4, cellW + 8, 13);
    }
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
        Class preset = NSClassFromString(@"KZPresetCell");
        for (PSSpecifier *s in _specifiers) {
            if ([s propertyForKey:@"action"]) [s setTarget:self];
            if ([s propertyForKey:@"step"] && stepper) {
                [s setProperty:stepper forKey:@"cellClass"];
                if ([s respondsToSelector:@selector(setCellClass:)]) [s setCellClass:stepper];
            }
            if ([s propertyForKey:@"presetPicker"] && preset) {
                [s setProperty:preset forKey:@"cellClass"];
                if ([s respondsToSelector:@selector(setCellClass:)]) [s setCellClass:preset];
            }
        }
    }
    return _specifiers;
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

#pragma mark 导入 / 删除自定义素材

- (UIImage *)normalizeImage:(UIImage *)img {
    if (!img || !img.CGImage) return nil;
    // 先转正
    UIImage *norm = img;
    if (img.imageOrientation != UIImageOrientationUp) {
        UIGraphicsBeginImageContextWithOptions(img.size, NO, 1.0);
        [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
        norm = UIGraphicsGetImageFromCurrentImageContext() ?: img;
        UIGraphicsEndImageContext();
    }
    CGImageRef cg = norm.CGImage;
    if (!cg) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    size_t side = w < h ? w : h;
    CGImageRef sq = CGImageCreateWithImageInRect(cg, CGRectMake((double)(w - side) / 2.0, (double)(h - side) / 2.0, (double)side, (double)side));
    if (!sq) return nil;
    UIImage *sqImg = [UIImage imageWithCGImage:sq scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(sq);

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(256, 256), YES, 1.0);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, 256, 256));
    [sqImg drawInRect:CGRectMake(0, 0, 256, 256)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: sqImg;
}

- (void)storeImage:(UIImage *)img {
    @try {
        UIImage *out = [self normalizeImage:img];
        if (!out) return;
        NSData *jpeg = UIImageJPEGRepresentation(out, 0.88);
        NSData *png = UIImagePNGRepresentation(out);
        NSData *use = (jpeg && jpeg.length < png.length) ? jpeg : png;
        if (!use || use.length > 400 * 1024) {
            use = UIImageJPEGRepresentation(out, 0.6);
        }
        if (!use) return;
        KZPrefSet(@"eyeImage", [use base64EncodedStringWithOptions:0]);
        KZPrefSet(@"eyePreset", @(kKZPresetCount));   // 自动切到「自定义」
        KZPost();
        KZPresetInvalidateCache();
        [self reloadSpecifiers];
    } @catch (NSException *e) {
        // 静默失败，不让设置进程崩
    }
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

- (void)deleteCustom {
    KZPrefClear(@"eyeImage");
    NSInteger cur = (NSInteger)round([KZPrefStr(@"eyePreset") doubleValue]);
    if (cur == kKZPresetCount) KZPrefSet(@"eyePreset", @(0));
    KZPost();
    KZPresetInvalidateCache();
    [self reloadSpecifiers];
}

#pragma mark 其它

- (void)resetAll {
    KZPrefClear(@"eyeImage");
    KZPrefClear(@"scale");
    KZPrefClear(@"offX");
    KZPrefClear(@"offY");
    KZPrefClear(@"duration");
    KZPrefClear(@"eyePreset");
    KZPrefClear(@"enabled");
    KZPost();
    KZPresetInvalidateCache();
    [self reloadSpecifiers];
}

- (void)applyNow { KZPost(); }

@end