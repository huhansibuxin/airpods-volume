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
// 入耳检测状态（iOS16 实机验证）：unsigned char 输出参数，bitmask——
// 0=未戴, 1=左耳, 2=右耳, 3=双耳（frida 实测摘戴实时跳变 0↔3）
- (void)inEarStatusPrimary:(unsigned char *)primary secondary:(unsigned char *)secondary;
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

// （v1.9.21：入耳检测 worn 门控已整体删除——其滞后/假阳性导致
//  开盒未戴不切、摘下抢回；"开盒必切"不依赖入耳检测，在场即切。
//  相关代码：airPodsInEarStatus / sWornCache / handleInEarChange /
//  BluetoothAccessorySettingsChanged 监听均已移除）

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
    // 摘下时通知音强制 100%（静音跳过）；戴上时各类音量按 cap 封顶
    // （媒体 70%/通知 40%——hook 层兜底，控制中心滑动条走 MediaRemote
    // 路径不经此 hook，由 handleRouteEvent 戴上时读当前值主动压兜底）
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
// Block "X 粘贴自 Y" 剪贴板读取提示（iOS 16）
// 社区方案（0xkuj/NoPasteAlerts16，iOS16 验证可用）：
// 剪贴板读取提示 = SBUserNotificationAlert（_alertSource == @"pasted"），
// 经 SBAlertItem +activateAlertItem: 激活展示。拦截：检测到即不激活
// 并清理（_setActivated:NO + _sendResponseAndCleanUp:YES），提示不出现，
// App 读取剪贴板功能不受影响。
// ============================================================

// 前向声明：routeLog 定义在下方路由模块（探针先于其调用）
static void routeLog(NSString *msg);

@interface SBUserNotificationAlert : NSObject
- (void)_setActivated:(BOOL)activated;
- (void)_sendResponseAndCleanUp:(BOOL)cleanup;
@end

static void (*origActivateAlertItem)(id, SEL, id) = NULL;
static void replActivateAlertItem(id self, SEL _cmd, id alertItem) {
    // 探针 A：全量记录（v1.9.30 排查"粘贴自"横幅路径）
    @try {
        NSString *cn = alertItem ? NSStringFromClass([alertItem class]) : @"nil";
        NSString *src = @"?";
        @try { src = [alertItem valueForKey:@"_alertSource"]; } @catch (id e) {}
        BOOL isUNA = alertItem && [alertItem isKindOfClass:NSClassFromString(@"SBUserNotificationAlert")];
        routeLog([NSString stringWithFormat:@"PROBE-A activateAlertItem class=%@ src=%@ isUNA=%d", cn, src, isUNA]);
    } @catch (id e) {}
    if (alertItem && [alertItem isKindOfClass:NSClassFromString(@"SBUserNotificationAlert")]) {
        NSString *source = nil;
        @try { source = [alertItem valueForKey:@"_alertSource"]; } @catch (id e) {}
        if ([source isEqualToString:@"pasted"]) {
            @try {
                [alertItem _setActivated:NO];
                if ([alertItem respondsToSelector:@selector(_sendResponseAndCleanUp:)])
                    [alertItem _sendResponseAndCleanUp:YES];
                routeLog(@"PROBE-A BLOCKED pasted alert");
            } @catch (id e) {}
            return; // 已拦截：不显示
        }
    }
    if (origActivateAlertItem)
        origActivateAlertItem(self, _cmd, alertItem);
}

// 探针 B：SBUserNotificationAlert 展示状态变化（横幅/弹窗展示必走）
static void (*origUNASetState)(id, SEL, long long, long long);
static void replUNASetState(id self, SEL _cmd, long long from, long long to) {
    @try {
        routeLog([NSString stringWithFormat:@"PROBE-B UNA state from=%lld to=%lld class=%@", from, to, NSStringFromClass([self class])]);
    } @catch (id e) {}
    if (origUNASetState) origUNASetState(self, _cmd, from, to);
}

