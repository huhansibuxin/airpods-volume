#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
- (BOOL)changeVolumeBy:(float)v forCategory:(id)c;
- (BOOL)getVolume:(float *)v forCategory:(id)c;
@end

@interface NCNotificationRequest : NSObject
- (NSString *)sectionIdentifier;
@end

@interface SBVolumeControl : NSObject
- (BOOL)increaseVolume;
@end

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

static BOOL isBluetoothPort(AVAudioSessionPortDescription *p) {
    NSString *type = p.portType;
    return [type isEqualToString:AVAudioSessionPortBluetoothA2DP]
        || [type isEqualToString:AVAudioSessionPortBluetoothHFP]
        || [type isEqualToString:AVAudioSessionPortBluetoothLE];
}

static BOOL sAirPodsConnected = NO;

static void updateAirPodsCache(void) {
    sAirPodsConnected = NO;
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *p in route.outputs) {
        if (isBluetoothPort(p)) {
            sAirPodsConnected = YES;
            break;
        }
    }
    if (!sAirPodsConnected) {
        for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
            if (isBluetoothPort(p)) {
                sAirPodsConnected = YES;
                break;
            }
        }
    }
}

static float sLastUncappedMediaVol = -1.0f;

static float capForCategory(id cat) {
    if (!sAirPodsConnected) return 1.0f;
    if (isNotificationCategory(cat)) return 0.4f;
    return 0.7f; // media + everything else: cap at 70%
}

// ============================================================
// SBVolumeControl: block hardware volume buttons
// ============================================================

%hook SBVolumeControl
- (BOOL)increaseVolume {
    if (sAirPodsConnected) {
        // read current volume via AVSystemController (any non-ringer cat)
        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        float cur;
        // try media categories that might give us actual media volume
        if ([avc getVolume:&cur forCategory:@"Audio/Video"] ||
            [avc getVolume:&cur forCategory:AVAudioSessionCategoryPlayback]) {
            if (cur >= 0.7f) return NO;
        }
    }
    return %orig;
}
%end

// ============================================================
// AVSystemController: catch CC slider + all volume paths
// ============================================================

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    float cap = capForCategory(cat);
    if (!sAirPodsConnected && isNotificationCategory(cat))
        vol = 1.0f;
    else if (cap < 1.0f)
        vol = MIN(vol, cap);
    return %orig(vol, cat);
}
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)cat {
    if (!sAirPodsConnected && isNotificationCategory(cat))
        return [self setVolumeTo:1.0f forCategory:cat];
    float cap = capForCategory(cat);
    if (cap >= 1.0f) return %orig;
    float cur;
    if ([self getVolume:&cur forCategory:cat] && (cur + delta) > cap) {
        if (cur >= cap) return YES;
        return [self setVolumeTo:cap forCategory:cat];
    }
    return %orig;
}
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig(vol, cat);
    if (r) {
        float cap = capForCategory(cat);
        if (!sAirPodsConnected && isNotificationCategory(cat))
            *vol = 1.0f;
        else if (cap < 1.0f) {
            if (!isNotificationCategory(cat)) sLastUncappedMediaVol = *vol;
            *vol = MIN(*vol, cap);
        }
    }
    return r;
}
%end

// ============================================================
// Disable touch on volume HUD
// ============================================================

%hook SBHUDWindow
- (void)addSubview:(UIView *)view {
    view.userInteractionEnabled = NO;
    %orig;
}
%end

@interface SBElasticVolumeSliderView : UIView
@end
%hook SBElasticVolumeSliderView
- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    self.userInteractionEnabled = NO;
    return self;
}
%end

// ============================================================
// Hide replaykit CC modules
// ============================================================

%hook NSBundle
- (Class)principalClass {
    NSString *bid = [self bundleIdentifier];
    if (bid && [bid hasPrefix:@"com.apple.replaykit."]) {
        if ([bid isEqualToString:@"com.apple.replaykit.AudioConferenceControlCenterModule"] ||
            [bid isEqualToString:@"com.apple.replaykit.VideoConferenceControlCenterModule"]) {
            return nil;
        }
    }
    return %orig;
}
%end

// ============================================================
// Block Shortcuts automation notifications
// 手动 MSHookMessageEx，挂在 %ctor(SpringBoard) 内：先用 NSClassFromString
// 强制 realize 类再挂 hook，规避 Logos %hook 在类未加载时静默失败（respring 偶发失效）；
// 同时拦截 post + modify 两条路径（快捷指令通知常被系统合并/更新，原 hook 漏掉 modify）。
// ============================================================

