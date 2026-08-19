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

static BOOL sAirPodsConnected = NO;

// ============================================================
// AirPods 在场判断（BluetoothManager 已连接设备列表）
// sAirPodsConnected 语义 = "AirPods 在场"（不是"有蓝牙设备"）：
// 车载单独连接不触发音量限制；摘下 AirPods（车载仍在）也能正确恢复音量。
// ============================================================

@interface BluetoothDevice : NSObject
- (NSString *)name;
@end

@interface BluetoothManager : NSObject
+ (id)sharedInstance;
- (NSArray *)connectedDevices;
@end

static BOOL isAirPodsName(NSString *name) {
    return name && [name containsString:@"AirPods"];
}

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

// 实时音频路由检测 AirPods 在场（不依赖输出路由）：
// AirPods 连接即有 HFP 输入（availableInputs），戴上瞬间即可检测到，
// 比 BluetoothManager connectedDevices（蓝牙列表更新滞后）更实时——
// 否则戴上时误判"不在场"：attached 不触发（不切）+ 误走恢复分支。
static BOOL airPodsInCurrentRoute(void) {
    @try {
        AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
        for (AVAudioSessionPortDescription *p in route.outputs) {
            if (isAirPodsName(p.portName)) return YES;
        }
        for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
            if (isAirPodsName(p.portName)) return YES;
        }
    } @catch (id e) {}
    return NO;
}

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

static float sLastUncappedMediaVol = -1.0f; // 戴上时 cap 判断用（不用于摘下恢复——系统自动恢复设备记忆音量）

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
// 改用 AVOutputContext（AVFoundation 公开 API）：
// MRAVOutputContext.setOutputDevices: 的 block 在 MediaRemote XPC
// 回复回调里执行，SpringBoard 进程直接调必崩（实测 EXC_BAD_ACCESS
// objc_storeStrong，两次确认）；AVOutputContext 的
// setOutputDevice:options:completionHandler: 是同进程标准回调，安全。
// BluetoothManager connectedDevices 判断 AirPods 是否在场（不依赖当前路由）。
// 戴上时缓存 AVOutputDevice 对象；输出被切走（如车载激活）而 AirPods
// 仍在蓝牙连接时，用缓存对象强制切回（2s 冷却防反复抢占打架）。
// ============================================================

@interface AVOutputDevice : NSObject
- (NSString *)name;
- (NSString *)logicalDeviceID;
@end

@interface AVOutputContext : NSObject
+ (id)sharedSystemAudioContext;
- (NSArray *)outputDevices;
- (void)setOutputDevice:(id)device options:(NSUInteger)options
      completionHandler:(void (^)(NSError *))handler;
@end

static id sAirPodsOutputDevice = nil;      // 缓存的 AirPods 输出设备对象
static NSTimeInterval sLastRouteForce = 0; // 强制切换冷却（3s 逃生通道；戴上时重置）
static BOOL sPrevAirInBT = NO; // 上次蓝牙列表是否含 AirPods（戴上 0→1 重置冷却）

// 缓存当前输出中的 AirPods 设备对象（AVOutputContext）
static void cacheAirPodsDeviceIfPresent(void) {
    @try {
        id ctx = [NSClassFromString(@"AVOutputContext") sharedSystemAudioContext];
        NSArray *devs = [ctx outputDevices];
        for (id d in devs) {
            if (isAirPodsName([d name])) { sAirPodsOutputDevice = d; return; }
        }
    } @catch (id e) {}
}

// 当前输出路由是否全部为 AirPods
static BOOL currentOutputIsAirPods(void) {
    @try {
        id ctx = [NSClassFromString(@"AVOutputContext") sharedSystemAudioContext];
        NSArray *devs = [ctx outputDevices];
        if (!devs || devs.count == 0) return NO;
        for (id d in devs) {
            if (!isAirPodsName([d name])) return NO;
        }
        return YES;
    } @catch (id e) {}
    return NO;
}

// 路由事件日志（生产版已禁用：不写文件，避免 IO 与日志膨胀；
// 需要排查时把本函数体恢复即可）
static void routeLog(NSString *msg) {
    (void)msg;
}

