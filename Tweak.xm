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
// HFP 激活（强制把通话路由钉到该蓝牙设备）：车载抢通话时我们反向激活 AirPods HFP
- (void)setWantsToBeActivated:(BOOL)arg1;
@end

@interface BluetoothManager : NSObject
+ (id)sharedInstance;
- (NSArray *)connectedDevices;
- (NSArray *)connectedHFPDevices;
- (void)setDevice:(id)arg1 wantsToBeActivated:(BOOL)arg2;
@end

// 前向声明：路由日志函数（定义在下方），避免被插在它前面的函数调用时报未声明
static void routeLog(NSString *msg);

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
    // 戴上 AirPods：物理音量键+ 禁用（老板要求：戴上时按钮不生效，只能控制中心调）。
    // 原实现读 getVolume("Audio/Video") >= 0.7 吞掉音量+——但视频通话（HFP）时
    // getVolume 返回通话音量（常 >=0.7）→ 音量+永远按不动（实测 bug）；且老板
    // 要的是戴上时 +/- 全禁，故直接 return NO，不做任何读取判断。
    if (sAirPodsConnected) return NO;
    return %orig;
}
- (BOOL)decreaseVolume {
    // 戴上 AirPods：物理音量键- 禁用（与 + 对称，老板要求按钮整体不生效）
    if (sAirPodsConnected) return NO;
    return %orig;
}
%end

// ============================================================
// 音量 HUD 永远小条（方案 A 修正，2026-08-21）
// iOS 16 音量 HUD = SBElasticVolumeViewController 状态机：
// _updateSliderViewMetricsForState: 的 state 1=大条(large)、2=mini 小条、
// 3=giant。按音量键先 state1 再转 state2 → 老板看到的"大的变小的"。
// ⚠️ 修正：此前 hook SBVolumeHUDViewController（iOS15 老类）无效——
// iOS16 大条就是这个弹性 VC 的 state1。参考 VolVibes mini 样式：
// 强制 %orig(2, ...) 永远直接 mini 小条。
// ============================================================

