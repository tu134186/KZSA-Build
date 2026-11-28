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

static NSArray<NSString *> *KZCustomList(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)@"eyeCustoms", (__bridge CFStringRef)KZ_DOMAIN);
    id obj = v ? (__bridge_transfer id)v : nil;
    if ([obj isKindOfClass:[NSArray class]]) return obj;
    return @[];
}

static UIImage *KZImageFromB64(NSString *b64) {
    if (b64.length < 200) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return d.length > 200 ? [UIImage imageWithData:d] : nil;
}

static NSArray<UIImage *> *KZPresetImages(void) {
    if (_kzPresetCache) return _kzPresetCache;
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < kKZPresetCount; i++) {
        UIImage *u = KZPBase64(kKZPresetB64[i]);
        [a addObject:u ?: [UIImage new]];
    }
    for (NSString *b64 in KZCustomList()) {
        UIImage *u = KZImageFromB64(b64);
        if (u) [a addObject:u];
    }
    _kzPresetCache = a;
    return a;
}

static NSArray<NSString *> *KZPresetNames(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < kKZPresetCount; i++) [a addObject:[NSString stringWithUTF8String:kKZPresetNames[i]]];
    NSInteger n = (NSInteger)KZCustomList().count;
    for (NSInteger i = 0; i < n; i++) [a addObject:[NSString stringWithFormat:@"自定%ld", (long)(i + 1)]];
    return a;
}


static BOOL gPresetEditMode = NO;

@interface KZPresetCell : PSTableCell
@end

@implementation KZPresetCell {
    NSMutableArray<UIControl *> *_wraps;
    NSMutableArray<UIButton *> *_btns;
    NSMutableArray<UILabel *> *_badges;
    NSMutableArray<UILabel *> *_labels;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _wraps = [NSMutableArray array];
        _btns = [NSMutableArray array];
        _badges = [NSMutableArray array];
        _labels = [NSMutableArray array];

        NSArray<UIImage *> *imgs = KZPresetImages();
        NSArray<NSString *> *names = KZPresetNames();
        for (NSInteger i = 0; i < imgs.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = i;
            b.layer.cornerRadius = 20;
            b.layer.masksToBounds = YES;
            b.backgroundColor = [UIColor blackColor];
            b.imageView.contentMode = UIViewContentModeScaleAspectFill;
            [b setImage:imgs[i] forState:UIControlStateNormal];
            b.userInteractionEnabled = NO;

            UILabel *lb = [[UILabel alloc] init];
            lb.text = names[i];
            lb.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
            lb.textColor = [UIColor secondaryLabelColor];
            lb.textAlignment = NSTextAlignmentCenter;
            [b addSubview:lb];

            // 红色减号徽标（编辑模式显示，只给自定义素材）
            UILabel *badge = [[UILabel alloc] init];
            badge.text = @"−";
            badge.textColor = [UIColor whiteColor];
            badge.backgroundColor = [UIColor systemRedColor];
            badge.font = [UIFont boldSystemFontOfSize:13];
            badge.textAlignment = NSTextAlignmentCenter;
            badge.layer.cornerRadius = 9;
            badge.layer.masksToBounds = YES;
            badge.userInteractionEnabled = NO;
            badge.hidden = YES;

            UIControl *wrap = [[UIControl alloc] init];
            wrap.tag = i;
            [wrap addSubview:b];
            [wrap addSubview:badge];
            [wrap addTarget:self action:@selector(tapWrap:) forControlEvents:UIControlEventTouchUpInside];
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
            [wrap addGestureRecognizer:lp];

            [self.contentView addSubview:wrap];
            [_wraps addObject:wrap];
            [_btns addObject:b];
            [_badges addObject:badge];
            [_labels addObject:lb];
        }
        [self refreshCellContentsWithSpecifier:specifier];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_btns.count) return;
    NSInteger cur = (NSInteger)round([KZPrefStr(@"eyePreset") doubleValue]);
    NSInteger total = (NSInteger)_btns.count;
    for (NSInteger i = 0; i < total; i++) {
        UIButton *b = _btns[i];
        BOOL sel = (i == cur);
        b.layer.borderWidth = sel ? 2.5 : 0.0;
        b.layer.borderColor = sel ? [UIColor systemBlueColor].CGColor : [UIColor clearColor].CGColor;
        b.alpha = sel ? 1.0 : 0.85;

        BOOL isCustom = (i >= kKZPresetCount);
        UILabel *badge = _badges[i];
        UIControl *wrap = _wraps[i];
        if (gPresetEditMode && isCustom) {
            badge.hidden = NO;
            wrap.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.001];   // 保证可点击
        } else {
            badge.hidden = YES;
        }
    }
}