// 强制切到 AirPods
// 冷却策略（重要）：只有 stolen（防抢/逃生通道）走 3s 冷却——
// 想用车载时 3s 内连点车载 2 次，第二次在冷却期内不会被拉回；
// attached（戴上即切）【不走冷却】：戴上必须切，否则"戴上不自动切"失效。
// AVOutputContext 回调同进程，标准 block 语义；保守起见 completionHandler
// 内不捕获外部 ObjC 对象，why 用 const char*。
static void forceRouteToAirPods(const char *why) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 统一 3s 冷却 = 逃生通道：3s 内连点喇叭/车载 2 次，第二次不被抢回。
    // 戴上必切不受影响：蓝牙 0→1 时 enforceAirPodsRoute 会重置 sLastRouteForce。
    if (now - sLastRouteForce < 3.0) return;
    sLastRouteForce = now;
    // 幂等去重：输出已是 AirPods 就不再切（多通知源叠加时避免重复）
    if (currentOutputIsAirPods()) return;
    if (!sAirPodsOutputDevice) cacheAirPodsDeviceIfPresent();
    id dev = sAirPodsOutputDevice;
    if (!dev) return;
    @try {
        id ctx = [NSClassFromString(@"AVOutputContext") sharedSystemAudioContext];
        if (!ctx) return;
        sLastRouteForce = now;
        [ctx setOutputDevice:dev options:0 completionHandler:^(NSError *err) {
            (void)err;
            routeLog([NSString stringWithFormat:@"av-force(%s) done", why ? why : "?"]);
        }];
        routeLog([NSString stringWithFormat:@"av-force(%s) triggered id=%@", why ? why : "?", [dev logicalDeviceID]]);
    } @catch (id e) {
        routeLog([NSString stringWithFormat:@"av-force(%s) EXC %@", why ? why : "?", e]);
    }
}

// ============================================================
// 统一路由事件处理器
// 触发源：
//  1) AVAudioSessionRouteChangeNotification（播放中切换音频路由时触发）
//  2) AVOutputContextOutputDevicesDidChangeNotification（输出设备列表变化，
//     控制中心切喇叭/切耳机、设备加入都触发，不依赖播放会话）
//  3) 1.5s 轮询兜底（系统不切输出时设备列表无变化、通知可能不触发——
//     戴上必切不能依赖通知）
// 在场 = 实时路由(availableInputs) || 蓝牙列表。
// attached/stolen 用"输出状态跳变"判定：上次输出是 AirPods（被切走）→
// stolen（3s 冷却逃生）；上次输出非 AirPods（戴上/刚连）→ attached（免冷却必切）。
// ============================================================

static BOOL sOutputWasAirPods = NO; // 上次检查时输出是否 AirPods（判定 attached/stolen）
static NSTimeInterval sLastReactivate = 0; // 会话重激活防抖（5s 内一次）

// 间接强制：重激活音频会话触发系统重新路由。
// 仅当拿不到 AirPods 设备对象（缓存为空，如 respring 后首次戴上且系统没切，
// AVOutputContext 只有当前输出）时兜底——系统重新路由时蓝牙连接中的 AirPods
// 会被优先选中。5s 防抖防反复打断。
static void reactivateAudioSession(const char *why) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastReactivate < 5.0) return;
    sLastReactivate = now;
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setActive:NO withOptions:0 error:nil];
        [s setActive:YES withOptions:0 error:nil];
        routeLog([NSString stringWithFormat:@"reactivate(%s) triggered", why ? why : "?"]);
    } @catch (id e) {
        routeLog([NSString stringWithFormat:@"reactivate(%s) EXC %@", why ? why : "?", e]);
    }
}

// 路由强制核心：AirPods 在场且输出非 AirPods → 切回（事件与轮询共用）。
// "不管系统切不切都保证切"：输出刚变成 AirPods（系统切的）时，我们也主动
// attached 切一次（幂等无害）——确保切换由我们执行而非依赖系统。
static void enforceAirPodsRoute(void) {
    @try {
        BOOL airInRoute = airPodsInCurrentRoute();
        BOOL airInBT = airPodsInBluetoothDevices();
        // 戴上（蓝牙 0→1）：重置 3s 逃生冷却，保证"戴上必切"不被连点冷却挡住
        if (airInBT && !sPrevAirInBT)
            sLastRouteForce = 0;
        sPrevAirInBT = airInBT;
        sAirPodsConnected = airInRoute || airInBT;
        if (!sAirPodsConnected) {
            sOutputWasAirPods = NO; // 不在场，重置状态
            return;
        }
        cacheAirPodsDeviceIfPresent();
        BOOL outIsAP = currentOutputIsAirPods();
        BOOL wasAP = sOutputWasAirPods;
        sOutputWasAirPods = outIsAP;
        if (outIsAP) {
            // 输出已是 AirPods（系统切的）：仅当刚变成时我们也 attached 切一次（幂等）
            if (!wasAP) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    forceRouteToAirPods("attached");
                });
            }
        } else {
            // 输出非 AirPods：上次输出是 AirPods（被切走）→ stolen（3s 冷却）；
            // 上次输出非 AirPods（戴上/刚连）→ attached（免冷却必切）
            const char *why = wasAP ? "stolen" : "attached";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                forceRouteToAirPods(why);
            });
            // 缓存为空（拿不到设备对象，respring 后首次/系统没切）→ 间接强制：
            // 重激活会话让系统重新路由到 AirPods（有缓存对象时不触发，不影响正常抢回）
            if (!sAirPodsOutputDevice) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    reactivateAudioSession(why);
                });
            }
        }
    } @catch (id e) {}
}