%hook SBElasticVolumeViewController
- (void)_updateSliderViewMetricsForState:(long long)state bounds:(CGRect)bounds integralized:(BOOL)integralized useSizeSpringData:(BOOL)useSizeSpringData useCenterSpringData:(BOOL)useCenterSpringData {
    // 强制 state=2（mini 小条）：永远直接小条，跳过大条过渡
    %orig(2, bounds, integralized, useSizeSpringData, useCenterSpringData);
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
// 控制中心：Now Playing（正在播放）模块压成 1x1
// ============================================================
// 尺寸单位 = 控制中心网格格数（竖屏共 4 列）。原生 nowplaying 占 2 宽 x 2 高
// （吃掉半屏宽 + 两行），目标改 1x1。
//
// ⚠️ 为什么不能改 plist：尺寸表在
// /System/Library/PrivateFrameworks/ControlCenterUI.framework/DefaultModuleSettings~iphone.plist
// 但根分区挂载属性是 (apfs, sealed, read-only)，rootless 越狱下 root 也写不进去
// （实测 echo >> 该文件报 read-only file system），只能走运行时 hook。
//
// 实现依据（逆向 xyz.cypwn.bettercc 0.0.55，Ghidra 反编译实锤）：
//   它 MSHookMessageEx 挂 CCUIModuleSettingsManager 的
//   -moduleSettingsForModuleIdentifier:prototypeSize:，命中目标模块后
//   **不调原实现**，直接返回新建的
//   [[CCUIModuleSettings alloc] initWithPortraitLayoutSize:landscapeLayoutSize:]。
//   我们只做 media 那一支，其余模块一律走原实现（不误伤别的模块）。
// ============================================================

typedef struct { unsigned long long width; unsigned long long height; } CCUILayoutSize;

@interface CCUIModuleSettings : NSObject
- (instancetype)initWithPortraitLayoutSize:(CCUILayoutSize)portraitSize
                       landscapeLayoutSize:(CCUILayoutSize)landscapeSize;
@end

@interface CCUIModuleSettingsManager : NSObject
- (id)moduleSettingsForModuleIdentifier:(NSString *)identifier
                          prototypeSize:(CCUILayoutSize)prototypeSize;
@end

// 控制中心音乐模块（nowplaying）的 identifier
static NSString * const kNowPlayingModuleID = @"com.apple.mediaremote.controlcenter.nowplaying";

// 诊断日志（轻量：装载 + 命中各数行；验证通过后可将 CC_DEBUG 置 0 关掉）
#define CC_DEBUG 1
static void ccLog(NSString *msg) {
#if CC_DEBUG
    FILE *f = fopen("/var/jb/tmp/airpods_cc.log", "a");
    if (f) {
        fprintf(f, "[%s] %s\n", [[[NSDate date] description] UTF8String], [msg UTF8String]);
        fclose(f);
    }
#endif
}

static id (*origModuleSettingsForModule)(id, SEL, NSString *, CCUILayoutSize) = NULL;

static id replModuleSettingsForModule(id self, SEL _cmd, NSString *identifier, CCUILayoutSize proto) {
    // 非目标模块：原样返回，保持系统行为
    if (![identifier isEqualToString:kNowPlayingModuleID]) {
        return origModuleSettingsForModule ? origModuleSettingsForModule(self, _cmd, identifier, proto) : nil;
    }

    // 目标模块：拿原 settings 做兜底，再返回 1x1 的新 settings
    id origSettings = origModuleSettingsForModule ? origModuleSettingsForModule(self, _cmd, identifier, proto) : nil;
    @try {
        CCUILayoutSize one = { 1, 1 };
        // ⚠️ 不能写 [[CCUIModuleSettings alloc] init...]：直接引用类名会生成
        // _OBJC_CLASS_$_CCUIModuleSettings 符号，而 theos SDK 里没有
        // ControlCenterUI 框架可链接（ld: framework 'ControlCenterUI' not found）。
        // 用 Class 变量发消息 → 运行时查找、不产生类符号，同时保留 ARC 内存管理
        // （比 objc_msgSend 强转安全）。
        Class settingsCls = NSClassFromString(@"CCUIModuleSettings");
        SEL initSel = NSSelectorFromString(@"initWithPortraitLayoutSize:landscapeLayoutSize:");
        if (settingsCls && [settingsCls instancesRespondToSelector:initSel]) {
            id raw = [settingsCls alloc];
            id mini = [raw initWithPortraitLayoutSize:one landscapeLayoutSize:one];
            if (mini) {
                ccLog(@"nowplaying -> 1x1 (新建 CCUIModuleSettings 替换)");
                return mini;
            }
            ccLog(@"nowplaying -> 新建 CCUIModuleSettings 返回 nil，退回原 settings");
        } else {
            ccLog(@"nowplaying -> CCUIModuleSettings 类/初始化方法不可用，退回原 settings");
        }
    } @catch (id e) {
        ccLog([NSString stringWithFormat:@"nowplaying EXC %@", e]);
    }
    return origSettings;
}

static void installNowPlaying1x1(void) {
    // 系统框架只在 dyld 缓存里（文件系统里已无二进制），先强制加载再取类
    dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_NOW);
    Class mgrCls = NSClassFromString(@"CCUIModuleSettingsManager");
    if (!mgrCls) {
        ccLog(@"CCUIModuleSettingsManager 未找到（框架未加载）");
        return;
    }
    SEL sel = NSSelectorFromString(@"moduleSettingsForModuleIdentifier:prototypeSize:");
    if (![mgrCls instancesRespondToSelector:sel]) {
        ccLog(@"CCUIModuleSettingsManager 不响应 moduleSettingsForModuleIdentifier:prototypeSize:");
        return;
    }
    MSHookMessageEx(mgrCls, sel, (IMP)replModuleSettingsForModule, (IMP *)&origModuleSettingsForModule);
    ccLog(@"hook 装载完成: CCUIModuleSettingsManager -moduleSettingsForModuleIdentifier:prototypeSize:");
}

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
// ⚠️ 只反映 A2DP 媒体输出——蓝牙耳机同时有 A2DP(媒体)+HFP(通话)两个端口，
// 视频通话时系统可能把 HFP 单独切到车载（A2DP 还在 AirPods）→ 此函数会
// 误判"输出是 AirPods"而不抢。必须配合 carHFPActive() 一起判断。
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

// 检测 HFP 通话路由是否被车载占用（视频/语音通话场景，2026-08-23 老板实测）：
// 抖音 A2DP 还在 AirPods 放，打微信视频时系统把 HFP 通话路由单独切到车载
//（车载免提优先级）→ currentRoute.outputs 出现"非 AirPods 的 BluetoothHFP 端口"。
// 这是 currentOutputIsAirPods() 看不到的盲区，必须单独检测。
static BOOL carHFPActive(void) {
    @try {
        AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
        for (AVAudioSessionPortDescription *p in route.outputs) {
            if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
                if (!isAirPodsName(p.portName)) return YES; // HFP 输出不是 AirPods = 车载
            }
        }
    } @catch (id e) {}
    return NO;
}