- (UIViewController *)hostVC {
    UIResponder *r = self;
    NSInteger guard = 0;
    while (r && guard++ < 24) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (KZCustomList().count == 0) return;
    gPresetEditMode = !gPresetEditMode;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"KZPresetEditChanged" object:nil];
}

- (void)tapWrap:(UIControl *)w {
    NSInteger idx = w.tag;
    if (gPresetEditMode && idx >= kKZPresetCount) {
        // 编辑模式下点的是自定义素材 → 删除
        NSArray *list = KZCustomList();
        NSInteger ci = idx - kKZPresetCount;
        if (ci >= 0 && ci < (NSInteger)list.count) {
            NSMutableArray *m = [list mutableCopy];
            [m removeObjectAtIndex:ci];
            KZPrefSet(@"eyeCustoms", m);
            NSInteger cur = (NSInteger)round([KZPrefStr(@"eyePreset") doubleValue]);
            if (cur >= kKZPresetCount + (NSInteger)m.count) KZPrefSet(@"eyePreset", @(0));
            KZPost();
            KZPresetInvalidateCache();
            gPresetEditMode = NO;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"KZPresetEditChanged" object:nil];
            return;
        }
        return;
    }
    if (idx >= (NSInteger)_btns.count) return;
    KZPrefSet(@"eyePreset", @(idx));
    KZPost();
    NSInteger total = (NSInteger)_btns.count;
    for (NSInteger i = 0; i < total; i++) {
        UIButton *b = _btns[i];
        BOOL sel = (i == idx);
        b.layer.borderWidth = sel ? 2.5 : 0.0;
        b.layer.borderColor = sel ? [UIColor systemBlueColor].CGColor : [UIColor clearColor].CGColor;
        b.alpha = sel ? 1.0 : 0.85;
    }
}

- (void)setHighlighted:(BOOL)h animated:(BOOL)a { [super setHighlighted:NO animated:NO]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    CGRect b = self.contentView.bounds;
    CGFloat pad = 10;
    CGFloat cols = 5;
    CGFloat avail = b.size.width - pad * 2;
    CGFloat gap = 6;
    CGFloat cellW = (avail - gap * (cols - 1)) / cols;
    CGFloat thumb = MIN(40.0, cellW);

    for (NSInteger i = 0; i < (NSInteger)_wraps.count; i++) {
        UIControl *wrap = _wraps[i];
        UIButton *btn = _btns[i];
        UILabel *badge = _badges[i];
        UILabel *lb = _labels[i];
        NSInteger row = i / (NSInteger)cols;
        NSInteger col = i % (NSInteger)cols;
        CGFloat x = pad + col * (cellW + gap);
        CGFloat y = 4 + row * 62;
        wrap.frame = CGRectMake(x, y, cellW, 58);
        btn.frame = CGRectMake((cellW - thumb) / 2.0, 0, thumb, thumb);
        badge.frame = CGRectMake(btn.frame.origin.x, 0, 18, 18);
        lb.frame = CGRectMake(-4, thumb + 2, cellW + 8, 12);
    }
}

@end

#pragma mark - 素材子页面（把 8 套收纳进来）

@interface KZPresetListController : PSListController
@end

@implementation KZPresetListController

- (id)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *arr = [NSMutableArray array];
        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"点一下立即替换"];
        [arr addObject:g];

        PSSpecifier *pick = [PSSpecifier preferenceSpecifierNamed:@"素材"
                                                           target:self
                                                              set:nil
                                                              get:nil
                                                           detail:nil
                                                             cell:PSStaticTextCell
                                                             edit:nil];
        Class pc = NSClassFromString(@"KZPresetCell");
        [pick setProperty:pc forKey:@"cellClass"];
        if ([pick respondsToSelector:@selector(setCellClass:)]) [pick setCellClass:pc];
        [pick setProperty:@(132.0) forKey:@"height"];
        [pick setProperty:@YES forKey:@"presetPicker"];
        [arr addObject:pick];

        PSSpecifier *imp = [PSSpecifier preferenceSpecifierNamed:@"导入素材"
                                                          target:self set:nil get:nil detail:nil
                                                            cell:PSButtonCell edit:nil];
        [imp setButtonAction:@selector(importPhoto)];
        [arr addObject:imp];

        PSSpecifier *del = [PSSpecifier preferenceSpecifierNamed:@"删除素材"
                                                          target:self set:nil get:nil detail:nil
                                                            cell:PSButtonCell edit:nil];
        [del setButtonAction:@selector(deleteCustom)];
        [arr addObject:del];

        PSSpecifier *note = [PSSpecifier groupSpecifierWithName:nil];
        [note setProperty:@"点一下就换；长按素材进入编辑模式，点红色 − 可逐个删除自定义素材。" forKey:@"footerText"];
        [arr addObject:note];

        _specifiers = arr;
    }
    return _specifiers;
}