static BOOL isShortcutsNotification(id req) {
    if (!req) return NO;
    NSString *sid = [req sectionIdentifier];
    return [sid isEqualToString:@"com.apple.shortcuts"];
}

static void (*origPostNotification)(id, SEL, id) = NULL;
static void (*origModifyNotification)(id, SEL, id) = NULL;

static void replPostNotification(id self, SEL _cmd, id req) {
    if (isShortcutsNotification(req)) return;
    if (origPostNotification) origPostNotification(self, _cmd, req);
}

static void replModifyNotification(id self, SEL _cmd, id req) {
    if (isShortcutsNotification(req)) return;
    if (origModifyNotification) origModifyNotification(self, _cmd, req);
}

// ============================================================
// [DEBUG] AirPods 弹窗探测 —— 运行时枚举 SpringBoard 内所有类，
// 找出真正实现 presentable 呈现方法（presentPresentable:withOptions:userInfo:
// / enqueuePresentable:withOptions:userInfo: / addPresentable:）的真实宿主类，
// hook 之并记录 presentable 的 hostClass / presentableClass / presentableType
// / isLowBatteryBanner。不拦截（仅日志）。
// 确认真实类名与取值后，改为精准拦截并只 hook 该类。
// 说明：之前误以为宿主类叫 BKSystemApertureController，但共享缓存里并无此
// 字符串（只有 systemApertureController 这个属性名），故 NSClassFromString
// 返回 nil、hook 全没挂上。改用运行时枚举兜底，不依赖猜测的类名。
// ============================================================

#import <objc/runtime.h>

// 让编译器认识 presentable 上的两个属性选择器（运行时用 @try 兜底，安全）
@interface NSObject (AirPodsPopupPresentable)
- (NSInteger)presentableType;
- (BOOL)isLowBatteryBanner;
@end

// 每个 (类, 选择器) 存一份原始 IMP，支持多类同时 hook
static CFMutableDictionaryRef gOrigBySel = NULL;

