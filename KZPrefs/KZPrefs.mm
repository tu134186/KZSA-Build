#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)KZ_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)KZ_DOMAIN);
}

static void KZPrefClear(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)KZ_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)KZ_DOMAIN);
}

@interface PSListController (KZ)
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface KZRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@end

@implementation KZRootListController

- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        for (PSSpecifier *s in _specifiers) {
            if ([s propertyForKey:@"action"]) [s setTarget:self];
        }
        [self decorate];
    }
    return _specifiers;
}

- (void)decorate {
    NSString *img = KZPrefStr(@"eyeImage");
    NSString *txt = (img.length > 200) ? @"自定义图片（已导入）" : @"内置写轮眼";
    for (PSSpecifier *s in self.specifiers) {
        if ([[s propertyForKey:@"key"] isEqualToString:@"eyeName"]) {
            [s setName:[NSString stringWithFormat:@"当前素材：%@", txt]];
        }
    }
}

- (void)refreshAll {
    [self decorate];
    [self.tableView reloadData];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    KZPrefSet(key, value);
    notify_post(KZ_NOTIFY);
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
    CGImageRef sq = CGImageCreateWithImageInRect(cg, CGRectMake((double)(w - side) / 2.0,
                                                                (double)(h - side) / 2.0,
                                                                (double)side, (double)side));
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
    notify_post(KZ_NOTIFY);
    [self refreshAll];
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
    UIDocumentPickerViewController *dp =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypePNG, UTTypeImage ]];
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

- (void)resetEye {
    KZPrefClear(@"eyeImage");
    notify_post(KZ_NOTIFY);
    [self refreshAll];
}

- (void)applyNow {
    notify_post(KZ_NOTIFY);
}

@end
