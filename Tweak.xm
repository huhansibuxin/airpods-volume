#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

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

@interface SBSoundDefaults : NSObject
+ (id)standardDefaults;
- (BOOL)isRingerMuted;
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

// 静音开关状态（SBSoundDefaults 域，iOS16 实机验证返回值随开关实时翻转）
// 摘下耳机"强制 100"的通知音必须跳过静音模式：静音时不允许把 Ringtone/Alert 拉回 100
static BOOL isRingerMuted(void) {
    @try {
        Class cls = NSClassFromString(@"SBSoundDefaults");
        if (!cls) return NO;
        id sbsd = [cls standardDefaults];
        if (!sbsd) return NO;
        if (![sbsd respondsToSelector:@selector(isRingerMuted)]) return NO;
        return (BOOL)[sbsd isRingerMuted];
    } @catch (id e) {
        return NO;
    }
}

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
    if (!sAirPodsConnected && isNotificationCategory(cat) && !isRingerMuted())
        vol = 1.0f;
    else if (cap < 1.0f)
        vol = MIN(vol, cap);
    return %orig(vol, cat);
}
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)cat {
    if (!sAirPodsConnected && isNotificationCategory(cat) && !isRingerMuted())
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
        if (!sAirPodsConnected && isNotificationCategory(cat) && !isRingerMuted())
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
// iOS16 上 NCNotificationDispatcher.postNotificationWithRequest:
// 不是唯一入口：自动化通知常被系统合并/更新，走
// modifyNotificationWithRequest:（见 b04019a 实证），只 hook post
// 会漏拦。且 Logos %hook 在 SpringBoard 启动早期类未加载时会
// 静默失败（respring 偶发失效），故改在 %ctor 内先 dlopen
// 强制加载 UserNotificationsKit，再 NSClassFromString realize 类、
// respondsToSelector 防御后 MSHookMessageEx 挂 post + modify 双路径。
// 返回类型按 dump 签名用 id：- (id)postNotificationWithRequest: / modifyNotificationWithRequest:
// ============================================================

static BOOL isShortcutsRequest(id req) {
    if (!req) return NO;
    NSString *sid = [req sectionIdentifier];
    return sid != nil && [sid isEqualToString:@"com.apple.shortcuts"];
}

static id (*origDispatcherPost)(id, SEL, id) = NULL;
static id (*origDispatcherModify)(id, SEL, id) = NULL;

static id replDispatcherPost(id self, SEL _cmd, id req) {
    if (isShortcutsRequest(req)) return nil;
    if (origDispatcherPost) return origDispatcherPost(self, _cmd, req);
    return nil;
}

static id replDispatcherModify(id self, SEL _cmd, id req) {
    if (isShortcutsRequest(req)) return nil;
    if (origDispatcherModify) return origDispatcherModify(self, _cmd, req);
    return nil;
}

// ============================================================
// Block AirPods open-case / connect popup (bottom transient overlay)
// 开盒/连接弹窗 = SharingViewService 的 HeadphoneFlow 远程内容，
// 经 SBRemoteTransientOverlaySessionManager 呈现（iOS16 实机 Frida 实证：
// serviceName=com.apple.SharingViewService
// vcClass=SharingViewService.HeadphoneFlowViewController）。
// 在该决策方法返回 NO 即拒绝呈现，弹窗不出现（已验证生效）。
// 不拦截 shouldActivateWithContext:，单点决策足够。
// ============================================================

@interface SBRemoteTransientOverlaySession : NSObject
- (id)definition;
@end

@interface SBSRemoteAlertDefinition : NSObject
- (NSString *)serviceName;
- (NSString *)viewControllerClassName;
@end

static BOOL (*origPerformPresentationRequest)(id, SEL, id, id) = NULL;

static BOOL replPerformPresentationRequest(id self, SEL _cmd, id session, id request) {
    @try {
        id def = [session definition];
        NSString *svc = [def serviceName];
        NSString *vc = [def viewControllerClassName];
        if (svc && vc &&
            [svc isEqualToString:@"com.apple.SharingViewService"] &&
            [vc isEqualToString:@"SharingViewService.HeadphoneFlowViewController"]) {
            return NO; // 拦截 AirPods 开盒/连接弹窗
        }
    } @catch (id e) {}
    if (origPerformPresentationRequest)
        return origPerformPresentationRequest(self, _cmd, session, request);
    return YES;
}

// ============================================================
// AirPods 路由强制：戴上即切 + 防车载抢路由
// MRAVOutputContext.setOutputDevices: 是控制中心"音频输出"的底层 API
//（iOS16 实机验证：sharedSystemAudioContext 可用，outputDevices 返回
//  当前输出，AirPods Pro uid=MAC-tacl；BluetoothManager connectedDevices
//  返回所有已连接蓝牙设备，可判断 AirPods 是否在场）。
// 戴上 AirPods 时缓存其 MRAVOutputDevice 对象；输出被切走（如车载激活）
// 而 AirPods 仍在蓝牙连接时，用缓存对象强制切回（2s 冷却防反复抢占打架）。
// ============================================================

@interface MRAVOutputDevice : NSObject
- (NSString *)name;
- (NSString *)uid;
@end

@interface MRAVOutputContext : NSObject
+ (id)sharedSystemAudioContext;
- (NSArray *)outputDevices;
- (void)setOutputDevices:(NSArray *)devices withPassword:(NSString *)pwd
     withCallbackQueue:(dispatch_queue_t)q block:(void (^)(BOOL, NSError *))block;
@end

@interface BluetoothDevice : NSObject
- (NSString *)name;
@end

@interface BluetoothManager : NSObject
+ (id)sharedInstance;
- (NSArray *)connectedDevices;
@end

static id sAirPodsOutputDevice = nil;      // 缓存的 AirPods 输出设备对象
static NSTimeInterval sLastRouteForce = 0; // 强制切换冷却时间戳

static BOOL isAirPodsName(NSString *name) {
    return name && [name containsString:@"AirPods"];
}

// AirPods 是否仍在已连接蓝牙设备列表（防抢判断用，车载连上时列表同时含 AirPods+车载）
static BOOL airPodsInBluetoothDevices(void) {
    @try {
        id bm = [NSClassFromString(@"BluetoothManager") sharedInstance];
        NSArray *devs = [bm connectedDevices];
        for (id d in devs) {
            if (isAirPodsName([d name])) return YES;
        }
    } @catch (id e) {}
    return NO;
}

// 缓存当前输出中的 AirPods 设备对象
static void cacheAirPodsDeviceIfPresent(void) {
    @try {
        id ctx = [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext];
        NSArray *devs = [ctx outputDevices];
        for (id d in devs) {
            if (isAirPodsName([d name])) { sAirPodsOutputDevice = d; return; }
        }
    } @catch (id e) {}
}

// 当前输出路由是否全部为 AirPods
static BOOL currentOutputIsAirPods(void) {
    @try {
        id ctx = [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext];
        NSArray *devs = [ctx outputDevices];
        if (!devs || devs.count == 0) return NO;
        for (id d in devs) {
            if (!isAirPodsName([d name])) return NO;
        }
        return YES;
    } @catch (id e) {}
    return NO;
}

// 路由事件日志（写文件，oslog 捕获不到注入 dylib 的 NSLog）
static void routeLog(NSString *msg) {
    FILE *f = fopen("/var/jb/tmp/airpods_route.log", "a");
    if (f) {
        fprintf(f, "[%s] %s\n", [[[NSDate date] description] UTF8String], [msg UTF8String]);
        fclose(f);
    }
}

// 强制切到 AirPods（2s 冷却防与车载反复抢占）
// 注意：block 会在 MediaRemote XPC 异步回调里执行，绝不能捕获任何 ObjC 对象
// （NSString 等），否则 use-after-free 崩（实测 EXC_BAD_ACCESS objc_storeStrong）。
// why 用 const char*（C 字符串，不参与 ARC 管理）。
static void forceRouteToAirPods(const char *why) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastRouteForce < 2.0) return;
    if (!sAirPodsOutputDevice) cacheAirPodsDeviceIfPresent();
    id dev = sAirPodsOutputDevice;
    if (!dev) return;
    @try {
        id ctx = [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext];
        if (!ctx) return;
        sLastRouteForce = now;
        [ctx setOutputDevices:@[dev] withPassword:nil
            withCallbackQueue:dispatch_get_main_queue() block:^(BOOL ok, NSError *err) {
            (void)err;
            routeLog([NSString stringWithFormat:@"force(%s) ok=%d", why ? why : "?", ok]);
        }];
        routeLog([NSString stringWithFormat:@"force(%s) triggered uid=%@", why ? why : "?", [dev uid]]);
    } @catch (id e) {
        routeLog([NSString stringWithFormat:@"force(%s) EXC %@", why ? why : "?", e]);
    }
}

