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
// [DEBUG] AirPods 弹窗类型探测 —— 仅记录 presentableType，不拦截。
// 用于区分"连接/开合弹窗"与"低电量弹窗"的真实取值，确认后删除本段。
// 仅在 BluetoothUIService 进程内生效（SpringBoard 无此类，Logos 自动跳过）。
// ============================================================
@interface BluetoothUIServiceBanner : UIViewController
- (NSInteger)presentableType;
- (void)dismissBanner;
@end

%hook BluetoothUIServiceBanner
- (void)viewWillAppear:(BOOL)animated {
    NSInteger t = 0;
    @try { t = (NSInteger)[self presentableType]; } @catch (id e) {}
    NSString *line = [NSString stringWithFormat:@"[AirPodsPopup] presentableType=%ld class=%@\n",
                      (long)t, NSStringFromClass([self class])];
    const char *p = [line UTF8String];
    FILE *f = fopen("/var/jb/tmp/airpods_popup_types.log", "a");
    if (f) { fputs(p, f); fclose(f); }
    %orig;
}
%end

// ============================================================
// %ctor
// ============================================================

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
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
}