// 探针 C：SBAlertItemsController 实例激活路径
static void (*origCtrlActivate)(id, SEL, id);
static void replCtrlActivate(id self, SEL _cmd, id alertItem) {
    @try {
        NSString *cn = alertItem ? NSStringFromClass([alertItem class]) : @"nil";
        NSString *src = @"?";
        @try { src = [alertItem valueForKey:@"_alertSource"]; } @catch (id e) {}
        routeLog([NSString stringWithFormat:@"PROBE-C ctrlActivate class=%@ src=%@", cn, src]);
    } @catch (id e) {}
    if (origCtrlActivate) origCtrlActivate(self, _cmd, alertItem);
}

// ============================================================
// AirPods 路由强制：戴上即切 + 防车载抢路由
// 切换引擎 = MPAVRoutingController（MediaPlayer 私有类，控制中心
// "音频输出"列表的底层实现）：
//   - availableRoutes 列出所有可用设备（不依赖当前输出）→ 开盒未戴
//     （输出还是喇叭）时列表里就有 AirPods（picked=N）——解决 AVOutputContext
//     "只有当前输出、第一次连接拿不到设备对象"的死角
//   - pickRoute: 直接切换（iOS16 实机验证 ret=true + 回读 picked=AirPods，
//     不崩）
// 历史踩坑记录（勿回退）：
//   MRAVOutputContext.setOutputDevices: block 在 MediaRemote XPC 回复回调里
//   执行，SpringBoard 进程直接调必崩（EXC_BAD_ACCESS objc_storeStrong，两次
//   确认）；AVOutputContext.setOutputDevice: 是同进程安全，但 outputDevices
//   只有当前输出，第一次连接切不了。
// BluetoothManager connectedDevices 判断 AirPods 是否在场（不依赖当前路由）。
// ============================================================

// 路由切换核心（v1.9.14 重写）：
// MPAVRoutingController = 控制中心"音频输出"列表的底层实现（MediaPlayer 私有类，
// iOS16 实机验证：SpringBoard 进程内直接可用（不崩），availableRoutes 列出所有
// 可用设备——开盒未戴（输出还是喇叭）时列表里就有 AirPods Pro（picked=N），
// pickRoute: 可直接切换（验证 ret=true + 1.5s 后回读 picked=AirPods Pro）。
// 这解决了 AVOutputContext 的死角：outputDevices 只返回"当前输出"，第一次连接
// 时拿不到 AirPods 设备对象就切不了；MPAV 的 availableRoutes 任何时候都有。
// AVOutputContext 仅保留只读 outputDevices 用于"当前输出是否 AirPods"判断。
// ============================================================

@interface AVOutputContext : NSObject
+ (id)sharedSystemAudioContext;
- (NSArray *)outputDevices;
@end

@interface MPAVRoute : NSObject
- (NSString *)routeName;
- (BOOL)isPicked;
@end

@interface MPAVRoutingController : NSObject
- (id)init;
- (NSArray *)availableRoutes;
- (void)setDiscoveryMode:(NSInteger)mode;
- (void)fetchAvailableRoutesWithCompletionHandler:(void (^)(void))handler;
- (BOOL)pickRoute:(id)route;
- (id)pickedRoute;
@end

static id sMPARouter = nil;              // 复用的 MPAVRoutingController 实例
static NSTimeInterval sLastRouteForce = 0; // 强制切换冷却（3s 逃生通道；戴上时重置）
static BOOL sPrevAirInBT = NO; // 上次蓝牙列表是否含 AirPods（戴上 0→1 重置冷却）

// 当前输出路由是否全部为 AirPods（只读判断：AVOutputContext 当前输出）
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
// 路由事件日志（写文件，oslog 捕获不到注入 dylib 的 NSLog）
// 路由事件日志（排查模式：写文件，oslog 捕获不到注入 dylib 的 NSLog）
static void routeLog(NSString *msg) {
    FILE *f = fopen("/var/jb/tmp/airpods_route.log", "a");
    if (f) {
        fprintf(f, "[%s] %s\n", [[[NSDate date] description] UTF8String], [msg UTF8String]);
        fclose(f);
    }
}