// ============================================================
// %ctor
// ============================================================

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.springboard"]) return;

    updateAirPodsCache();
    cacheAirPodsDeviceIfPresent(); // 启动时若已连 AirPods 先缓存输出设备对象

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    if (!sAirPodsConnected && !isRingerMuted()) {
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
            // 摘下耳机：恢复通知音 100%，但静音模式下不允许强制（保持静音状态）
            if (!isRingerMuted()) {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
        }

        // AirPods 路由强制：戴上即切 + 防车载抢路由
        cacheAirPodsDeviceIfPresent();
        if (airPodsInBluetoothDevices()) {
            // AirPods 在场：戴上时主动切（解决"偶尔不自动切"）；输出被切走时切回（防抢）
            BOOL newlyAttached = (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable);
            if (newlyAttached || !currentOutputIsAirPods()) {
                const char *why = newlyAttached ? "attached" : "stolen";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    forceRouteToAirPods(why);
                });
            }
        }
    }];

    // 快捷指令通知拦截：强制加载框架 + realize 类后挂 post/modify 双路径
    dlopen("/System/Library/PrivateFrameworks/UserNotificationsKit.framework/UserNotificationsKit", RTLD_NOW);
    Class ncdCls = NSClassFromString(@"NCNotificationDispatcher");
    if (ncdCls) {
        if ([ncdCls instancesRespondToSelector:@selector(postNotificationWithRequest:)])
            MSHookMessageEx(ncdCls, @selector(postNotificationWithRequest:),
                            (IMP)replDispatcherPost, (IMP *)&origDispatcherPost);
        if ([ncdCls instancesRespondToSelector:@selector(modifyNotificationWithRequest:)])
            MSHookMessageEx(ncdCls, @selector(modifyNotificationWithRequest:),
                            (IMP)replDispatcherModify, (IMP *)&origDispatcherModify);
    }

    // AirPods 开盒/连接弹窗拦截：远程 overlay 决策点返回 NO
    Class rtoCls = NSClassFromString(@"SBRemoteTransientOverlaySessionManager");
    if (rtoCls) {
        SEL selPP = @selector(remoteTransientOverlaySession:performPresentationRequest:);
        if ([rtoCls instancesRespondToSelector:selPP])
            MSHookMessageEx(rtoCls, selPP,
                            (IMP)replPerformPresentationRequest, (IMP *)&origPerformPresentationRequest);
    }
}