static int sLastEvtState = -1; // 日志限流：AirPods 在场状态 0/1，变化才写日志

static void handleRouteEvent(NSString *source) {
    @try {
        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        BOOL airInRoute = airPodsInCurrentRoute();
        BOOL airInBT = airPodsInBluetoothDevices();
        sAirPodsConnected = airInRoute || airInBT;
        // 日志限流：outputdev 通知戴上时高频触发（每秒多次），状态未变化不刷日志
        int state = sAirPodsConnected ? 1 : 0;
        if (state != sLastEvtState) {
            sLastEvtState = state;
            routeLog([NSString stringWithFormat:@"evt(%@) airInRoute=%d airInBT=%d conn=%d",
                      source, airInRoute, airInBT, sAirPodsConnected]);
        }
        if (sAirPodsConnected) {
            float cur;
            if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
            if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                [avc setVolumeTo:0.4f forCategory:@"Alert"];
            [avc getVolume:&cur forCategory:@"Audio/Video"]; // prime（仅用于 cap 判断）
            if (sLastUncappedMediaVol > 0.7f)
                [avc setVolumeTo:0.7f forCategory:@"Audio/Video"];
        } else {
            // 摘下 AirPods（不管车载是否还在）：恢复通知音 100%，静音模式下不强制
            if (!isRingerMuted()) {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
            // 摘下媒体音量：不碰——iOS 为每个输出设备独立记忆音量，
            // 输出切回喇叭时系统自动恢复喇叭记忆音量（老板实测手动点喇叭
            // 会自动回到戴前值 93）。之前主动 setVolumeTo 反而覆盖了系统恢复。
            // sLastUncappedMediaVol 保留用于戴上时的 cap 判断（不用于恢复）。
        }
        enforceAirPodsRoute();
    } @catch (id e) {
        routeLog([NSString stringWithFormat:@"evt(%@) EXC %@", source, e]);
    }
}
%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.springboard"]) return;

    routeLog(@"ctor running"); // 启动标记：确认 %ctor 执行 + routeLog 写入是否正常
    sAirPodsConnected = airPodsInBluetoothDevices(); // 启动时初始化"AirPods 在场"
    cacheAirPodsDeviceIfPresent(); // 启动时若已连 AirPods 先缓存输出设备对象

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    if (!sAirPodsConnected && !isRingerMuted()) {
        [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
        [avc setVolumeTo:1.0f forCategory:@"Alert"];
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        handleRouteEvent(@"avroute");
    }];

    // 输出设备列表变化（控制中心切喇叭/切耳机、设备加入都触发，不依赖播放会话）
    [[NSNotificationCenter defaultCenter] addObserverForName:@"AVOutputContextOutputDevicesDidChangeNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        handleRouteEvent(@"outputdev");
    }];

    // 1.5s 轮询兜底：保证"戴上必切"（系统不切输出时设备列表无变化、通知不触发）。
    // 动态启停：初始暂停（没连 AirPods 完全不轮询、省电）；
    // AirPods 蓝牙连接成功通知 → 启动；断开通知 → 停止。
    __block BOOL sTimerRunning = NO;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
                              1.5 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        enforceAirPodsRoute();
    });
    dispatch_suspend(timer); // 初始不轮询（省电），等 AirPods 连接通知启动

    // AirPods 蓝牙连接成功（开盒即连接，此时还没戴上）→ 启动轮询 + 立即强制路由
    [[NSNotificationCenter defaultCenter] addObserverForName:@"BluetoothDeviceConnectSuccessNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (airPodsInBluetoothDevices()) {
            if (!sTimerRunning) { dispatch_resume(timer); sTimerRunning = YES; }
            handleRouteEvent(@"btconnect");
        }
    }];
    // AirPods 蓝牙断开 → 停止轮询
    [[NSNotificationCenter defaultCenter] addObserverForName:@"BluetoothDeviceDisconnectSuccessNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (sTimerRunning) { dispatch_suspend(timer); sTimerRunning = NO; }
        handleRouteEvent(@"btdisconnect");
    }];

    // 启动时若已连 AirPods（如 respring 后仍连着）：启动轮询 + 初始强制切
    if (sAirPodsConnected) {
        if (!sTimerRunning) { dispatch_resume(timer); sTimerRunning = YES; }
        handleRouteEvent(@"ctor-init");
    }

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