// 强制切到 AirPods（MPAVRoutingController 版）
// 冷却策略（重要）：只有 stolen（防抢/逃生通道）走 3s 冷却——
// 想用车载时 3s 内连点车载 2 次，第二次在冷却期内不会被拉回；
// attached（戴上即切）【不走冷却】：戴上必须切（enforceAirPodsRoute 里
// 蓝牙 0→1 时重置 sLastRouteForce 实现）。
// 切换机制：MPAVRoutingController availableRoutes 找 AirPods → pickRoute:。
// availableRoutes 列出所有可用设备（不依赖当前输出），所以"第一次连接
// （respring 后首次/输出未切）"也能拿到 AirPods 强制切换。
static void forceRouteToAirPods(const char *why) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastRouteForce < 3.0) return;
    sLastRouteForce = now;
    // 幂等去重：输出已是 AirPods 就不再切（多通知源叠加时避免重复）
    if (currentOutputIsAirPods()) return;
    @try {
        if (!sMPARouter) {
            sMPARouter = [[NSClassFromString(@"MPAVRoutingController") alloc] init];
            [sMPARouter setDiscoveryMode:1];
            [sMPARouter fetchAvailableRoutesWithCompletionHandler:^{}]; // 触发刷新
        }
        NSArray *routes = [sMPARouter availableRoutes];
        id airRoute = nil;
        for (id r in routes) {
            if (isAirPodsName([r routeName])) { airRoute = r; break; }
        }
        if (airRoute) {
            BOOL ok = [sMPARouter pickRoute:airRoute];
            routeLog([NSString stringWithFormat:@"mpav-force(%s) ok=%d", why ? why : "?", ok]);
        } else {
            // 列表还没刷新出来（实例刚建）：0.4s 后重试一次，再不行靠轮询兜底
            routeLog([NSString stringWithFormat:@"mpav-force(%s) no-route-yet", why ? why : "?"]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (currentOutputIsAirPods()) return;
                NSArray *r2 = [sMPARouter availableRoutes];
                for (id r in r2) {
                    if (isAirPodsName([r routeName])) {
                        BOOL ok2 = [sMPARouter pickRoute:r];
                        routeLog([NSString stringWithFormat:@"mpav-force(%s) retry ok=%d", why ? why : "?", ok2]);
                        break;
                    }
                }
            });
        }
    } @catch (id e) {
        routeLog([NSString stringWithFormat:@"mpav-force(%s) EXC %@", why ? why : "?", e]);
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
static NSTimeInterval sLastDisconnect = 0; // 最近一次"AirPods 不在场"时刻
                                           // （断开保护期：5s 内不抢回——摘下放回
                                           //  盒子蓝牙断开时不抢；重新开盒会清除）

// 前向声明（定义在下方）
static void enforceAirPodsRoute(void);
static void startPollWindow(void);

// ============================================================
// 轮询窗口化管理（老板要求：只在需要兜底时轮询 1 分钟，平时零轮询）
// 触发：戴上（btconnect）、被抢（输出切走）→ 启动/重置 1 分钟窗口；
// 窗口到期自动停；AirPods 断开立即停。系统稳定（输出已是 AirPods
// 超过 1 分钟）后完全不轮询。
// ============================================================

static dispatch_source_t sPollTimer = NULL;
static BOOL sPollRunning = NO;
static NSTimeInterval sPollWindowEnd = 0;

static void startPollWindow(void) {
    if (!sPollTimer) return;
    sPollWindowEnd = [[NSDate date] timeIntervalSince1970] + 60.0; // 1 分钟窗口
    if (!sPollRunning) { dispatch_resume(sPollTimer); sPollRunning = YES; }
}

static void stopPoll(void) {
    sPollWindowEnd = 0;
    if (sPollRunning) { dispatch_suspend(sPollTimer); sPollRunning = NO; }
}

// 路由强制核心：AirPods 在场且输出非 AirPods → 切回（事件与轮询共用）。
// "开盒必切"（v1.9.21，老板定案）：不依赖入耳检测（worn 门控已删——
// 其滞后/假阳性导致开盒未戴不切、摘下抢回），切换条件 = AirPods 在场
// （蓝牙列表/音频路由任一命中）→ 输出非 AirPods → 强制切回。
//   开盒（btconnect）→ 重置冷却 + 清断开保护期 → attached 必切
//   车载抢（在场）→ stolen 抢回
//   摘下放回盒子（蓝牙断开）→ 断开保护期 5s 内不抢（白送优化，老板
//     已接受摘下拿手里/蓝牙还连时的抢回行为）
//   手动切喇叭连点 2 次 → 3s 逃生通道保留
static void enforceAirPodsRoute(void) {
    @try {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        BOOL airInRoute = airPodsInCurrentRoute();
        BOOL airInBT = airPodsInBluetoothDevices();
        // 连接（蓝牙 0→1）：重置 3s 逃生冷却，保证"开盒必切"不被连点冷却挡住
        if (airInBT && !sPrevAirInBT)
            sLastRouteForce = 0;
        sPrevAirInBT = airInBT;
        sAirPodsConnected = airInRoute || airInBT;
        if (!sAirPodsConnected) {
            sOutputWasAirPods = NO; // 不在场，重置状态
            sLastDisconnect = now;  // 断开保护期（摘下放回盒子）
            return;
        }
        // 断开保护期：5s 内 AirPods 不在场过（摘下放回盒子）→ 不抢回，
        // 避免摘下瞬间输出被系统切走时我们抢回
        if (now - sLastDisconnect < 5.0) {
            sOutputWasAirPods = NO;
            return;
        }
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
            // 被抢/戴上需要切 → 重启 1 分钟轮询窗口（车载再开、系统抖动都能兜底；
            // 系统稳定后窗口到期自动停，平时零轮询）
            startPollWindow();
        }
    } @catch (id e) {}
}