// ---- HFP 通话路由综合检测（车载抢通话，2026-08-23 老板实测）----
// 蓝牙耳机同时有 A2DP(媒体)+HFP(通话)两个端口；视频/语音通话时系统把 HFP
// 单独切到车载（车载免提优先），而 A2DP 媒体可能还在 AirPods（抖音在放）。
// 以下多个角度判断是否"车载正占用通话路由"，任一为真即视为车载抢了通话。

// 是否有"非 AirPods 的蓝牙设备"已连接（车载/其他蓝牙）→ 车模式判定用
static BOOL otherBTDeviceConnected(void) {
    @try {
        id bm = [NSClassFromString(@"BluetoothManager") sharedInstance];
        NSArray *devs = [bm connectedDevices];
        for (id d in devs) {
            NSString *nm = [d name];
            if (nm && !isAirPodsName(nm)) return YES;
        }
    } @catch (id e) {}
    return NO;
}

// 系统输出设备列表里是否有"已连的非 AirPods 蓝牙设备"成为当前输出（车载 HFP 通话输出）
// 交叉比对蓝牙列表里的非 AirPods 已连设备名与系统当前输出设备名——避免误判内置喇叭
static BOOL carInSystemOutput(void) {
    @try {
        NSMutableSet *carNames = [NSMutableSet set];
        id bm = [NSClassFromString(@"BluetoothManager") sharedInstance];
        if (bm && [bm respondsToSelector:@selector(connectedDevices)]) {
            for (id d in [bm connectedDevices]) {
                NSString *nm = [d name];
                if (nm && !isAirPodsName(nm)) [carNames addObject:nm];
            }
        }
        if (carNames.count == 0) return NO; // 没有非 AirPods 蓝牙设备 → 不可能被车载抢
        id ctx = [NSClassFromString(@"AVOutputContext") sharedSystemAudioContext];
        NSArray *devs = [ctx outputDevices];
        for (id d in devs) {
            NSString *nm = [d name];
            if (nm && [carNames containsObject:nm]) return YES; // 车载设备已成为当前系统输出
        }
    } @catch (id e) {}
    return NO;
}

// 通话输入是否被车载占用（currentRoute.inputs 出现非 AirPods 的 BluetoothHFP）
static BOOL carHFPInputActive(void) {
    @try {
        AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
        for (AVAudioSessionPortDescription *p in route.inputs) {
            if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
                if (!isAirPodsName(p.portName)) return YES;
            }
        }
    } @catch (id e) {}
    return NO;
}

// 综合：车载是否正占用通话路由（任一检测为真）
static BOOL carOwnsCall(void) {
    return carHFPActive() || carHFPInputActive() || carInSystemOutput();
}

// 路由事件日志（v1.9.50 生产静默：不写文件，零 IO；排查时恢复函数体）
// ⚠️ 调试基准 = v1.9.46（19dd6db，日志开启）
static void routeLog(NSString *msg) {
    (void)msg;
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
            routeLog([NSString stringWithFormat:@"mpav-force(%s) ok=%d hfpBefore=%d", why ? why : "?", ok, carHFPActive()]);
            // 诊断：pickRoute 后 0.6s 复查 HFP 是否跟着切（验证 MediaRemote 能否控制 HFP 通话路由）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                routeLog([NSString stringWithFormat:@"mpav-force(%s) hfpAfter0.6=%d", why ? why : "?", carHFPActive()]);
            });
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

// 强制把通话路由抢回 AirPods（v1.9.50 定型）
// 实机验证（2026-08-25 车在，7+ 次全成功）：S1 MPAVRoutingController pickRoute:
// 是唯一生效策略——MediaRemote 不仅能切 A2DP 媒体，也能切 HFP 通话路由
//（route 行实测 BluetoothHFP:Honda HFT -> BluetoothHFP:AirPods Pro）。
// S2 setPreferredInput:（车载占 HFP 时 AirPods HFP 端口不在 availableInputs，
// 永远 no-HFP-port）与 S3 setWantsToBeActivated:（从不触发）实测无效已删。
// 短冷却 0.8s：允许轮询每次尝试重抢，但不被通知风暴刷爆
static NSTimeInterval sLastCallForce = 0;
static void forceCallToAirPods(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastCallForce < 0.8) return;
    sLastCallForce = now;
    @try {
        if (!carOwnsCall()) return;
        if (!sMPARouter) {
            sMPARouter = [[NSClassFromString(@"MPAVRoutingController") alloc] init];
            [sMPARouter setDiscoveryMode:1];
            [sMPARouter fetchAvailableRoutesWithCompletionHandler:^{}];
        }
        NSArray *routes = [sMPARouter availableRoutes];
        id airRoute = nil;
        for (id r in routes) { if (isAirPodsName([r routeName])) { airRoute = r; break; } }
        if (airRoute) {
            [sMPARouter pickRoute:airRoute];
        } else {
            // 列表还没刷新出来（实例刚建）：0.4s 后重试一次，再不行靠车模式轮询兜底
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (carOwnsCall()) {
                    NSArray *r2 = [sMPARouter availableRoutes];
                    for (id r in r2) {
                        if (isAirPodsName([r routeName])) { [sMPARouter pickRoute:r]; break; }
                    }
                }
            });
        }
    } @catch (id e) {}
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
static void forceCallToAirPods(void);
static BOOL carOwnsCall(void);