static void storeOrig(SEL sel, Class c, IMP imp) {
    if (!gOrigBySel) {
        gOrigBySel = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    CFStringRef key = (__bridge CFStringRef)NSStringFromSelector(sel);
    CFMutableDictionaryRef per = (CFMutableDictionaryRef)CFDictionaryGetValue(gOrigBySel, key);
    if (!per) {
        per = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        CFDictionarySetValue(gOrigBySel, key, per);
        CFRelease(per);
    }
    CFDictionarySetValue(per, (__bridge void *)c, (void *)imp);
}
static IMP fetchOrig(SEL sel, Class c) {
    if (!gOrigBySel) return NULL;
    CFStringRef key = (__bridge CFStringRef)NSStringFromSelector(sel);
    CFDictionaryRef per = (CFDictionaryRef)CFDictionaryGetValue(gOrigBySel, key);
    if (!per) return NULL;
    return (IMP)CFDictionaryGetValue(per, (__bridge void *)c);
}

static void appendLog(NSString *line) {
    const char *p = [line UTF8String];
    FILE *f = fopen("/var/jb/tmp/airpods_popup_types.log", "a");
    if (f) { fputs(p, f); fclose(f); }
}

static void logPresentable(id presentable, NSString *via, NSString *hostClass) {
    if (!presentable) return;
    NSInteger t = 0;
    BOOL low = NO;
    NSString *pcls = NSStringFromClass([presentable class]);
    @try { t = (NSInteger)[presentable presentableType]; } @catch (id e) {}
    @try { low = (BOOL)[presentable isLowBatteryBanner]; } @catch (id e) {}
    appendLog([NSString stringWithFormat:
        @"[AirPodsPopup] %@ host=%@ presentableClass=%@ presentableType=%ld isLowBattery=%d\n",
        via, hostClass, pcls, (long)t, low]);
}

static id replPresentPresentable(id self, SEL _cmd, id p, id o, id u) {
    logPresentable(p, @"presentPresentable", NSStringFromClass([self class]));
    IMP orig = fetchOrig(_cmd, [self class]);
    if (orig) return ((id(*)(id,SEL,id,id,id))orig)(self, _cmd, p, o, u);
    return nil;
}
static id replEnqueuePresentable(id self, SEL _cmd, id p, id o, id u) {
    logPresentable(p, @"enqueuePresentable", NSStringFromClass([self class]));
    IMP orig = fetchOrig(_cmd, [self class]);
    if (orig) return ((id(*)(id,SEL,id,id,id))orig)(self, _cmd, p, o, u);
    return nil;
}
static id replAddPresentable(id self, SEL _cmd, id p) {
    logPresentable(p, @"addPresentable", NSStringFromClass([self class]));
    IMP orig = fetchOrig(_cmd, [self class]);
    if (orig) return ((id(*)(id,SEL,id))orig)(self, _cmd, p);
    return nil;
}

// ============================================================
// %ctor
// ============================================================

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;

    // [DEBUG] 注入确认标记：任何被注入的进程都写一行，用于区分
    // "未注入 BluetoothUIService" 与 "注入了但 hook 未触发"。确认后删除。
    {
        NSString *m = [NSString stringWithFormat:@"[AirPodsPopup] injected bid=%@\n", bid];
        FILE *f = fopen("/var/jb/tmp/airpods_injection.log", "a");
        if (f) { fputs([m UTF8String], f); fclose(f); }
    }

    if (![bid isEqualToString:@"com.apple.springboard"]) return;

    updateAirPodsCache();

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    if (!sAirPodsConnected) {
        [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
        [avc setVolumeTo:1.0f forCategory:@"Alert"];
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        NSInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
        if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
            sAirPodsConnected = NO;
        } else {
            updateAirPodsCache();
        }
        if (sAirPodsConnected) {
            float cur;
            if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
            if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                [avc setVolumeTo:0.4f forCategory:@"Alert"];
            [avc getVolume:&cur forCategory:@"Audio/Video"]; // prime sLastUncappedMediaVol
            if (sLastUncappedMediaVol > 0.7f)
                [avc setVolumeTo:0.7f forCategory:@"Audio/Video"];
        } else {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }
    }];

    // 拦截快捷指令通知：类已强制加载，手动挂 hook（覆盖 post + modify 两条路径）
    Class ncdCls = NSClassFromString(@"NCNotificationDispatcher");
    if (ncdCls) {
        MSHookMessageEx(ncdCls, @selector(postNotificationWithRequest:),
                        (IMP)replPostNotification, (IMP *)&origPostNotification);
        MSHookMessageEx(ncdCls, @selector(modifyNotificationWithRequest:),
                        (IMP)replModifyNotification, (IMP *)&origModifyNotification);
    }

    // [DEBUG] AirPods 弹窗探测：运行时枚举 SpringBoard 内类，hook 真正实现
    // presentable 呈现方法的宿主（不依赖猜测类名，避免 NSClassFromString 落空）
    {
        int n = objc_getClassList(NULL, 0);
        if (n > 0) {
            Class *list = (Class *)malloc(sizeof(Class) * (n + 1));
            if (list) {
                int got = objc_getClassList(list, n);
                for (int i = 0; i < got; i++) {
                    Class c = list[i];
                    NSString *nm = NSStringFromClass(c);
                    if (![nm containsString:@"Aperture"] &&
                        ![nm containsString:@"Banner"] &&
                        ![nm containsString:@"Presentable"] &&
                        ![nm containsString:@"SystemAperture"]) continue;
                    SEL s1 = @selector(presentPresentable:withOptions:userInfo:);
                    SEL s2 = @selector(enqueuePresentable:withOptions:userInfo:);
                    SEL s3 = @selector(addPresentable:);
                    if ([c instancesRespondToSelector:s1]) {
                        IMP o = NULL;
                        MSHookMessageEx(c, s1, (IMP)replPresentPresentable, &o);
                        storeOrig(s1, c, o);
                        appendLog([NSString stringWithFormat:@"[AirPodsPopup] HOOKED %@ -presentPresentable:withOptions:userInfo:\n", nm]);
                    }
                    if ([c instancesRespondToSelector:s2]) {
                        IMP o = NULL;
                        MSHookMessageEx(c, s2, (IMP)replEnqueuePresentable, &o);
                        storeOrig(s2, c, o);
                        appendLog([NSString stringWithFormat:@"[AirPodsPopup] HOOKED %@ -enqueuePresentable:withOptions:userInfo:\n", nm]);
                    }
                    if ([c instancesRespondToSelector:s3]) {
                        IMP o = NULL;
                        MSHookMessageEx(c, s3, (IMP)replAddPresentable, &o);
                        storeOrig(s3, c, o);
                        appendLog([NSString stringWithFormat:@"[AirPodsPopup] HOOKED %@ -addPresentable:\n", nm]);
                    }
                }
                free(list);
            }
        }
    }
}