- (void)forwardTo:(NSString *)sel {
    SEL s = NSSelectorFromString(sel);
    // 1) 同一导航栈里的 KZRootListController（responder 链到不了"兄弟" VC）
    if ([self isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)self;
        for (UIViewController *c in vc.navigationController.viewControllers) {
            if ([NSStringFromClass(c.class) isEqualToString:@"KZRootListController"] &&
                [c respondsToSelector:s]) {
                ((void (*)(id, SEL))objc_msgSend)(c, s);
                return;
            }
        }
    }
    // 2) 兜底：responder 链（必须跳过自己，否则自己调自己 → 无限递归崩溃）
    UIResponder *r = self.nextResponder;
    NSInteger guard = 0;
    while (r && guard++ < 24) {
        if ([r respondsToSelector:s] && r != self) {
            ((void (*)(id, SEL))objc_msgSend)(r, s);
            return;
        }
        r = r.nextResponder;
    }
}

- (void)importPhoto { [self forwardTo:@"importPhoto"]; }
- (void)deleteCustom { [self forwardTo:@"deleteCustom"]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    KZPresetInvalidateCache();
    [self reloadSpecifiers];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onEditChanged)
                                                 name:@"KZPresetEditChanged"
                                               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"KZPresetEditChanged" object:nil];
}

- (void)onEditChanged {
    for (UITableViewCell *c in [self.tableView visibleCells]) {
        if ([c isKindOfClass:[KZPresetCell class]]) {
            [(KZPresetCell *)c refreshCellContentsWithSpecifier:nil];
        }
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

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
        NSMutableArray *list = [KZCustomList() mutableCopy];
        if (list.count >= 8) [list removeObjectAtIndex:0];
        [list addObject:[use base64EncodedStringWithOptions:0]];
        KZPrefSet(@"eyeCustoms", list);
        KZPrefSet(@"eyePreset", @(kKZPresetCount + (NSInteger)list.count - 1));   // 切到刚导入的
        KZPost();
        KZPresetInvalidateCache();
        [self reloadSpecifiers];
    } @catch (NSException *e) {
        // 静默失败，不让设置进程崩
    }
}

- (void)pickFromPhotos {
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)pickFromFiles {
    NSMutableArray *types = [NSMutableArray array];
    Class UTTypeCls = NSClassFromString(@"UTType");
    if (UTTypeCls && [UTTypeCls respondsToSelector:@selector(typeWithIdentifier:)]) {
        for (NSString *ident in @[@"public.png", @"public.jpeg", @"public.heic", @"public.image"]) {
            id t = ((id (*)(id, SEL, id))objc_msgSend)(UTTypeCls, @selector(typeWithIdentifier:), ident);
            if (t) [types addObject:t];
        }
    }
    UIDocumentPickerViewController *d;
    if (types.count && [UIDocumentPickerViewController instancesRespondToSelector:@selector(initForOpeningContentTypes:)]) {
        d = ((id (*)(id, SEL, id))objc_msgSend)([UIDocumentPickerViewController alloc], @selector(initForOpeningContentTypes:), types);
    } else {
        d = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.image"] inMode:UIDocumentPickerModeImport];
    }
    d.delegate = self;
    d.allowsMultipleSelection = NO;
    [self presentViewController:d animated:YES completion:nil];
}

- (void)importPhoto {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入素材"
                                                              message:@"选择图片来源"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"从相册选择" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self pickFromPhotos];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"从文件选择（PNG/JPG）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self pickFromFiles];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    BOOL access = [u startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:u];
    UIImage *img = data.length > 100 ? [UIImage imageWithData:data] : nil;
    if (access) [u stopAccessingSecurityScopedResource];
    if (img) [self storeImage:img];
    else [self alert:@"这个文件读不出图片，换一张试试"];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{ [self storeImage:img]; }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)deleteCustom {
    KZPrefClear(@"eyeCustoms");
    NSInteger cur = (NSInteger)round([KZPrefStr(@"eyePreset") doubleValue]);
    if (cur >= kKZPresetCount) KZPrefSet(@"eyePreset", @(0));
    KZPost();
    KZPresetInvalidateCache();
    [self reloadSpecifiers];
}

#pragma mark 其它

- (void)resetAll {
    KZPrefClear(@"eyeCustoms");
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