// ============================================================
// 轮询窗口化管理（老板要求：只在需要兜底时轮询，平时零轮询）
// 触发：戴上（btconnect）、被抢（输出切走）→ 启动/重置 1 分钟窗口
//（抢车载场景窗口要久一点）；窗口到期自动停；AirPods 断开立即停。
// 通话挂断后的媒体音量复查是独立 5 秒 dispatch_after（见 handleRouteEvent）。
// ============================================================

static dispatch_source_t sPollTimer = NULL;
static BOOL sPollRunning = NO;
static NSTimeInterval sPollWindowEnd = 0;

static void startPollWindow(void) {
    if (!sPollTimer) return;
    sPollWindowEnd = [[NSDate date] timeIntervalSince1970] + 60.0; // 1 分钟窗口（抢车载）
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
        // ⚠️ HFP 通话路由盲区（2026-08-23 老板实测）：视频/语音通话时系统把
        // HFP 通话路由单独切到车载（车载免提优先），而 A2DP 媒体输出可能还在
        // AirPods（抖音在放）→ 上面 outIsAP=YES 误判"输出是 AirPods"不抢。
        // 综合检测 carOwnsCall（HFP 输出/输入/系统输出任一为车载）→ 多策略抢回。
        if (carOwnsCall()) {
            routeLog(@"enforce carOwnsCall=1 -> forceCallToAirPods");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                forceCallToAirPods();
            });
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
            // 通话挂断后的媒体复查（老板需求）：微信视频/语音拨出未接通→挂断时，
            // 系统把路由从 HFP 通话通道切回 A2DP，并恢复"媒体音量记忆值"——若
            // 记忆值是 100（实测弹回 100），且恢复走 MediaRemote 路径绕过
            // setVolumeTo cap，我们就拦不住。每次路由事件安排一次 5 秒后复查：
            // 挂断 5 秒内发现媒体 >70% → 压回 70%（AirPods 记忆值随之变 70，
            // 下次挂断系统恢复 70，不再弹 100）。getVolume 无播放会话时返回
            // 缓存假值 0.70，>0.7 判断不会误压；真 100 能读到并压回。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sAirPodsConnected && currentOutputIsAirPods()) {
                    id avc2 = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                    float mv = -1.0f;
                    if ([avc2 getVolume:&mv forCategory:@"Audio/Video"] && mv > 0.7f) {
                        [avc2 setVolumeTo:0.7f forCategory:@"Audio/Video"];
                        routeLog([NSString stringWithFormat:@"recheck(%@) media %.2f ->70 (post-call restore)", source, mv]);
                    }
                }
            });
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
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        // 车模式（车载+AirPods 同时在场）：持续监控，窗口续期不断，
        // 保证"车载连接状态下打微信视频被切车载"能在 1.5s 内被抢回
        if (sAirPodsConnected && otherBTDeviceConnected()) {
            sPollWindowEnd = now + 60.0;
        } else if (now > sPollWindowEnd) {
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
        // 任何蓝牙设备连接（车载/开盒）→ 无条件兜底：重置冷却 + 清断开保护 +
        // 开窗口 + 检查路由。⚠️ 不能依赖 airPodsInBluetoothDevices()——车载连接
        // 瞬间蓝牙列表可能滞后（AirPods 未出现在列表），旧代码整个分支被跳过
        // → 冷却没重置 + 窗口没开 → 漏抢（实测"有一次没抢回来"）。在场判断
        // 交给 handleRouteEvent/enforce 内部，这里无条件执行保证保底。
        sLastRouteForce = 0;    // 车载/设备连接：重置冷却，确保开盒必切/抢回
        sLastDisconnect = 0;    // 清除断开保护期：重新开盒必切（不被摘盒保护挡）
        startPollWindow();
        handleRouteEvent(@"btconnect");
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

    // 控制中心 Now Playing 模块压成 1x1（BetterCC 同款机制，只做 media 一支）
    installNowPlaying1x1();

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