static int sLastEvtState = -1; // 日志限流：AirPods 在场状态 0/1，变化才写日志
static BOOL sPrevAttached = NO; // 上次 handleRouteEvent 的在场状态（conn 0→1 判定"新戴上"，
                                // 只在此时压媒体音量；摘下方向绝不碰）

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
            // 媒体音量：只在"新戴上"（conn 0→1 跳变）时压到 70（v1.9.27）。
            // ⚠️ 关键时序修复：**绝不立即压**——btconnect 瞬间输出还在喇叭，
            // setVolumeTo(0.7) 会改喇叭音量+污染喇叭记忆（摘下后系统恢复的
            // 喇叭记忆被我们改成 70 → 回不到戴前值，老板实测"摘下停在 70"）。
            // 正确做法：等 attached 切换完成（输出确认是 AirPods）再压——
            // 只改 AirPods 音量/记忆，喇叭记忆不碰，摘下后系统正常恢复。
            // 压三次（0.8s/2.0s/3.2s，输出是 AirPods 才压）：覆盖系统经
            // MediaRemote 路径的延迟音量设置。getVolume 恒假值不读取。
            BOOL newlyAttached = !sPrevAttached;
            if (newlyAttached) {
                if (currentOutputIsAirPods()) {
                    [avc setVolumeTo:0.7f forCategory:@"Audio/Video"];
                    routeLog([NSString stringWithFormat:@"attach(%@) press media ->70 (already AirPods)", source]);
                }
                void (^pressWhenAirPods)(double, NSString *) = ^(double delay, NSString *tag) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (currentOutputIsAirPods()) {
                            id avc2 = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                            [avc2 setVolumeTo:0.7f forCategory:@"Audio/Video"];
                            routeLog([NSString stringWithFormat:@"attach(%@) %@ press media ->70 (output AirPods)", source, tag]);
                        }
                    });
                };
                pressWhenAirPods(0.8, @"t0.8");
                pressWhenAirPods(2.0, @"t2.0");
                pressWhenAirPods(3.2, @"t3.2");
            }
        } else {
            // 摘下 AirPods（不管车载是否还在）：恢复通知音 100%，静音模式下不强制
            if (!isRingerMuted()) {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
            // 摘下媒体音量：不碰——iOS 为每个输出设备独立记忆音量，
            // 输出切回喇叭时系统自动恢复喇叭记忆音量（老板实测手动点喇叭
            // 会自动回到戴前值 93）。之前主动 setVolumeTo 反而覆盖了系统恢复。
        }
        sPrevAttached = sAirPodsConnected; // 更新状态（新戴上判定用）
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
    // 预建 MPAVRoutingController 实例 + 触发刷新：消除首次连接时
    // availableRoutes 为空导致的 no-route-yet 半秒延迟（开盒即能直接切）
    @try {
        sMPARouter = [[NSClassFromString(@"MPAVRoutingController") alloc] init];
        [sMPARouter setDiscoveryMode:1];
        [sMPARouter fetchAvailableRoutesWithCompletionHandler:^{}];
    } @catch (id e) {}

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

    // 1.5s 轮询兜底：保证"开盒必切"（系统不切输出时设备列表无变化、通知不触发）。
    // **窗口化**（老板要求）——连接/被抢时启动 1 分钟兜底窗口，
    // 窗口到期自动停；车载再次打开（再抢）→ 事件触发重启 1 分钟窗口。平时零轮询。
    sPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sPollTimer, dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
                              1.5 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sPollTimer, ^{
        // 窗口到期自动停止（零轮询）
        if ([[NSDate date] timeIntervalSince1970] > sPollWindowEnd) {
            if (sPollRunning) { dispatch_suspend(sPollTimer); sPollRunning = NO; }
            return;
        }
        enforceAirPodsRoute();
    });
    dispatch_suspend(sPollTimer); // 初始不轮询，等事件启动窗口

    // 蓝牙设备连接成功（开盒 AirPods、车载等任何蓝牙设备都触发）
    // → 启动轮询窗口 + 立即强制路由。
    // 关键：**先重置 3s 逃生冷却**——车载连接是"自动事件"，必须保证抢回
    // 不被逃生通道挡住（戴上后很快开车载的场景）；手动切喇叭/车载连点
    // 2 次走 outputdev 通知（不重置冷却），逃生通道保留。
    [[NSNotificationCenter defaultCenter] addObserverForName:@"BluetoothDeviceConnectSuccessNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (airPodsInBluetoothDevices()) {
            sLastRouteForce = 0;    // 车载/设备连接：重置冷却，确保开盒必切/抢回
            sLastDisconnect = 0;    // 清除断开保护期：重新开盒必切（不被摘盒保护挡）
            startPollWindow();
            handleRouteEvent(@"btconnect");
        }
    }];
    // AirPods 蓝牙断开 → 立即停止轮询（不等窗口到期）
    [[NSNotificationCenter defaultCenter] addObserverForName:@"BluetoothDeviceDisconnectSuccessNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        stopPoll();
        handleRouteEvent(@"btdisconnect");
    }];

    // 启动时若已连 AirPods（如 respring 后仍连着）：启动轮询窗口 + 初始强制切
    if (sAirPodsConnected) {
        startPollWindow();
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

    // 剪贴板"粘贴自"提示拦截（iOS16：SBAlertItem +activateAlertItem: 类方法，
    // 用 MSHookFunction 挂类方法 IMP——MSHookMessageEx 只支持实例方法）
    {
        Class sbaCls = NSClassFromString(@"SBAlertItem");
        if (sbaCls) {
            Method m = class_getClassMethod(sbaCls, NSSelectorFromString(@"activateAlertItem:"));
            if (m) {
                IMP imp = method_getImplementation(m);
                MSHookFunction(imp, (IMP)replActivateAlertItem, (IMP *)&origActivateAlertItem);
            }
        }
    }

    // 探针 B/C（v1.9.30 排查"粘贴自"横幅真实路径）：UNA 展示状态 + 控制器激活
    {
        Class unaCls = NSClassFromString(@"SBUserNotificationAlert");
        if (unaCls) {
            Method mb = class_getInstanceMethod(unaCls, NSSelectorFromString(@"presentationStateDidChangeFromState:toState:"));
            if (mb) MSHookFunction(method_getImplementation(mb), (IMP)replUNASetState, (IMP *)&origUNASetState);
        }
        Class ctrlCls = NSClassFromString(@"SBAlertItemsController");
        if (ctrlCls) {
            Method mc = class_getInstanceMethod(ctrlCls, NSSelectorFromString(@"activateAlertItem:"));
            if (mc) MSHookFunction(method_getImplementation(mc), (IMP)replCtrlActivate, (IMP *)&origCtrlActivate);
        }
    }
}
