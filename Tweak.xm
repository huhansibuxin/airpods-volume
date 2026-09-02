#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>
#include <unistd.h>

// ============================================================
// 偏好设置（TGK 风格 plist）
// layout/Library/PreferenceLoader/Preferences/AirPodsVolume/Preferences.plist
// domain = com.huhansibuxin.airpodsvolume
// PostNotification = com.huhansibuxin.airpodsvolume-updated
// ============================================================

static NSString * const kAPVDomain = @"com.huhansibuxin.airpodsvolume";
static NSString * const kAPVChanged = @"com.huhansibuxin.airpodsvolume-updated";

// 读 BOOL（直连 cfprefsd 取新鲜值）
static BOOL apv_bool(NSString *key, BOOL def) {
    Boolean valid = false;
    Boolean v = CFPreferencesGetAppBooleanValue((CFStringRef)key,
                                                (CFStringRef)kAPVDomain, &valid);
    return valid ? (BOOL)v : def;
}

// 缓存（启动 + 设置变更通知时刷新，避免每个事件都读 pref）
static BOOL gAutoRoute = YES, gStealBack = YES, gStealHFP = YES;
static BOOL gHideReplayKit = YES;
static BOOL gShrinkNowPlaying = YES, gHidePrevNext = YES;
static BOOL gBlockPopup = YES, gBlockShortcuts = YES;
static BOOL gMiniVolumeHUD = YES, gDisableHUDTouch = YES;
static BOOL gVolDiag = NO;      // 音量诊断日志（默认关：每次 setVolumeTo 都记，排查用）
static BOOL gShowRingerSlider = YES; // 控制中心音量模块展开后显示铃声音量滑块（默认开）
static BOOL gLimitRinger = YES;      // 戴 AirPods 时限制铃声音量（v1.9.77 开关，默认开；摘下强制 100% 常驻不受此开关影响）
static BOOL gRingerCap30 = NO;       // v1.9.82：铃封顶档位——关=40%，开=30%（仅在 gLimitRinger 打开时有效）
static BOOL gNotifGroupFrom3 = NO;   // v1.9.91：通知合并档位——关=第 2 条起合并成一栏（NDH 原行为），开=第 3 条起才合并

// ---- v1.9.96：SystemX(SystemBox) 移植功能开关（全部默认关闭）----
static BOOL gRunIndicator = NO;        // APP 运行指示点：正在运行的 APP 图标下方显示彩色小圆点
static BOOL gNoLockAfterRespring = NO; // 注销（respring）不锁屏
static BOOL gColorizeVPN = NO;         // 连接 VPN 后状态栏 VPN 图标变色
static BOOL gDisableHomeLongPress = NO;// 禁用桌面长按（不再进抖动编辑态）
static BOOL gHideVPNFlyIn = NO;        // 禁用 VPN 图标飞入动画（瞬间出现）
static UIColor *gRunDotColor = nil;    // 指示点颜色（颜色代码解析结果）
static UIColor *gVPNColor = nil;       // VPN 图标颜色（颜色代码解析结果）

// 读字符串偏好（直连 cfprefsd，与 apv_bool 一样拿新鲜值，不受进程内缓存影响）
static NSString *apv_string(NSString *key, NSString *def) {
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                 (__bridge CFStringRef)kAPVDomain,
                                                 kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost);
    NSString *s = nil;
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) s = [(__bridge NSString *)v copy];
        CFRelease(v);
    }
    return s.length ? s : def;
}

// 颜色代码解析：支持 #RRGGBB / RRGGBB / "R,G,B"(0-255) 三种写法；解析不了或留空用 fallback。
// （老板要求：设置里不做颜色选择器，直接手填颜色代码）
static UIColor *apv_colorFromCode(NSString *code, NSString *fallback) {
    NSString *s = [code stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) s = fallback;
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length == 6) {
        unsigned int rgb = 0;
        NSScanner *sc = [NSScanner scannerWithString:s];
        if ([sc scanHexInt:&rgb]) {
            return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                   green:((rgb >> 8) & 0xFF) / 255.0
                                    blue:(rgb & 0xFF) / 255.0
                                   alpha:1.0];
        }
    }
    NSArray *parts = [s componentsSeparatedByString:@","];
    if (parts.count == 3) {
        CGFloat r = [parts[0] floatValue], g = [parts[1] floatValue], b = [parts[2] floatValue];
        return [UIColor colorWithRed:MIN(MAX(r / 255.0f, 0.0f), 1.0f)
                               green:MIN(MAX(g / 255.0f, 0.0f), 1.0f)
                                blue:MIN(MAX(b / 255.0f, 0.0f), 1.0f)
                               alpha:1.0];
    }
    return [UIColor whiteColor];
}

// 戴耳机时通知音(Ringtone/Alert)的封顶值，全局唯一出口，禁止再散落硬编码 0.4/0.3：
//   gLimitRinger 关           → 1.0（不限制）
//   gLimitRinger 开 + 档位 40% → 0.4
//   gLimitRinger 开 + 档位 30% → 0.3
static float apv_notifyCap(void) {
    if (!gLimitRinger) return 1.0f;
    return gRingerCap30 ? 0.3f : 0.4f;
}

static void apv_refresh(void) {
    gAutoRoute = apv_bool(@"autoRouteToAirPods", YES);
    gStealBack = apv_bool(@"stealBackFromCar", YES);
    gStealHFP = apv_bool(@"stealBackHFPCalls", YES);
    gHideReplayKit = apv_bool(@"hideReplayKitCCModules", YES);
    gShrinkNowPlaying = apv_bool(@"shrinkNowPlayingCCModule", YES);
    gHidePrevNext = apv_bool(@"hideNowPlayingPrevNext", YES);
    gBlockPopup = apv_bool(@"blockAirPodsPopup", YES);
    gBlockShortcuts = apv_bool(@"blockShortcutsNotifications", YES);
    gMiniVolumeHUD = apv_bool(@"miniVolumeHUD", YES);
    gDisableHUDTouch = apv_bool(@"disableVolumeHUDTouch", YES);
    gVolDiag = apv_bool(@"volumeDiagLog", NO);
    gShowRingerSlider = apv_bool(@"showRingerSlider", YES);
    gLimitRinger = apv_bool(@"limitRingerWhenConnected", YES);
    gRingerCap30 = apv_bool(@"ringerCap30", NO);
    gNotifGroupFrom3 = apv_bool(@"notifGroupFrom3", NO);
    // v1.9.96：SystemX 移植功能（默认全关）
    gRunIndicator = apv_bool(@"runIndicatorEnabled", NO);
    gNoLockAfterRespring = apv_bool(@"noLockAfterRespring", NO);
    gColorizeVPN = apv_bool(@"colorizeVPNStatusBar", NO);
    gDisableHomeLongPress = apv_bool(@"disableHomeScreenLongPress", NO);
    gHideVPNFlyIn = apv_bool(@"hideVPNFlyInAnimation", NO);
    gRunDotColor = apv_colorFromCode(apv_string(@"runIndicatorColor", @"#FFFFFF"), @"#FFFFFF");
    gVPNColor = apv_colorFromCode(apv_string(@"vpnStatusBarColor", @"#FF9F0A"), @"#FF9F0A");
}

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
    // v1.9.92：热路径优化——getVolume/setVolumeTo 每次调用都进来，
    // 先走精确匹配（绝大多数调用就是 @"Ringtone"/@"Alert" 常量，零堆分配），
    // 未命中再退回旧的 description+containsString 宽松匹配。
    if ([cat isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)cat;
        if ([s isEqualToString:@"Ringtone"] || [s isEqualToString:@"Alert"]) return YES;
    }
    NSString *d = [cat description];
    return [d containsString:@"Ringtone"] || [d containsString:@"Alert"];
}

static BOOL sAirPodsConnected = NO;

// ============================================================
// v1.9.92：XPC 查询 TTL 缓存（主线程/CPU 开销优化）
//
// 问题：一次路由事件 burst 里，airPodsInCurrentRoute / hfpCallActive /
// carHFPActive / carHFPInputActive 各自同步查 [AVAudioSession
// sharedInstance].currentRoute（XPC 到 mediaserverd），currentOutputIsAirPods /
// carInSystemOutput 各自查 AVOutputContext outputDevices，蓝牙三兄弟各自查
// BluetoothManager connectedDevices——同一份系统状态在一次事件里被同步问了
// 4~6 遍，全在主线程。轮询窗口开着的 1.5s tick 也反复问。
//
// 修法：三类查询各挂一个小 TTL 缓存，事件入口（handleRouteEvent）主动失效
// 保证事件时刻拿到新鲜值；burst 内后续调用直接命中缓存。
// TTL 选值依据：通知本身是"状态已变"的信号，入口失效后第一遍必是新值；
// 轮询 tick 间隔 1.5s > 全部 TTL，兜底检测永远能拿到不早于 tick 的数据。
// （缓存读写均为单字对齐的指针/时间戳，ARM64 上读写原子，竞态最坏后果
//  只是多查一次，无实际危害，不加锁避免热路径锁开销。）
// ============================================================

static NSTimeInterval apv_now(void) { return [[NSDate date] timeIntervalSince1970]; }

// ---- 缓存 1：AVAudioSession currentRoute + availableInputs（0.4s）----
static AVAudioSessionRouteDescription *sCachedRoute = nil;
static NSArray *sCachedInputs = nil;
static NSTimeInterval sCachedRouteAt = -1e9;

static void apv_invalidateSessionCache(void) {
    sCachedRoute = nil; sCachedInputs = nil; sCachedRouteAt = -1e9;
}

// currentRoute + availableInputs 一次取齐（两者都走 mediaserverd，一次 burst 只付一遍）
static BOOL apv_sessionSnapshot(AVAudioSessionRouteDescription **routeOut, NSArray **inputsOut) {
    NSTimeInterval now = apv_now();
    if (!sCachedRoute || (now - sCachedRouteAt) >= 0.4) {
        @try {
            AVAudioSession *ses = [AVAudioSession sharedInstance];
            sCachedRoute  = ses.currentRoute;
            sCachedInputs = ses.availableInputs;
        } @catch (id e) { sCachedRoute = nil; sCachedInputs = nil; }
        sCachedRouteAt = now;
    }
    *routeOut = sCachedRoute;
    *inputsOut = sCachedInputs;
    return sCachedRoute != nil;
}

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

// 前向声明：日志函数定义在下方，但上面的音量 hook 就要用到
static void routeLog(NSString *msg);
static void volLog(NSString *msg);
static NSString *volStack(NSUInteger n);

static BOOL isAirPodsName(NSString *name) {
    return name && [name containsString:@"AirPods"];
}

// ---- 缓存 2：BluetoothManager connectedDevices（0.8s）----
// 蓝牙服务 XPC：airPodsInBluetoothDevices / otherBTDeviceConnected /
// carInSystemOutput 三处共用；轮询窗口开着的 1.5s tick 也走这里。
static NSArray *sCachedBTDevs = nil;
static NSTimeInterval sCachedBTAt = -1e9;
static NSArray *apv_btDevicesCached(void) {
    NSTimeInterval now = apv_now();
    if (!sCachedBTDevs || (now - sCachedBTAt) >= 0.8) {
        @try {
            id bm = [NSClassFromString(@"BluetoothManager") sharedInstance];
            sCachedBTDevs = [bm connectedDevices] ?: @[];
        } @catch (id e) { sCachedBTDevs = @[]; }
        sCachedBTAt = now;
    }
    return sCachedBTDevs;
}

static BOOL airPodsInBluetoothDevices(void) {
    for (id d in apv_btDevicesCached()) {
        if (isAirPodsName([d name])) return YES;
    }
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
        // v1.9.92：走会话快照缓存，burst 内多函数共享一次 mediaserverd 查询
        AVAudioSessionRouteDescription *route = nil;
        NSArray *inputs = nil;
        if (!apv_sessionSnapshot(&route, &inputs)) return NO;
        for (AVAudioSessionPortDescription *p in route.outputs) {
            if (isAirPodsName(p.portName)) return YES;
        }
        for (AVAudioSessionPortDescription *p in inputs) {
            if (isAirPodsName(p.portName)) return YES;
        }
    } @catch (id e) {}
    return NO;
}

// 静音开关状态（SBSoundDefaults 域，iOS16 实机验证返回值随开关实时翻转）
// 摘下耳机"强制 100"的通知音必须跳过静音模式：静音时不允许把 Ringtone/Alert 拉回 100
// v1.9.92：0.5s TTL 缓存——这个函数在 getVolume hook 热路径里
// （每次音量读取都可能调），SBSoundDefaults 每次新建调用有开销；静音开关
// 物理拨动的响应延迟 0.5s 无感知。
static BOOL sRingerMutedCache = NO;
static NSTimeInterval sRingerMutedAt = -1e9;
static BOOL isRingerMuted(void) {
    NSTimeInterval now = apv_now();
    if (now - sRingerMutedAt < 0.5) return sRingerMutedCache;
    @try {
        Class cls = NSClassFromString(@"SBSoundDefaults");
        if (!cls) { sRingerMutedCache = NO; }
        else {
            id sbsd = [cls standardDefaults];
            if (!sbsd || ![sbsd respondsToSelector:@selector(isRingerMuted)])
                sRingerMutedCache = NO;
            else
                sRingerMutedCache = (BOOL)[sbsd isRingerMuted];
        }
    } @catch (id e) {
        sRingerMutedCache = NO;
    }
    sRingerMutedAt = now;
    return sRingerMutedCache;
}

static float capForCategory(id cat) {
    if (!sAirPodsConnected) return 1.0f;
    if (isNotificationCategory(cat)) return apv_notifyCap();
    return 1.0f; // v1.9.75: 媒体音量完全不管（系统自管理已验证正常）
}

// ============================================================
// SBVolumeControl: block hardware volume buttons
// ============================================================

%hook SBVolumeControl
- (BOOL)increaseVolume {
    // v1.9.75 定案：戴 AirPods 时音量键 +/- 全禁（只能控制中心/设置调媒体音量）；
    // 不戴 AirPods 时按钮完全原生（媒体音量随便调）。
    if (sAirPodsConnected) return NO;
    return %orig;
}
- (BOOL)decreaseVolume {
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
    // 开关：设置里"音量条永远小条"；关掉就完全走系统（先大条再转小条）
    // ⚠️ 多参数方法里不能写无参 `%orig;`（Logos 展开会失败，后面全乱套），
    // 必须把参数全部显式写出来。
    if (!gMiniVolumeHUD) {
        %orig(state, bounds, integralized, useSizeSpringData, useCenterSpringData);
        return;
    }
    // 强制 state=2（mini 小条）：永远直接小条，跳过大条过渡
    %orig(2, bounds, integralized, useSizeSpringData, useCenterSpringData);
}
%end

// ============================================================
// AVSystemController: catch CC slider + all volume paths
// ============================================================

// v1.9.80：观察快照专用"绕过 cap"开关（定义在 hook 之前，C 要求先声明后使用）。
// 本文件的 getVolume hook 会改写返回值（戴耳机 Ringtone/Alert 封顶 0.4、摘下
// 通知类伪装 1.0）。诊断快照要读**真值**，若不绕过，戴耳机时 Ringtone/Alert
// 永远只能读到被我们压过的 0.400 假值，排查"到底哪个类别跳 100%"会得出错误结论。
static BOOL gBypassGetCap = NO;

// 读某个类别的**真值**（绕开下面 getVolume hook 的 cap 改写）。
// 凡是需要"先看真实音量、再决定要不要压"的地方，必须走这里。直接调 getVolume
// 拿到的恒是被 cap 过的假值（戴耳机时 Ringtone/Alert 恒为 0.4），会让判断条件
// 永远不成立——v1.9.80 的 [SNAP] 日志实锤了这个 bug（见下方 apv_clampNotifyVolume）。
static BOOL apv_realVolume(id avc, id cat, float *out) {
    gBypassGetCap = YES;
    BOOL r = [avc getVolume:out forCategory:cat];
    gBypassGetCap = NO;
    return r;
}

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    // v1.9.77：摘下时通知音强制 100%（常驻硬需求，静音跳过）；戴上时通知音
    // 按 cap（受「戴耳机限制铃声音量」开关控制，开=0.4 关=1.0）；媒体音量完全不管。
    float vol_orig = vol; // 原始请求值（诊断用：看系统/App 到底想要多少）
    float cap = capForCategory(cat);
    if (!sAirPodsConnected && isNotificationCategory(cat) && !isRingerMuted())
        vol = 1.0f;
    else if (cap < 1.0f)
        vol = MIN(vol, cap);
    if (gVolDiag) {
        volLog([NSString stringWithFormat:
            @"setVolumeTo cat=%@ req=%.3f -> %.3f (cap=%.2f conn=%d)%@",
            cat, vol_orig, vol, cap, sAirPodsConnected, volStack(6)]);
    }
    return %orig(vol, cat);
}
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)cat {
    if (!sAirPodsConnected && isNotificationCategory(cat) && !isRingerMuted())
        return [self setVolumeTo:1.0f forCategory:cat];
    float cap = capForCategory(cat);
    if (cap >= 1.0f) return %orig;
    float cur;
    // v1.9.81：读真值判断。用被 cap 过的假值会让 delta 判断失真。
    if (apv_realVolume(self, cat, &cur) && (cur + delta) > cap) {
        if (cur >= cap) return YES;
        return [self setVolumeTo:cap forCategory:cat];
    }
    return %orig;
}
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig(vol, cat);
    if (r && !gBypassGetCap) { // v1.9.80：gBypassGetCap 时直返真值，不做 cap 改写
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
    // 开关：设置里"音量条禁用触摸"
    if (gDisableHUDTouch) view.userInteractionEnabled = NO;
    %orig;
}
%end

@interface SBElasticVolumeSliderView : UIView
@end
%hook SBElasticVolumeSliderView
- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    if (gDisableHUDTouch) self.userInteractionEnabled = NO;
    return self;
}
%end

// ============================================================
// Hide replaykit CC modules
// ============================================================

%hook NSBundle
- (Class)principalClass {
    // 开关：设置里"隐藏视频通话重复模块"
    if (!gHideReplayKit) return %orig;
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

// ============================================================
// 日志系统（v1.9.58 重构，老板要求）
//
// **全部日志由设置里那一个开关「诊断日志」控制**（gVolDiag），不再有
// 独立的编译期宏。开 = 全开，关 = 一个字节都不写。
// 全部写进同一个日志文件（v1.9.93 起固定路径，详见 apvLogPath 注释）：
//   /var/mobile/Documents/airpods_vol.log（兜底 /var/mobile/ → /var/tmp/）
// 历史：v1.9.90 曾用"探测 /var/jb 是否存在"区分 rootless/roothide，但 Relaxin
// 上 /var/jb 是指向 / 的 symlink → 恒判成 rootless → 落到 /var/jb/tmp == /tmp，
// SpringBoard 沙盒写不进去，日志一行都没有。故改为固定 /var/mobile 真实路径。
//
// 三档频率（老板要求：刷屏的降频，音量的盯紧）：
//   [VOL]   音量重点日志 —— **不限流**，每次音量设置全记（类别/请求值/
//           实际值/是否被封顶/调用栈），只对"完全相同且 1s 内重复"去重。
//   [ROUTE] 路由事件日志 —— 中等。路由事件本身高频，同类消息 5s 一条。
//   [CC]    控制中心模块 —— 低频。下拉一次控制中心会刷 6 条同样的
//           "nowplaying -> 1x1"，同类消息 30s 一条。
//
// 关掉开关时：三个函数都在第一行 return，连字符串都不拼，零开销。
// ============================================================

// v1.9.93：日志路径**固定**，不再探测。
//
// ⚠️ 为什么不能用探测（隐根 Relaxin 实机翻车）：
//   1) Relaxin 上 **/var/jb 是一个指向 / 的 symlink**（为兼容 rootless 建的），
//      fileExistsAtPath(@"/var/jb") 恒为真 → v1.9.90 的"有 /var/jb 就是 rootless"
//      探测在这里 100% 误判，日志路径算成 /var/jb/tmp == /tmp，SpringBoard 沙盒
//      写不进去 → 一行日志都没有（排查时完全找不到记录）。
//   2) roothide 系是**隐根**：越狱根目录每次重启都会换随机目录名
//      （/var/containers/Bundle/Application/.jbroot-<RANDOM>/usr/lib/TweakInject），
//      任何基于越狱根推导的绝对路径都不稳定。
//
// 定案（老板约定，长期遵守）：
//   · hook 用户 App 的插件 → 写用户沙盒 NSHomeDirectory()/Documents/...
//   · hook SpringBoard 的插件 → 写 /var/mobile/Documents/...（真实路径，
//     不随 jbroot 随机串变化，SpringBoard 沙盒有写权限）
// 本插件只注入 SpringBoard，故首选 /var/mobile/Documents/airpods_vol.log。
//
// v1.9.94：探测方式从「看目录权限位」改成「真 fopen 试写」。
//   isWritableFileAtPath: 只看 DAC 权限位，**看不到沙盒/MACF 的实际裁决**：
//   目录权限位写着可写、SpringBoard 真 fopen 却被拒，探测照样判成功 →
//   又回到"以为在写、其实一行没有"的老坑。故逐个候选 mkdir -p 后真的
//   fopen("a") 一次，打开成功才算这个候选可用。
// 另外：选中路径会缓存（记住成功路径，避免每条日志都探测）；一旦实际写入
// 失败（目录被清 / 沙盒策略变了），作废缓存，下一条日志重新探测降级。
// 最终落点同步写一份 airpods_vol.path 标记文件，SSH 一眼能找到日志在哪。
static NSString * volatile gLogPathChosen = nil;
static os_unfair_lock sLogPathLock = OS_UNFAIR_LOCK_INIT;
#define APV_LOG_MARKER @"/var/mobile/Documents/airpods_vol.path"

// 逐个候选：mkdir -p → 真 fopen("a") 试写 → 成功即采纳
static NSString *apv_probeLogPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cands = @[@"/var/mobile/Documents/airpods_vol.log",
                       @"/var/mobile/Library/airpods_vol.log",
                       @"/var/mobile/airpods_vol.log",
                       @"/var/tmp/airpods_vol.log"];
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        FILE *t = fopen([p UTF8String], "a");
        if (t) { fclose(t); return p; }
    }
    return nil; // 全挂（极端情况）→ 静默不写，绝不崩
}

static NSString *apvLogPath(void) {
    NSString *p = gLogPathChosen;
    if (p) return p;                       // 快路径：已探到过，无锁
    os_unfair_lock_lock(&sLogPathLock);
    p = gLogPathChosen;
    if (!p) {
        p = apv_probeLogPath();
        gLogPathChosen = p;
        if (p) {
            // 把最终落点写一份标记文件，SSH 直接 cat 它就知道日志在哪
            [[NSString stringWithFormat:@"%@\n", p] writeToFile:APV_LOG_MARKER
                                                      atomically:YES
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
        }
    }
    os_unfair_lock_unlock(&sLogPathLock);
    return p;
}

// 写入失败时调用：作废缓存，下次重新探测（落点被清 / 沙盒策略变了都能自愈）
static void apvInvalidateLogPath(void) {
    os_unfair_lock_lock(&sLogPathLock);
    gLogPathChosen = nil;
    os_unfair_lock_unlock(&sLogPathLock);
}

// 节流：同一个 key 在 interval 秒内只放行一次（返回 NO = 抑制）
// v1.9.92：加 os_unfair_lock——volLog 可能从任意线程（音量调用方）、
// routeLog/ccLog 从主线程和后台装载队列同时进来，裸 NSMutableDictionary
// 并发读写有崩溃风险。锁只保护字典查找，纳秒级。
static os_unfair_lock sThrottleLock = OS_UNFAIR_LOCK_INIT;
static BOOL apv_throttle(NSString *key, NSTimeInterval interval) {
    static NSMutableDictionary *last = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ last = [[NSMutableDictionary alloc] init]; });
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    os_unfair_lock_lock(&sThrottleLock);
    NSNumber *prev = [last objectForKey:key];
    BOOL allow = YES;
    if (prev && (now - [prev doubleValue]) < interval) {
        allow = NO;
    } else {
        [last setObject:[NSNumber numberWithDouble:now] forKey:key];
    }
    os_unfair_lock_unlock(&sThrottleLock);
    return allow;
}

// v1.9.92：写盘移出调用线程——routeLog 在主线程路由事件里跑，此前每次
// fopen/fprintf/fclose 同步磁盘 IO 都压在主线程上（开诊断日志时）。
// 现在字符串在调用线程拼好（纯内存），实际写盘丢专用串行队列：
// 主线程零磁盘 IO；串行队列保证日志行序与提交顺序一致。
static dispatch_queue_t apv_log_queue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huhansibuxin.airpodsvolume.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// v1.9.96：force=YES 是「装载/探针」专用通道（[SYS] 标签）。
// 它回答的是"hook 到底挂没挂上、挂上后有没有被触发"——排查的第一证据，
// 不能因为「诊断日志」开关没开就一行都看不到（v1.9.82 之前的 airpods_boot.log
// 就是不受门控的，那是当年唯一能确认 hook 生效的手段）。
// 量极小且一次性：装载结果 + 每个探针首次命中 + 启动/5s/30s 三次汇总，
// 之后全部走 30s 限流；不进任何热路径，不影响性能。
static void apvWriteEx(NSString *tag, NSString *msg, NSTimeInterval throttle, BOOL force) {
    if (!force && !gVolDiag) return;
    if (throttle > 0.0 && !apv_throttle(msg, throttle)) return;
    NSString *ts = [[NSDate date] description]; // 时间戳在提交时刻取，保序
    dispatch_async(apv_log_queue(), ^{
        // v1.9.94：打开失败 → 落点已失效，作废缓存重新探测一次再试
        NSString *p = apvLogPath();
        FILE *f = p ? fopen([p UTF8String], "a") : NULL;
        if (!f) {
            apvInvalidateLogPath();
            p = apvLogPath();
            if (!p) return;
            f = fopen([p UTF8String], "a");
            if (!f) return;
        }
        fprintf(f, "[%s] %s %s\n", [ts UTF8String], [tag UTF8String], [msg UTF8String]);
        fclose(f);
    });
}

static void apvWrite(NSString *tag, NSString *msg, NSTimeInterval throttle) {
    apvWriteEx(tag, msg, throttle, NO);
}

// 音量重点日志：**盯紧**，只做 1s 内完全相同消息的去重
static void volLog(NSString *msg)   { apvWrite(@"[VOL]", msg, 1.0); }
// 路由事件日志：同类 5s 一条
static void routeLogImpl(NSString *msg) { apvWrite(@"[ROUTE]", msg, 5.0); }
// 控制中心模块日志：同类 30s 一条（下拉控制中心会连刷 6 条一样的）
static void ccLog(NSString *msg)    { apvWrite(@"[CC]", msg, 30.0); }

// ============================================================
// v1.9.82：v1.9.79~1.9.81 的 [OBS]/[SNAP] 观察探针已全部移除。
// 它们的使命（实锤"respring 后首次来电 100% 是 Ringtone 真值没被压"）已完成，
// 修复落在 apv_clampNotifyVolume（读真值再压）与 gBypassGetCap 机制。
// 诊断日志统一受「诊断日志」开关（gVolDiag）门控：关闭后一行都不写。
// ============================================================

// v1.9.82：装载日志并入主日志，受「诊断日志」开关门控（关闭一行都不写）。
// 历史用途是"诊断关也能确认 hook 是否真生效"（独立文件 airpods_boot.log）；
// 现在诊断开时 [BOOT] 与其余日志同文件可见，无需再单独开文件。
static void apvBootLog(NSString *msg) { apvWrite(@"[BOOT]", msg, 0.0); }

// 调用栈前 N 帧（只在开诊断时才调用，别放进热路径）
static NSString *volStack(NSUInteger n) {
    NSArray *syms = [NSThread callStackSymbols];
    NSMutableString *ms = [NSMutableString string];
    NSUInteger max = MIN(n, syms.count);
    for (NSUInteger i = 1; i < max; i++) { // 跳过 volStack 自己
        NSString *line = syms[i];
        // 只留形如 "0x... + 帧偏移" 之前的部分，砍掉超长地址
        NSRange r = [line rangeOfString:@" 0x"];
        if (r.location != NSNotFound) line = [line substringToIndex:r.location];
        [ms appendFormat:@"\n      %@", line];
    }
    return ms;
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
    // 开关：设置里"音乐模块压缩成 1×1"
    if (!gShrinkNowPlaying) {
        ccLog(@"设置已关闭 shrinkNowPlayingCCModule，不装 1×1 hook");
        return;
    }
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
// 控制中心 1×1 音乐模块：内部布局调整
// 隐藏上一首/下一首 + 隐藏副标题 + 放大播放键
// ============================================================
// hook 点来自逆向 BetterCC 0.0.55（Ghidra 反编译 + 方法名静态提取）：
//   MRUNowPlayingControlsView          -layoutSubviews → 调整内部子视图位置
//   MRUNowPlayingTransportControlsView -layoutSubviews → leftButton/rightButton alpha 归零
//   MRUNowPlayingLabelView             -layoutSubviews → 隐藏第 2 个及以后的 UILabel
// BetterCC 在 _mediaPortraitSize==1 的分支就是"左右按钮 alpha=0，只留 middleButton"。
// ⚠️ 判断"是否 1×1 格子"**不能用 layout 属性**——实测它在全屏展开态
// 也返回 0，照它判断会把全屏播放器的上一曲/下一曲一起隐藏掉（老板实测）。
// 改用视图实际宽度：1×1 模块 ≈ 屏宽/4（约 100pt），全屏展开后 ≥ 300pt。
// 只在 1×1 格子里动，长按展开后完全交回系统。
// ============================================================

static void (*origMRUTransportLayout)(id, SEL) = NULL;

// 取属性的 SEL 只解析一次（NSSelectorFromString 在 layoutSubviews 里每次跑是浪费）
static SEL sSelLeft = NULL;
static SEL sSelRight = NULL;

// 1×1 格子判定：宽度落在 (1, 160) 之间
// 实测 1×1 ≈ 96pt，展开态 ≈ 400pt，160 是安全分界线。
static BOOL mru_isCompact(id view) {
    if (![view isKindOfClass:[UIView class]]) return NO;
    CGFloat w = ((UIView *)view).bounds.size.width;
    return (w > 1.0 && w < 160.0);
}

// 精确取属性：只对 self 自己 respondToSelector，不递归遍历整个视图树
static id mru_obj(id view, SEL s) {
    if (!view || !s) return nil;
    if (![view respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(view, s);
}

// 1×1：只把上一曲/下一曲按掉（alpha 0，UIKit 对 alpha<0.01 的视图不做 hit-test，
// 所以点不到，也不会占掉中间的点击区域）。展开态完全归还原生，一个属性都不碰。
static void replMRUTransportLayout(id self, SEL _cmd) {
    if (origMRUTransportLayout) origMRUTransportLayout(self, _cmd);
    @try {
        // 开关关了也要把 alpha 还原回去，否则关不掉
        BOOL want = (gShrinkNowPlaying && gHidePrevNext && mru_isCompact(self));
        CGFloat a = want ? 0.0 : 1.0;
        UIView *l = (UIView *)mru_obj(self, sSelLeft);
        UIView *r = (UIView *)mru_obj(self, sSelRight);
        if (l.alpha != a) { l.alpha = a; l.userInteractionEnabled = !want; }
        if (r.alpha != a) { r.alpha = a; r.userInteractionEnabled = !want; }
    } @catch (NSException *e) {}
}

static void installNowPlayingLayoutTweaks(void) {
    // MRUNowPlaying* 在 MediaRemoteUI 私有框架（系统框架只在 dyld 缓存里）
    dlopen("/System/Library/PrivateFrameworks/MediaRemoteUI.framework/MediaRemoteUI", RTLD_NOW);

    sSelLeft  = NSSelectorFromString(@"leftButton");
    sSelRight = NSSelectorFromString(@"rightButton");

    Class c = NSClassFromString(@"MRUNowPlayingTransportControlsView");
    SEL s = NSSelectorFromString(@"layoutSubviews");
    if (!c) {
        ccLog(@"MRUNowPlayingTransportControlsView 类未找到，跳过");
        return;
    }
    if (![c instancesRespondToSelector:s]) {
        ccLog(@"MRUNowPlayingTransportControlsView 不响应 layoutSubviews，跳过");
        return;
    }
    MSHookMessageEx(c, s, (IMP)replMRUTransportLayout, (IMP *)&origMRUTransportLayout);
    ccLog(@"hook 装载: MRUNowPlayingTransportControlsView -layoutSubviews (1×1 隐藏上一曲/下一曲)");
}

// ============================================================
// 铃声音量滑块（Ring 复刻版，v1.9.69 清理后唯一定位路径）
// Ring 反编译实锤（ring_decompiled.txt:1320-1834）：
//   MediaControlsVolumeRingerSliderView 是 Ring 自写的 UIView 子类，不是系统类！
//   它的"原生观感"来自系统同款毛玻璃材质 MTMaterialView（MaterialKit.framework）：
//     背景视图 = [MTMaterialView materialViewWithRecipe:4 options:0]（垫底）
//     填充视图 = [MTMaterialView materialViewWithRecipe:0 options:0] + 白色底色，
//                从底部向上填充（高度 = value * bounds.height，动画过渡）
//     容器     = cornerCurve=continuous + cornerRadius=42 + clipsToBounds
//   setCurrentValue: 内部直接写 AVSystemController Ringtone。
//   左边 primarySlider 内部同为 MTMaterialView 体系 → 两边观感天然一致。
// （2026-08-31 实机验证：MTMaterialView 在 iOS16 SpringBoard 必可用，
//   旧的 APVRingerSliderView 自绘降级类已删——永远走不到的代码就是冗余）
// ============================================================

static void apv_setRingerVolume(float vol);  // 定义在下方，先声明避免 C 编译报错
static BOOL currentOutputIsAirPods(void);    // 同样在下方定义
static void apv_ringerApplyValue(UIView *container, float value);

static const void *kRingerSliderKey  = &kRingerSliderKey;
static const void *kRingerBellKey    = &kRingerBellKey;
static const void *kRingerFillKey    = &kRingerFillKey;
static const void *kRingerHandlerKey = &kRingerHandlerKey;

@interface APVRingerTouchHandler : NSObject
@property (nonatomic, weak) UIView *slider;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation APVRingerTouchHandler
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *slider = self.slider;
    if (!slider) return;
    CGFloat h = slider.bounds.size.height;
    if (h <= 0) return;
    CGPoint loc = [pan locationInView:slider];
    // v1.9.85 起：相对拖动 + 阻尼。原实现是**绝对定位**（value=1-y/h），
    // 滑块矮时手指动一点点音量就涨很多。现改为：
    //   起点 = 按下瞬间的 Ringtone 真值（apv_realVolume 绕开 cap 改写）；
    //   之后 value = 起点 + (按下y - 当前y)/h * 阻尼，更跟手。
    // 阻尼系数（<1 降低灵敏度，改这里即可微调，1.0 = 1:1 跟手）：
    //   v1.9.85 = 0.6（老板嫌太慢）→ v1.9.86 = 0.8
    static float sPanStartVol = -1.0f;
    static CGFloat sPanStartY = 0;
    if (pan.state == UIGestureRecognizerStateBegan) {
        float cur = 0.5f;
        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        if (avc) apv_realVolume(avc, @"Ringtone", &cur);
        sPanStartVol = cur;
        sPanStartY = loc.y;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (sPanStartVol < 0) { sPanStartVol = 0.5f; sPanStartY = loc.y; }
        float dy = (float)(sPanStartY - loc.y); // 上滑为正
        float value = sPanStartVol + dy / h * 0.8f;
        value = fmaxf(0.0f, fminf(1.0f, value));
        // 戴 AirPods 时铃声音量封顶（档位 40%/30%，受开关控制，统一走 apv_notifyCap）
        float cap = currentOutputIsAirPods() ? apv_notifyCap() : 1.0f;
        if (value > cap) value = cap;
        apv_setRingerVolume(value);
        apv_ringerApplyValue(slider, value); // 拖动实时反映填充高度
    }
}
@end

// Ring updateFillLayer 复刻：填充从底部向上，高度 = value * height，动画过渡
// v1.9.92：值与容器尺寸都没变时直接跳过——viewDidLayoutSubviews 在 CC 展开
// 期间每个布局帧都会调，此前每帧都建一个 0.25s 的 UIView 动画事务（CA 事务
// 创建/提交有真实开销）。全局只有这一个滑块实例，一对静态记录即可。
static float sRingerLastFillVal = -1.0f;
static CGRect sRingerLastFillBounds = CGRectZero;
static void apv_ringerApplyValue(UIView *container, float value) {
    @try {
        UIView *fill = objc_getAssociatedObject(container, kRingerFillKey);
        if (!fill) return;
        CGRect b = container.bounds;
        if (b.size.height <= 0) return;
        float cap = currentOutputIsAirPods() ? apv_notifyCap() : 1.0f;
        if (value > cap) value = cap; // 戴耳机显示也封顶（档位 40%/30%，统一走 apv_notifyCap）
        if (fabsf(value - sRingerLastFillVal) < 0.001f &&
            CGRectEqualToRect(b, sRingerLastFillBounds)) return; // 无变化，不建动画
        sRingerLastFillVal = value;
        sRingerLastFillBounds = b;
        CGFloat fillH = b.size.height * (CGFloat)value;
        CGRect nf = CGRectMake(0, b.size.height - fillH, b.size.width, fillH);
        [UIView animateWithDuration:0.25 animations:^{ fill.frame = nf; }];
    } @catch (id e) {}
}

// Ring initWithFrame:minimumValue:cornerRadius: + createFillLayer + createBackgroundView 复刻
static UIView *apv_createRingerSlider(CGRect frame, float value, double cornerRadius) {
    UIView *container = [[UIView alloc] initWithFrame:frame];
    container.backgroundColor = [UIColor clearColor];
    container.layer.cornerRadius = cornerRadius > 0 ? cornerRadius : 42.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.clipsToBounds = YES;
    container.tag = 0xA9B0;
    container.userInteractionEnabled = YES;

    // MTMaterialView（MaterialKit.framework）= 控制中心音量条同款毛玻璃材质
    // iOS16 SpringBoard 实锤必可用；取不到时用普通 UIView 兜底（功能不受影响）
    dlopen("/System/Library/PrivateFrameworks/MaterialKit.framework/MaterialKit", RTLD_NOW);
    Class mtk = NSClassFromString(@"MTMaterialView");
    SEL recipeSel = NSSelectorFromString(@"materialViewWithRecipe:options:");
    UIView *background = nil, *fill = nil;
    if (mtk && [mtk respondsToSelector:recipeSel]) {
        @try {
            background = ((id (*)(id, SEL, long, long))objc_msgSend)(mtk, recipeSel, 4, 0);
            fill       = ((id (*)(id, SEL, long, long))objc_msgSend)(mtk, recipeSel, 0, 0);
        } @catch (id e) {}
    }
    if (!background) background = [[UIView alloc] init];
    if (!fill) fill = [[UIView alloc] init];
    // Ring createFillLayer 分支1：fill 材质 + 白色底色（v1.9.87：老板定稿——
    // 恢复最初版本 white:1.0 alpha:0.90，即 10% 透明；原生滑块颜色会随
    // 材质/亮度自己变，追不齐，就以这版为准不再调）
    fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    UIViewAutoresizing mask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    background.autoresizingMask = mask;
    fill.autoresizingMask = mask;
    background.frame = container.bounds;
    fill.frame = container.bounds; // 马上由 apv_ringerApplyValue 修正
    [container addSubview:background];
    [container addSubview:fill];
    objc_setAssociatedObject(container, kRingerFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    apv_ringerApplyValue(container, value);
    apvBootLog([NSString stringWithFormat:@"铃声音量滑块(Ring复刻)创建完成 cornerRadius=%.1f bg=%@ fill=%@",
                container.layer.cornerRadius, NSStringFromClass([background class]),
                NSStringFromClass([fill class])]);
    return container;
}

// （历史备注：v1.9.62-65 曾走 MRUContinuousSliderView 系统类路线，boot log 实锤
//   该类无任何样式接口无法渲染填充，v1.9.68 起改用上方 Ring 复刻版，旧路已删。）

static float apv_ringerVolume(void) {
    @try {
        Class cls = NSClassFromString(@"AVSystemController");
        if (!cls) return 0.5f;
        id avc = [cls sharedAVSystemController];
        SEL sel = NSSelectorFromString(@"getVolume:forCategory:");
        if (![avc respondsToSelector:sel]) return 0.5f;
        float vol = 0.5f;
        ((BOOL (*)(id, SEL, float *, id))objc_msgSend)(avc, sel, &vol, @"Ringtone");
        return vol;
    } @catch (id e) { return 0.5f; }
}

static void apv_setRingerVolume(float vol) {
    @try {
        Class cls = NSClassFromString(@"AVSystemController");
        if (!cls) return;
        id avc = [cls sharedAVSystemController];
        SEL sel = NSSelectorFromString(@"setVolume:forCategory:");
        if (![avc respondsToSelector:sel]) return;
        ((BOOL (*)(id, SEL, float, id))objc_msgSend)(avc, sel, fmaxf(0.0f, fminf(1.0f, vol)), @"Ringtone");
    } @catch (id e) {}
}

static void (*origMRUVolumeLayout)(id, SEL) = NULL;
static void replMRUVolumeLayout(id self, SEL _cmd) {
    if (origMRUVolumeLayout) origMRUVolumeLayout(self, _cmd);
    if (!gShowRingerSlider) return;

    // 不受诊断门控：确认 hook 真在跑（放在 @try 之前，任何提前 return 都能抓到）
    static BOOL didRingerTopLog = NO;
    if (!didRingerTopLog) {
        didRingerTopLog = YES;
        apvBootLog(@"replMRUVolumeLayout 首次进入（orig 已调用）");
    }

    @try {
        // v1.9.92：SEL 全部静态缓存——viewDidLayoutSubviews 在 CC 展开期间
        // 每个布局帧都进来，NSSelectorFromString 每帧做哈希查找是纯浪费。
        static SEL sSelView = NULL, sSelExpanded = NULL, sSelSlider = NULL, sSelCR = NULL, sSelAsset = NULL;
        static dispatch_once_t onceSel;
        dispatch_once(&onceSel, ^{
            sSelView     = NSSelectorFromString(@"view");
            sSelExpanded = NSSelectorFromString(@"isExpanded");
            sSelSlider   = NSSelectorFromString(@"primarySlider");
            sSelCR       = NSSelectorFromString(@"continuousSliderCornerRadius");
            sSelAsset    = NSSelectorFromString(@"primaryAssetView");
        });
        id view = ((id (*)(id, SEL))objc_msgSend)(self, sSelView);
        if (![view isKindOfClass:[UIView class]]) return;
        UIView *moduleView = (UIView *)view;

        // isExpanded 发在 self.view 上（Ring FUN_00006590 行723：isExpanded(view)）。
        // 先查 view，再退而查 self，双保险；都不响应时按"展开"处理。
        BOOL expanded = YES;
        if ([moduleView respondsToSelector:sSelExpanded]) {
            expanded = ((BOOL (*)(id, SEL))objc_msgSend)(moduleView, sSelExpanded);
        } else if ([self respondsToSelector:sSelExpanded]) {
            expanded = ((BOOL (*)(id, SEL))objc_msgSend)(self, sSelExpanded);
        }

        // ★ primarySlider / secondarySlider 是 self.view 的属性，不是控制器的！
        // 之前错写成 objc_msgSend(self, primarySlider) → 返回 nil → 永远提前 return，
        // 滑块从不创建（Ring FUN_00006590 行744：primarySlider(view)）。
        id slider = nil;
        if ([moduleView respondsToSelector:sSelSlider]) {
            slider = ((id (*)(id, SEL))objc_msgSend)(moduleView, sSelSlider);
        } else if ([self respondsToSelector:sSelSlider]) {
            slider = ((id (*)(id, SEL))objc_msgSend)(self, sSelSlider);
        }
        if (![slider isKindOfClass:[UIView class]]) return;
        UIView *primarySlider = (UIView *)slider;

        // 展开态详细信息（首次进入展开时记一次，不受诊断门控）
        static BOOL didRingerExpandedLog = NO;
        if (expanded && !didRingerExpandedLog) {
            didRingerExpandedLog = YES;
            apvBootLog([NSString stringWithFormat:
                @"replMRUVolumeLayout 展开态: expanded=1 primarySliderCls=%@ viewCls=%@",
                [slider class], [moduleView class]]);
        }

        UIView *ringer = objc_getAssociatedObject(self, kRingerSliderKey);
        UIImageView *bell = objc_getAssociatedObject(self, kRingerBellKey);

        if (!expanded) {
            if (ringer) ringer.hidden = YES;
            if (bell) bell.hidden = YES;
            return;
        }

        CGRect b = moduleView.bounds;
        CGRect sf = primarySlider.frame;
        CGFloat sliderW = sf.size.width;
        CGFloat sliderH = sf.size.height;
        CGFloat sliderY = sf.origin.y;

        // 按 Ring 反编译 layout：两个滑块等宽，左/右/中三段间距相等。
        // gap = (总宽 - 2*sliderW) / 3，左滑块 x=gap，右滑块 x=总宽-gap-sliderW。
        CGFloat gap = (b.size.width - sliderW * 2.0f) / 3.0f;
        if (gap < 4.0f) gap = 4.0f;
        CGFloat leftX  = gap;
        CGFloat rightX = b.size.width - gap - sliderW;

        primarySlider.frame = CGRectMake(leftX, sliderY, sliderW, sliderH);

        if (!ringer) {
            CGRect rFrame = CGRectMake(rightX, sliderY, sliderW, sliderH);
            // 圆角与左边一致（Ring：读 primarySlider.continuousSliderCornerRadius，默认 42）
            double cornerRadius = 42.0;
            if ([primarySlider respondsToSelector:sSelCR]) {
                cornerRadius = ((double (*)(id, SEL))objc_msgSend)(primarySlider, sSelCR);
            }
            ringer = apv_createRingerSlider(rFrame, apv_ringerVolume(), cornerRadius);
            objc_setAssociatedObject(self, kRingerSliderKey, ringer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [moduleView addSubview:ringer];

            // Ring：滑块自己接收触摸。用绝对定位 pan（点哪到哪，比 Ring 的相对拖动直观）
            APVRingerTouchHandler *handler = [[APVRingerTouchHandler alloc] init];
            handler.slider = ringer;
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler
                                                                                  action:@selector(handlePan:)];
            [ringer addGestureRecognizer:pan];
            // 手势 target 引用方式不完全可控，handler 挂关联对象防释放
            objc_setAssociatedObject(ringer, kRingerHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ringer.hidden = NO;
        ringer.frame = CGRectMake(rightX, sliderY, sliderW, sliderH);

        // 同步铃声音量显示（fill 高度跟随实际值；戴耳机 40% 封顶在 applyValue 内处理）
        apv_ringerApplyValue(ringer, apv_ringerVolume());

        if (!bell) {
            UIImage *img = [UIImage systemImageNamed:@"bell.fill"];
            if (!img) {
                // SFSymbols 不可用时的降级：用 UILabel 画一个铃铛符号
                UILabel *fallback = [[UILabel alloc] initWithFrame:CGRectZero];
                fallback.text = @"\U0001F514";
                fallback.textAlignment = NSTextAlignmentCenter;
                fallback.font = [UIFont systemFontOfSize:18];
                fallback.textColor = [UIColor whiteColor];
                objc_setAssociatedObject(self, kRingerBellKey, fallback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [moduleView addSubview:fallback];
                bell = (UIImageView *)fallback;
            } else {
                bell = [[UIImageView alloc] initWithImage:img];
                bell.contentMode = UIViewContentModeScaleAspectFit;
                bell.tintColor = [UIColor whiteColor];
                objc_setAssociatedObject(self, kRingerBellKey, bell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [moduleView addSubview:bell];
            }
            bell.tag = 0xA9B1;
        }
        bell.hidden = NO;

        // 铃铛图标居中于铃声音量滑块上方
        CGFloat bellSize = 22.0f;
        CGFloat bellY = sliderY - bellSize - 6.0f;
        if (bellY < 8.0f) bellY = 8.0f;
        bell.frame = CGRectMake(roundf(rightX + sliderW * 0.5f - bellSize * 0.5f),
                                bellY, bellSize, bellSize);

        // 尝试把顶部 AirPods/扬声器图标也移到左侧滑块上方（如果 view 上有 primaryAssetView）
        if ([moduleView respondsToSelector:sSelAsset]) {
            id asset = ((id (*)(id, SEL))objc_msgSend)(moduleView, sSelAsset);
            if ([asset isKindOfClass:[UIView class]]) {
                UIView *av = (UIView *)asset;
                CGRect af = av.frame;
                av.frame = CGRectMake(roundf(leftX + sliderW * 0.5f - af.size.width * 0.5f),
                                      af.origin.y, af.size.width, af.size.height);
            }
        }
    } @catch (id e) {
        apvBootLog([NSString stringWithFormat:@"replMRUVolumeLayout 异常: %@", e]);
    }
}

static void installRingerSlider(void) {
    // 不受诊断门控：装没装上第一时间可见
    if (!gShowRingerSlider) {
        apvBootLog(@"showRingerSlider 关闭，跳过铃声音量 hook");
        return;
    }
    dlopen("/System/Library/PrivateFrameworks/MediaRemoteUI.framework/MediaRemoteUI", RTLD_NOW);
    Class c = NSClassFromString(@"MRUVolumeViewController");
    if (!c) {
        apvBootLog(@"MRUVolumeViewController 未找到，跳过铃声音量（dlopen MediaRemoteUI 可能失败 / 类未加载）");
        return;
    }
    SEL s = NSSelectorFromString(@"viewDidLayoutSubviews");
    if (![c instancesRespondToSelector:s]) {
        apvBootLog(@"MRUVolumeViewController 不响应 viewDidLayoutSubviews，跳过铃声音量");
        return;
    }
    MSHookMessageEx(c, s, (IMP)replMRUVolumeLayout, (IMP *)&origMRUVolumeLayout);
    apvBootLog(@"hook 装载成功: MRUVolumeViewController -viewDidLayoutSubviews (铃声音量双滑块)");
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
    // 开关：设置里"拦截 Shortcuts 自动化通知"
    if (gBlockShortcuts && isShortcutsRequest(req)) return nil;
    if (origDispatcherPost) return origDispatcherPost(self, _cmd, req);
    return nil;
}

static id replDispatcherModify(id self, SEL _cmd, id req) {
    if (gBlockShortcuts && isShortcutsRequest(req)) return nil;
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
        // 开关：设置里"拦截 AirPods 开盒弹窗"
        if (gBlockPopup) {
            id def = [session definition];
            NSString *svc = [def serviceName];
            NSString *vc = [def viewControllerClassName];
            if (svc && vc &&
                [svc isEqualToString:@"com.apple.SharingViewService"] &&
                [vc isEqualToString:@"SharingViewService.HeadphoneFlowViewController"]) {
                return NO; // 拦截 AirPods 开盒/连接弹窗
            }
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
// ---- 缓存 3：AVOutputContext outputDevices（0.3s）----
// currentOutputIsAirPods / carInSystemOutput 共用。
static NSArray *sCachedOutDevs = nil;
static NSTimeInterval sCachedOutAt = -1e9;
static NSArray *apv_outputDevicesCached(void) {
    NSTimeInterval now = apv_now();
    if (!sCachedOutDevs || (now - sCachedOutAt) >= 0.3) {
        @try {
            id ctx = [NSClassFromString(@"AVOutputContext") sharedSystemAudioContext];
            sCachedOutDevs = [ctx outputDevices] ?: @[];
        } @catch (id e) { sCachedOutDevs = @[]; }
        sCachedOutAt = now;
    }
    return sCachedOutDevs;
}

static BOOL currentOutputIsAirPods(void) {
    NSArray *devs = apv_outputDevicesCached();
    if (devs.count == 0) return NO;
    for (id d in devs) {
        if (!isAirPodsName([d name])) return NO;
    }
    return YES;
}

// 检测 HFP 通话路由是否被车载占用（视频/语音通话场景，2026-08-23 老板实测）：
// 抖音 A2DP 还在 AirPods 放，打微信视频时系统把 HFP 通话路由单独切到车载
//（车载免提优先级）→ currentRoute.outputs 出现"非 AirPods 的 BluetoothHFP 端口"。
// 这是 currentOutputIsAirPods() 看不到的盲区，必须单独检测。
static BOOL carHFPActive(void) {
    @try {
        AVAudioSessionRouteDescription *route = nil;
        NSArray *inputs = nil;
        if (!apv_sessionSnapshot(&route, &inputs)) return NO; // v1.9.92：走快照缓存
        for (AVAudioSessionPortDescription *p in route.outputs) {
            if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
                if (!isAirPodsName(p.portName)) return YES; // HFP 输出不是 AirPods = 车载
            }
        }
    } @catch (id e) {}
    return NO;
}

// 是否正处于蓝牙 HFP 通话（微信视频/语音、系统电话都走这个端口）。
// 只看端口类型，不区分是车载还是 AirPods——只要 BluetoothHFP 端口出现在
// 当前路由里，就是"正在煲电话粥"，音量兜底窗口就该开着。
static BOOL hfpCallActive(void) {
    @try {
        AVAudioSessionRouteDescription *route = nil;
        NSArray *inputs = nil;
        if (!apv_sessionSnapshot(&route, &inputs)) return NO; // v1.9.92：走快照缓存
        for (AVAudioSessionPortDescription *p in route.outputs)
            if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) return YES;
        // ⚠️ 必须用 route.inputs（当前路由的输入端口），不是 availableInputs
        // （所有可用输入）——语义不同，用错会把"仅可用未激活"误判成通话中
        for (AVAudioSessionPortDescription *p in route.inputs)
            if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) return YES;
    } @catch (id e) {}
    return NO;
}

// ---- HFP 通话路由综合检测（车载抢通话，2026-08-23 老板实测）----
// 蓝牙耳机同时有 A2DP(媒体)+HFP(通话)两个端口；视频/语音通话时系统把 HFP
// 单独切到车载（车载免提优先），而 A2DP 媒体可能还在 AirPods（抖音在放）。
// 以下多个角度判断是否"车载正占用通话路由"，任一为真即视为车载抢了通话。

// 是否有"非 AirPods 的蓝牙设备"已连接（车载/其他蓝牙）→ 车模式判定用
static BOOL otherBTDeviceConnected(void) {
    for (id d in apv_btDevicesCached()) { // v1.9.92：走蓝牙列表缓存
        NSString *nm = [d name];
        if (nm && !isAirPodsName(nm)) return YES;
    }
    return NO;
}

// 系统输出设备列表里是否有"已连的非 AirPods 蓝牙设备"成为当前输出（车载 HFP 通话输出）
// 交叉比对蓝牙列表里的非 AirPods 已连设备名与系统当前输出设备名——避免误判内置喇叭
static BOOL carInSystemOutput(void) {
    @try {
        NSMutableSet *carNames = [NSMutableSet set];
        for (id d in apv_btDevicesCached()) { // v1.9.92：走蓝牙列表缓存
            NSString *nm = [d name];
            if (nm && !isAirPodsName(nm)) [carNames addObject:nm];
        }
        if (carNames.count == 0) return NO; // 没有非 AirPods 蓝牙设备 → 不可能被车载抢
        for (id d in apv_outputDevicesCached()) { // v1.9.92：走输出设备缓存
            NSString *nm = [d name];
            if (nm && [carNames containsObject:nm]) return YES; // 车载设备已成为当前系统输出
        }
    } @catch (id e) {}
    return NO;
}

// 通话输入是否被车载占用（currentRoute.inputs 出现非 AirPods 的 BluetoothHFP）
static BOOL carHFPInputActive(void) {
    @try {
        AVAudioSessionRouteDescription *route = nil;
        NSArray *inputs = nil;
        if (!apv_sessionSnapshot(&route, &inputs)) return NO; // v1.9.92：走快照缓存
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

// 路由事件日志
// v1.9.50 起生产静默（空函数体），v1.9.58 恢复：改由设置里那一个「诊断日志」
// 开关控制，写同一个文件，同类消息 5s 一条。
// ⚠️ 调试基准 = v1.9.46（19dd6db，日志开启）
static void routeLog(NSString *msg) {
    routeLogImpl(msg);
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
            // v1.9.95：0.6s 后复查**单次抢回成败**——pickRoute 返回 ok=1 ≠ 真切过去
            //（系统假答应），此前只查 HFP（hfpAfter0.6）是盲区：老板实测"开头几次
            // 好像没抢成功"无法从日志判定。现在 outAP=1 才是真成功，outAP=0 = 假答应。
            // 复查自动拿新值：session 快照 TTL 0.4s / outputDevices TTL 0.3s 均 < 0.6s。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                routeLog([NSString stringWithFormat:@"mpav-force(%s) verify0.6 outAP=%d hfp=%d",
                          why ? why : "?", currentOutputIsAirPods(), carHFPActive()]);
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
            // v1.9.95：补上成败日志 + 0.6s 后复查——此前车载 HFP 抢回**完全静默**
            //（一行日志都没有），老板没法确认抢回是否真成功。carOwnsCall 三路
            // 检测（HFP 输出/输入端口/系统输出）走 0.4s/0.3s TTL 缓存，0.6s 后
            // 复查自动拿新值：carOwns=0 = 车载已放手 = 抢回成功。
            BOOL ok = [sMPARouter pickRoute:airRoute];
            routeLog([NSString stringWithFormat:@"call-force ok=%d carBefore=%d", ok, carOwnsCall()]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                routeLog([NSString stringWithFormat:@"call-force verify0.6 carOwns=%d", carOwnsCall()]);
            });
        } else {
            // 列表还没刷新出来（实例刚建）：0.4s 后重试一次，再不行靠车模式轮询兜底
            routeLog(@"call-force no-route-yet");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (carOwnsCall()) {
                    NSArray *r2 = [sMPARouter availableRoutes];
                    for (id r in r2) {
                        if (isAirPodsName([r routeName])) {
                            BOOL ok2 = [sMPARouter pickRoute:r];
                            routeLog([NSString stringWithFormat:@"call-force retry ok=%d", ok2]);
                            break;
                        }
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

// ============================================================
// 通话期间媒体音量兜底压制（v1.9.57，老板实测问题修复）
//
// 现象：戴 AirPods 听抖音 → 打微信视频，媒体音量弹到 100%；
//       手动调低后有时能回到 70，有时又弹回 100。
//
// 根因：系统/微信在通话建立时设音量走的是 **MediaRemote 路径**，
//   那条路根本不经过 AVSystemController -setVolumeTo:forCategory:
//   ——而我们唯一的封顶 (capForCategory) 就挂在那一个方法上。
//   所以通话那一刻的 100% 我们**完全拦不住**（代码注释里早就写着
//   "控制中心滑动条走 MediaRemote 路径不经此 hook"，同一个盲区）。
//
// 旧兜底为什么时灵时不灵：原来靠"路由事件后 5s 复查"，判断是否要压用
//   `[avc getVolume:&mv ...] && mv > 0.7f`。但无播放会话时 getVolume
//   返回的是**缓存假值 0.70**，`> 0.7` 恒为假 → 明明实际是 100 也压不动。
//   这就是老板说的"两次压回来了、两次没有"。
//
// 修法：通话期间（HFP 端口在场）开 2s 兜底窗口，**无条件**把
//   Audio/Video 压到 70%、Ringtone/Alert 压到 40%——不看 getVolume 的
//   读数，绕开假值问题。压之前判过"输出确实是 AirPods"，所以不会
//   污染喇叭的音量记忆（摘下后系统照常恢复喇叭记忆值）。
//   通话结束 12s 后自动停表，平时零轮询。
// ============================================================

// ============================================================
// v1.9.75 定案（老板实测驱动）：媒体音量完全不管。
//   v1.9.74 零干预实测：微信来视频/挂断时 MediaPlaybackVolume 全程纹丝不动（0.700），
//   系统三个音量（通知/媒体播放/通话）各自记忆、自管理完全正常。
//   MRMediaRemoteSetMediaPlaybackVolume 一调必崩（PAC，v1.9.73 安全模式实锤），
//   AVSystemController setVolumeTo 压媒体又干扰系统记忆 → 媒体压制整体移除。
//   保留：戴 AirPods 时音量键禁用（SBVolumeControl hook）+ 铃声/通知 40% 压制。
// ============================================================

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
        // 设置开关：三个路由功能全都关掉时完全不介入
        if (!gAutoRoute && !gStealBack && !gStealHFP) return;

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

        // v1.9.62：HFP 通话（微信视频/语音）期间，只处理 HFP 路由抢回，
        // 不碰 A2DP 媒体路由，避免 pickRoute/MPAV 操作干扰通话音频。
        BOOL hfpNow = hfpCallActive();
        if (hfpNow) {
            if (gStealHFP && carOwnsCall()) {
                routeLog(@"enforce carOwnsCall=1 (HFP call active) -> forceCallToAirPods");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    forceCallToAirPods();
                });
                startPollWindow();
            }
            // 仍更新输出状态，避免挂断后状态机依据过时的 wasAP 做错误判定
            sOutputWasAirPods = currentOutputIsAirPods();
            return;
        }

        BOOL outIsAP = currentOutputIsAirPods();
        BOOL wasAP = sOutputWasAirPods;
        sOutputWasAirPods = outIsAP;
        if (outIsAP) {
            // 输出已是 AirPods（系统切的）：仅当刚变成时我们也 attached 切一次（幂等）
            // 开关：autoRouteToAirPods
            if (!wasAP && gAutoRoute) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    forceRouteToAirPods("attached");
                });
            }
        } else {
            // 输出非 AirPods：上次输出是 AirPods（被切走）→ stolen（3s 冷却）；
            // 上次输出非 AirPods（戴上/刚连）→ attached（免冷却必切）
            // 开关：被抢走 → stealBackFromCar；刚连上 → autoRouteToAirPods
            const char *why = wasAP ? "stolen" : "attached";
            BOOL allow = wasAP ? gStealBack : gAutoRoute;
            if (allow) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    forceRouteToAirPods(why);
                });
                // 被抢/戴上需要切 → 重启 1 分钟轮询窗口（车载再开、系统抖动都能兜底；
                // 系统稳定后窗口到期自动停，平时零轮询）
                startPollWindow();
            }
        }
        // ⚠️ HFP 通话路由盲区（2026-08-23 老板实测）：视频/语音通话时系统把
        // HFP 通话路由单独切到车载（车载免提优先），而 A2DP 媒体输出可能还在
        // AirPods（抖音在放）→ 上面 outIsAP=YES 误判"输出是 AirPods"不抢。
    } @catch (id e) {}
}

static int sLastEvtState = -1; // 日志限流：AirPods 在场状态 0/1，变化才写日志

// ============================================================
// v1.9.81：把通知音(Ringtone/Alert)主动压到 cap（戴耳机且开关开时 = 0.4）。
//
// ⚠️ 修的是 v1.9.80 [SNAP] 日志实锤的 bug：
//   老代码 `if ([avc getVolume:&cur ...] && cur > 0.4f)` 读的是**被自己 hook cap 过的
//   假值**（戴耳机时恒为 0.4）→ 条件永远为假 → **这段压制逻辑从来没执行过一次**。
//   后果：respring 后 Ringtone 真值一直晾在 1.000，直到用户手动滑一次音量条走
//   setVolumeTo 才被 cap 成 0.4 —— 这正是老板观察到的"respring 后第一次来电
//   音量条显示 100%，手动滑一下变 40%，之后来电都不再跳"。
//   （讽刺的是老代码注释早已写明"getVolume 被 hook 也会 cap 到 0.4"，但没照它实现。）
//
// 实测数据（v1.9.80）：戴上+1.0s 与开机+10s 时 Ringtone=1.000 Alert=1.000 纹丝不动，
// 挂断+0.8s（手动滑过）才变 0.400，第二次来电起稳定 0.400。
//
// 修法：用 apv_realVolume 绕开 hook 读真值再判断；cap 统一取 capForCategory，
// 开关关闭/摘下时 cap=1.0 自动跳过。
// ============================================================
static void apv_clampNotifyVolume(id avc) {
    if (!avc) return;
    @try {
        float capR = capForCategory(@"Ringtone");
        float capA = capForCategory(@"Alert");
        if (capR >= 1.0f && capA >= 1.0f) return; // 摘下 / 开关关闭 → 不压
        float curR = 0.0f, curA = 0.0f;
        BOOL hasR = apv_realVolume(avc, @"Ringtone", &curR);
        BOOL hasA = apv_realVolume(avc, @"Alert", &curA);
        if (hasR && capR < 1.0f && curR > capR) [avc setVolumeTo:capR forCategory:@"Ringtone"];
        if (hasA && capA < 1.0f && curA > capA) [avc setVolumeTo:capA forCategory:@"Alert"];
    } @catch (id e) {}
}

static void handleRouteEvent(NSString *source) {
    @try {
        // v1.9.92：事件时刻强制取新鲜值——缓存只用于吸收 burst 内的重复查询
        apv_invalidateSessionCache();
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
            // v1.9.81：戴上时铃声/通知限 40%（受「戴耳机限制铃声音量」开关控制，默认开）。
            // 老代码在这里读 getVolume 的**假值**判断，导致这段压制从未生效过
            // （详见 apv_clampNotifyVolume 注释）。现改为内部读真值。
            apv_clampNotifyVolume(avc);
            // v1.9.75：媒体音量完全不管——系统对每个输出设备独立记忆音量，
            // 微信来视频/挂断时 MediaPlaybackVolume 自管理正常（v1.9.74 零干预实测 0.700 纹丝不动）。
        } else {
            // 摘下 AirPods（不管车载是否还在）：强制恢复通知音 100%（常驻硬需求，不受开关影响），静音模式下不强制
            if (!isRingerMuted()) {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
            // 摘下媒体音量：不碰——iOS 为每个输出设备独立记忆音量，
            // 输出切回喇叭时系统自动恢复喇叭记忆音量（老板实测手动点喇叭
            // 会自动回到戴前值 93）。之前主动 setVolumeTo 反而覆盖了系统恢复。
        }
        enforceAirPodsRoute();
    } @catch (id e) {
        routeLog([NSString stringWithFormat:@"evt(%@) EXC %@", source, e]);
    }
}

// v1.9.92：事件合并去抖——outputdev 通知在连接抖动/开盒瞬间每秒连发多次，
// 每次全量检测（会话快照 + 蓝牙列表 + 输出设备 + 压制 + 路由决策）都在主线程。
// 100ms 窗口内的 burst 合并成一次跑（戴上必切延迟 100ms 无感知，功能时序不变）。
static BOOL sRouteEvtPending = NO;
static void handleRouteEventDebounced(void) {
    if (sRouteEvtPending) return;
    sRouteEvtPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sRouteEvtPending = NO;
        handleRouteEvent(@"coalesced");
    });
}
// ============================================================
// 通知合并成一组（源出 NotifsDontHide Feature 1，v1.9.91 并入）
// ============================================================
// 只并入 NDH 的「多条通知合并成一栏」功能；其「通知不隐藏」(Feature 2)
// 不并入（独立仓库保留维护；且两包不可同装——同一批方法会被双重 hook）。
//
// 机制（iOS 16，NDH 实机验证）：
//  1) NCNotificationRequest.threadIdentifier → 返回 sectionIdentifier：
//     同一 App 的所有通知强制归入同一 thread，系统把它们视为一组可折叠集合
//  2) NCNotificationCollapsingQueue.collapsingThreshold：系统默认 4
//     （第 5 条才折叠成一栏）→ 改为 1（第 2 条起合并）
//  3) NCNotificationStructuredSectionList.dynamicGroupingThreshold：
//     iOS 16 备用杠杆，同步改阈值
//
// 开关 notifGroupFrom3（hook 内实时读 gNotifGroupFrom3，kAPVChanged 即时生效，免注销）：
//   关（默认）→ 第 2 条通知起合并成一栏（NDH 原行为）
//   开        → 第 3 条通知起才合并（少弹几条再折叠，没那么激进）

static NSUInteger apv_ndh_collapseThreshold(void) {
    return gNotifGroupFrom3 ? 2 : 1;
}

// NDH 同款安全装载：类/方法存在才 hook，静默跳过（未来 iOS 变化不会崩 SpringBoard）
static void apv_ndh_try_hook(const char *clsName, SEL sel, IMP imp, IMP *orig) {
    Class cls = objc_getClass(clsName);
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    MSHookMessageEx(cls, sel, imp, orig);
}

// 1) 同 App 通知归入同一 thread => 一组
// v1.9.92：sectionIdentifier 支持性是类级事实，缓存一次（每条通知都进这里）
static id (*orig_ndh_threadIdentifier)(id, SEL);
static id hook_ndh_threadIdentifier(id self, SEL _cmd) {
    static NSInteger sSupport = 0; // 0=未查 1=支持 -1=不支持
    if (sSupport == 0) sSupport = [self respondsToSelector:@selector(sectionIdentifier)] ? 1 : -1;
    if (sSupport == 1) {
        return ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier));
    }
    return orig_ndh_threadIdentifier(self, _cmd);
}
// 2) 折叠队列阈值：默认 4 → 1（第 2 条合并）/ 2（第 3 条合并）
static NSUInteger (*orig_ndh_collapsingThreshold)(id, SEL);
static NSUInteger hook_ndh_collapsingThreshold(id self, SEL _cmd) {
    return apv_ndh_collapseThreshold();
}
// 3) 备用杠杆：分区列表动态分组阈值
static NSUInteger (*orig_ndh_dynamicGroupingThreshold)(id, SEL);
static NSUInteger hook_ndh_dynamicGroupingThreshold(id self, SEL _cmd) {
    return apv_ndh_collapseThreshold();
}

static void installNotifGrouping(void) {
    apv_ndh_try_hook("NCNotificationRequest", @selector(threadIdentifier),
                     (IMP)&hook_ndh_threadIdentifier, (IMP *)&orig_ndh_threadIdentifier);
    apv_ndh_try_hook("NCNotificationCollapsingQueue", @selector(collapsingThreshold),
                     (IMP)&hook_ndh_collapsingThreshold, (IMP *)&orig_ndh_collapsingThreshold);
    apv_ndh_try_hook("NCNotificationStructuredSectionList", @selector(dynamicGroupingThreshold),
                     (IMP)&hook_ndh_dynamicGroupingThreshold, (IMP *)&orig_ndh_dynamicGroupingThreshold);
}

// ============================================================
// v1.9.96：SystemX（包名 SystemBox）五功能移植
//   ① APP 运行指示点   runIndicatorEnabled + runIndicatorColor
//   ② 注销不锁屏       noLockAfterRespring
//   ③ 连接 VPN 变色    colorizeVPNStatusBar + vpnStatusBarColor
//   ④ 禁用桌面长按     disableHomeScreenLongPress
//   ⑤ 禁用 VPN 飞入    hideVPNFlyInAnimation
//
// hook 点来源：SystemBox.dylib 反编译（451 个 selref）与本设备 SpringBoard
// 运行时 dump 交叉核对。装载方式与 NDH 一致——类/方法存在才 hook，缺失静默
// 跳过（将来 iOS 改版不会连累 SpringBoard）。装载结果与命中情况写 [SYS] 日志，
// 受「诊断日志」总开关门控。全部功能默认关闭。
// ============================================================

// 走 force 通道：不受「诊断日志」开关门控，装没装上永远有据可查
static void sysLog(NSString *msg) { apvWriteEx(@"[SYS]", msg, 30.0, YES); }

// ------------------------------------------------------------
// 探针：把「没装载」和「装了但从没被触发」区分开
//   · 装载失败 → 类/方法在这个 iOS 版本上不存在，得换 hook 点
//   · 装载成功但命中 0 → hook 点选错了（方法存在但系统根本不走它）
// 两种情况修法完全不同，日志里必须一眼分得清。
// ------------------------------------------------------------
enum {
    kProbeIconLayout = 0, // SBIconView layoutSubviews（指示点绘制入口）
    kProbeAppProcess,     // SBApplication _updateProcess:withState:（APP 启停事件）
    kProbeSetUILocked,    // SBLockScreenManager _setUILocked:
    kProbeLockFromSource, // SBLockScreenManager lockUIFromSource:withOptions:
    kProbeVPNApply,       // _UIStatusBarIndicatorVPNItem applyUpdate:toDisplayItem:
    kProbeVPNAddAnim,     // ...additionAnimationForDisplayItemWithIdentifier:
    kProbeLongPress,      // SBIconView editingModeGestureRecognizerDidFire:
    kProbeLongPressMgr,   // SBHIconManager iconView:editingModeGestureRecognizerDidFire:
    kProbeCount
};
typedef struct { const char *name; BOOL installed; int hits; } apv_probe_t;
static apv_probe_t sProbes[kProbeCount] = {
    { "SBIconView.layoutSubviews",        NO, 0 },
    { "SBApplication._updateProcess",     NO, 0 },
    { "SBLockScreenManager._setUILocked", NO, 0 },
    { "SBLockScreenManager.lockSrc",      NO, 0 },
    { "VPNItem.applyUpdate",              NO, 0 },
    { "VPNItem.additionAnim",             NO, 0 },
    { "SBIconView.longPressFire",         NO, 0 },
    { "SBHIconManager.longPressFire",     NO, 0 },
};

// 每个探针只在**首次命中**时落一条（写清触发现场）；之后每 200 次补一条计数，
// 既能证明"一直在被调"，又不会把日志刷爆。
static void apv_probe(int idx, NSString *detail) {
    if (idx < 0 || idx >= kProbeCount) return;
    sProbes[idx].hits++;
    if (sProbes[idx].hits == 1) {
        apvWriteEx(@"[SYS]", [NSString stringWithFormat:@"探针命中 %s %@",
                              sProbes[idx].name, detail ? detail : @""], 0.0, YES);
    } else if (sProbes[idx].hits % 200 == 0) {
        apvWriteEx(@"[SYS]", [NSString stringWithFormat:@"探针 %s 累计命中 %d 次",
                              sProbes[idx].name, sProbes[idx].hits], 0.0, YES);
    }
}

// 汇总快照：5s（刚启动完）/ 30s（用户已开始操作）各一次
static void apv_probeSummary(NSString *when) {
    @try {
        NSMutableString *m = [NSMutableString stringWithFormat:@"探针汇总(%@): ", when];
        for (int i = 0; i < kProbeCount; i++) {
            [m appendFormat:@"%s[%@/%d] ", sProbes[i].name,
                            sProbes[i].installed ? @"已装" : @"未装", sProbes[i].hits];
        }
        apvWriteEx(@"[SYS]", m, 0.0, YES);
    } @catch (id e) {}
}

// 带装载结果日志的 hook：排查"哪条没挂上"直接看日志，不用猜
static void apv_sys_try_hook(const char *clsName, SEL sel, IMP imp, IMP *orig, int probeIdx) {
    Class cls = objc_getClass(clsName);
    if (!cls || !class_getInstanceMethod(cls, sel)) {
        sysLog([NSString stringWithFormat:@"装载失败（跳过）: %s %@", clsName, NSStringFromSelector(sel)]);
        return;
    }
    MSHookMessageEx(cls, sel, imp, orig);
    if (probeIdx >= 0 && probeIdx < kProbeCount) sProbes[probeIdx].installed = YES;
    sysLog([NSString stringWithFormat:@"装载成功: %s %@", clsName, NSStringFromSelector(sel)]);
}

// ------------------------------------------------------------
// ① APP 运行指示点
// ------------------------------------------------------------
// 自绘小圆点（不碰系统 SBIconDotLabelAccessoryView / labelAccessoryType 枚举——
// 那套私有枚举值各版本不同，赌错就是满屏乱点；自绘可控且零依赖）。
// 判定"运行中"：SBApplicationController → SBApplication.processState.isRunning
// 事件驱动：hook SBApplication 的进程状态更新回调，状态一变就重画，不做轮询。
// ------------------------------------------------------------
static const NSInteger kAPVDotTag = 0x41565044; // 'APVD'
static NSMutableDictionary *sRunCache = nil;    // bundleID -> NSNumber(BOOL)
static os_unfair_lock sRunLock = OS_UNFAIR_LOCK_INIT;

// 三条取 bundleID 的路径依次降级（不同 iOS 版本/图标类型能拿到的不一样），
// 走通哪条记进 sBidPath，探针日志里能看到——万一取不到，一眼知道是哪条断了。
static int sBidPath = 0; // 0=未取到过 1=icon.applicationBundleID 2=icon.application.bundleIdentifier 3=iconView.applicationBundleIdentifierForShortcuts
static NSString *apv_iconBundleID(UIView *iconView) {
    @try {
        if ([iconView respondsToSelector:@selector(icon)]) {
            id icon = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(icon));
            if (icon) {
                if ([icon respondsToSelector:@selector(applicationBundleID)]) {
                    id bid = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(applicationBundleID));
                    if ([bid isKindOfClass:[NSString class]] && [bid length]) { sBidPath = 1; return bid; }
                }
                if ([icon respondsToSelector:@selector(application)]) {
                    id app = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(application));
                    if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                        id bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
                        if ([bid isKindOfClass:[NSString class]] && [bid length]) { sBidPath = 2; return bid; }
                    }
                }
            }
        }
        if ([iconView respondsToSelector:@selector(applicationBundleIdentifierForShortcuts)]) {
            id bid = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(applicationBundleIdentifierForShortcuts));
            if ([bid isKindOfClass:[NSString class]] && [bid length]) { sBidPath = 3; return bid; }
        }
    } @catch (id e) {}
    return nil;
}

static BOOL apv_isRunningBundle(NSString *bid) {
    if (!bid.length) return NO;
    os_unfair_lock_lock(&sRunLock);
    NSNumber *cached = [sRunCache objectForKey:bid];
    os_unfair_lock_unlock(&sRunLock);
    if (cached) return [cached boolValue];

    BOOL running = NO;
    @try {
        id ctrl = ((id (*)(Class, SEL))objc_msgSend)(NSClassFromString(@"SBApplicationController"),
                                                     @selector(sharedInstance));
        id app = ((id (*)(id, SEL, id))objc_msgSend)(ctrl, @selector(applicationWithBundleIdentifier:), bid);
        id st = ((id (*)(id, SEL))objc_msgSend)(app, @selector(processState));
        running = ((BOOL (*)(id, SEL))objc_msgSend)(st, @selector(isRunning));
    } @catch (id e) {}
    os_unfair_lock_lock(&sRunLock);
    [sRunCache setObject:[NSNumber numberWithBool:running] forKey:bid];
    os_unfair_lock_unlock(&sRunLock);
    return running;
}

static void apv_invalidateRunCache(void) {
    os_unfair_lock_lock(&sRunLock);
    [sRunCache removeAllObjects];
    os_unfair_lock_unlock(&sRunLock);
}

// 每个 bundleID 只记一次：既证明"识别到了哪些 app"，又不会因桌面反复布局刷屏
static void apv_logBidOnce(NSString *bid, NSString *prefix, NSMutableSet *seen) {
    if (!bid.length || [seen containsObject:bid]) return;
    [seen addObject:bid];
    sysLog([NSString stringWithFormat:@"%@ %@", prefix, bid]);
}

static void apv_updateRunDot(UIView *iconView) {
    if (!iconView) return;
    apv_probe(kProbeIconLayout, nil);
    UIView *dot = [iconView viewWithTag:kAPVDotTag];
    if (!gRunIndicator) {            // 开关关：只负责收掉已经画出来的点
        if (dot) dot.hidden = YES;
        return;
    }
    if (!dot) {
        dot = [[UIView alloc] initWithFrame:CGRectZero];
        dot.tag = kAPVDotTag;
        dot.userInteractionEnabled = NO;
        dot.hidden = YES;
        [iconView addSubview:dot];
    }
    NSString *bid = apv_iconBundleID(iconView);
    if (!bid.length) {
        dot.hidden = YES;
        // 取不到 bundleID 是"点画不出来"的头号原因，限流记一条（含类名，便于定位）
        apvWriteEx(@"[SYS]", [NSString stringWithFormat:@"指示点: 取不到 bundleID（类=%@，路径=%d）",
                              NSStringFromClass([iconView class]), sBidPath], 60.0, YES);
        return;
    }
    static NSMutableSet *sBidSeen = nil;
    static dispatch_once_t bidOnce;
    dispatch_once(&bidOnce, ^{ sBidSeen = [[NSMutableSet alloc] init]; });
    apv_logBidOnce(bid, @"指示点: 识别到图标", sBidSeen);
    if (!apv_isRunningBundle(bid)) { dot.hidden = YES; return; }
    CGSize s = iconView.bounds.size;
    CGFloat d = 5.0;
    // 位置：跟系统"更新/等待小圆点"一致——图标名右侧 2pt；
    // labelView 拿不到或不在同一坐标系时回退到图标底部居中（不会跑到屏幕外）
    CGRect f = CGRectMake((s.width - d) * 0.5, s.height - 4.0, d, d);
    @try {
        if ([iconView respondsToSelector:@selector(labelView)]) {
            UIView *lv = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(labelView));
            if ([lv isKindOfClass:[UIView class]] && lv.superview == iconView && lv.frame.size.width > 0) {
                f = CGRectMake(CGRectGetMaxX(lv.frame) + 2.0,
                               CGRectGetMidY(lv.frame) - d * 0.5, d, d);
            }
        }
    } @catch (id e) {}
    dot.frame = f;
    dot.layer.cornerRadius = d * 0.5;
    dot.backgroundColor = gRunDotColor ?: [UIColor whiteColor];
    dot.hidden = NO;
    [iconView bringSubviewToFront:dot];
    static NSMutableSet *sDotSeen = nil;
    static dispatch_once_t dotOnce;
    dispatch_once(&dotOnce, ^{ sDotSeen = [[NSMutableSet alloc] init]; });
    apv_logBidOnce(bid, @"指示点: 已画点(运行中)", sDotSeen);
}

static void apv_recurseIconDots(UIView *v, NSInteger depth) {
    if (!v || depth > 12) return;
    static Class sIconViewCls = nil;
    if (!sIconViewCls) sIconViewCls = NSClassFromString(@"SBIconView");
    if (sIconViewCls && [v isKindOfClass:sIconViewCls]) apv_updateRunDot(v);
    for (UIView *sub in v.subviews) apv_recurseIconDots(sub, depth + 1);
}

static void apv_refreshAllIconDots(void) {
    @try {
        // iOS 15 起 UIApplication.windows 已废弃，而工程开了 -Werror（部署目标 15.0），
        // 直接用会编译不过 → 改成遍历每个 UIWindowScene 自己的 windows。
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) apv_recurseIconDots(w, 0);
        }
    } @catch (id e) {}
}

static void (*orig_iconView_layoutSubviews)(UIView *, SEL);
static void hook_iconView_layoutSubviews(UIView *self, SEL _cmd) {
    orig_iconView_layoutSubviews(self, _cmd);
    @try { apv_updateRunDot(self); } @catch (id e) {}
}

static void (*orig_app_updateProcess)(id, SEL, id, id);
static void hook_app_updateProcess(id self, SEL _cmd, id process, id state) {
    orig_app_updateProcess(self, _cmd, process, state);
    @try {   // 探针：APP 启停事件有没有真的送进来
        NSString *bid = nil;
        BOOL running = NO;
        if ([self respondsToSelector:@selector(bundleIdentifier)]) {
            id b = ((id (*)(id, SEL))objc_msgSend)(self, @selector(bundleIdentifier));
            if ([b isKindOfClass:[NSString class]]) bid = b;
        }
        id st = ((id (*)(id, SEL))objc_msgSend)(self, @selector(processState));
        if (st && [st respondsToSelector:@selector(isRunning)])
            running = ((BOOL (*)(id, SEL))objc_msgSend)(st, @selector(isRunning));
        apv_probe(kProbeAppProcess, [NSString stringWithFormat:@"bid=%@ running=%d", bid ?: @"?", running]);
    } @catch (id e) {}
    if (!gRunIndicator) return;
    apv_invalidateRunCache();
    // 状态刚变，processState 未必已经落定，稍等 0.5s 再刷一次桌面
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ apv_refreshAllIconDots(); });
}

// ------------------------------------------------------------
// ② 注销不锁屏
// ------------------------------------------------------------
// 判定"这次启动是注销而不是冷开机"：比较系统开机时间（kern.boottime）与
// 本进程启动时间（KERN_PROC_PID → p_starttime）。冷开机时 SpringBoard 在
// 开机几秒内就起来了；注销（respring）时设备已经跑了一段时间才重启
// SpringBoard。两者相差 > 30s 即判定为 respring，此时吞掉"第一次上锁"
// 并主动解锁。只吃一次——之后用户按电源键锁屏完全走原生逻辑。
// ------------------------------------------------------------
static BOOL gRespringLaunch = NO;
static BOOL gLockSwallowed = NO;

static BOOL apv_isRespringLaunch(void) {
    struct timeval boot;
    size_t len = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &len, NULL, 0) != 0) return NO;
    struct kinfo_proc kp;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    len = sizeof(kp);
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) return NO;
    double bootT  = (double)boot.tv_sec + (double)boot.tv_usec / 1e6;
    double startT = (double)kp.kp_proc.p_starttime.tv_sec + (double)kp.kp_proc.p_starttime.tv_usec / 1e6;
    double delta = startT - bootT;
    sysLog([NSString stringWithFormat:@"启动判定: SpringBoard 于开机后 %.0f 秒启动（>30s 判定为注销）", delta]);
    return delta > 30.0;
}

static BOOL apv_shouldSwallowLock(BOOL locked) {
    return (locked && gNoLockAfterRespring && gRespringLaunch && !gLockSwallowed);
}

static void apv_doAutoUnlock(id lsm) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SEL sel = @selector(unlockUIFromSource:withOptions:);
            if (![lsm respondsToSelector:sel]) {
                sysLog(@"[noLock] 自动解锁失败：SBLockScreenManager 不响应 unlockUIFromSource:");
                return;
            }
            ((BOOL (*)(id, SEL, int, id))objc_msgSend)(lsm, sel, 1, nil);
            sysLog(@"[noLock] 已请求自动解锁 unlockUIFromSource:1");
        } @catch (id e) {}
    });
}

static void (*orig_setUILocked)(id, SEL, BOOL);
static void hook_setUILocked(id self, SEL _cmd, BOOL locked) {
    apv_probe(kProbeSetUILocked, [NSString stringWithFormat:@"locked=%d 吞锁条件=%d(开关%d/注销启动%d/未吞过%d)",
                                  locked, apv_shouldSwallowLock(locked),
                                  gNoLockAfterRespring, gRespringLaunch, !gLockSwallowed]);
    if (apv_shouldSwallowLock(locked)) {
        gLockSwallowed = YES;
        sysLog(@"[noLock] 吃掉注销后的 _setUILocked:YES");
        orig_setUILocked(self, _cmd, NO);
        apv_doAutoUnlock(self);
        return;
    }
    orig_setUILocked(self, _cmd, locked);
}

static void (*orig_lockUIFromSource)(id, SEL, int, id);
static void hook_lockUIFromSource(id self, SEL _cmd, int source, id options) {
    apv_probe(kProbeLockFromSource, [NSString stringWithFormat:@"source=%d 吞锁条件=%d(开关%d/注销启动%d/未吞过%d)",
                                     source, apv_shouldSwallowLock(YES),
                                     gNoLockAfterRespring, gRespringLaunch, !gLockSwallowed]);
    if (apv_shouldSwallowLock(YES)) {
        gLockSwallowed = YES;
        sysLog([NSString stringWithFormat:@"[noLock] 吃掉注销后的 lockUIFromSource:%d", source]);
        apv_doAutoUnlock(self);
        return;
    }
    orig_lockUIFromSource(self, _cmd, source, options);
}

// ------------------------------------------------------------
// ③ 连接 VPN 变色 / ⑤ 禁用 VPN 飞入动画
// ------------------------------------------------------------
// 两者都在同一个私有指示器类 _UIStatusBarIndicatorVPNItem 上：
//   · 变色：改它自己的 imageView 的 tintColor（图标是模板图，tintColor 生效）
//   · 飞入：入场动画由 additionAnimationForDisplayItemWithIdentifier: 提供，
//           换成 0 时长空动画即可瞬间出现（不返回 nil，避免调用方解引用空）
// ------------------------------------------------------------
static id (*orig_vpn_applyUpdate)(id, SEL, id, id);
static id hook_vpn_applyUpdate(id self, SEL _cmd, id update, id displayItem) {
    id r = orig_vpn_applyUpdate(self, _cmd, update, displayItem);
    @try {   // 探针：VPN 指示器的刷新到底有没有走到这里，imageView 拿不拿得到
        id iv = ((id (*)(id, SEL))objc_msgSend)(self, @selector(imageView));
        apv_probe(kProbeVPNApply, [NSString stringWithFormat:@"imageView=%@ 有图=%d 变色开关=%d",
                                   iv ? NSStringFromClass([iv class]) : @"nil",
                                   ([iv isKindOfClass:[UIImageView class]] && ((UIImageView *)iv).image) ? 1 : 0,
                                   gColorizeVPN]);
    } @catch (id e) {
        apv_probe(kProbeVPNApply, @"imageView 取值抛异常");
    }
    if (!gColorizeVPN) return r;
    @try {
        id iv = ((id (*)(id, SEL))objc_msgSend)(self, @selector(imageView));
        if ([iv isKindOfClass:[UIImageView class]]) {
            UIImageView *v = (UIImageView *)iv;
            if (v.image && v.image.renderingMode != UIImageRenderingModeAlwaysTemplate)
                v.image = [v.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            v.tintColor = gVPNColor ?: [UIColor orangeColor];
        }
    } @catch (id e) {}
    return r;
}

static id (*orig_vpn_additionAnim)(id, SEL, id);
static id hook_vpn_additionAnim(id self, SEL _cmd, id ident) {
    apv_probe(kProbeVPNAddAnim, [NSString stringWithFormat:@"ident=%@ 禁用开关=%d",
                                 [ident description] ?: @"nil", gHideVPNFlyIn]);
    if (gHideVPNFlyIn) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.duration = 0.0;
        a.fromValue = [NSNumber numberWithDouble:1.0];
        a.toValue = [NSNumber numberWithDouble:1.0];
        return a;
    }
    return orig_vpn_additionAnim(self, _cmd, ident);
}

// ------------------------------------------------------------
// ④ 禁用桌面长按
// ------------------------------------------------------------
// 长按图标进抖动编辑态的回调就是 editingModeGestureRecognizerDidFire:，
// 开了开关直接不往下走（图标菜单/其它手势不受影响）。
// ------------------------------------------------------------
static id (*orig_icon_editingFired)(id, SEL, id);
static id hook_icon_editingFired(id self, SEL _cmd, id gr) {
    apv_probe(kProbeLongPress, [NSString stringWithFormat:@"gesture=%@ 禁用开关=%d",
                                gr ? NSStringFromClass([gr class]) : @"nil", gDisableHomeLongPress]);
    if (gDisableHomeLongPress) {
        sysLog(@"[长按] 拦截 SBIconView editingModeGestureRecognizerDidFire:（桌面长按已禁用）");
        return nil;
    }
    return orig_icon_editingFired(self, _cmd, gr);
}

// 备用路径：长按也可能走 delegate（SBHIconManager iconView:editingModeGestureRecognizerDidFire:）。
// 两条都堵，探针会告诉我们系统实际走的是哪条（或两条都走）。
static id (*orig_iconMgr_editingFired)(id, SEL, id, id);
static id hook_iconMgr_editingFired(id self, SEL _cmd, id iconView, id gr) {
    apv_probe(kProbeLongPressMgr, [NSString stringWithFormat:@"gesture=%@ 禁用开关=%d",
                                   gr ? NSStringFromClass([gr class]) : @"nil", gDisableHomeLongPress]);
    if (gDisableHomeLongPress) {
        sysLog(@"[长按] 拦截 SBHIconManager iconView:editingModeGestureRecognizerDidFire:（桌面长按已禁用）");
        return nil;
    }
    return orig_iconMgr_editingFired(self, _cmd, iconView, gr);
}

static NSString *apv_colorCode(UIColor *c) {
    if (!c) return @"nil";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    @try { [c getRed:&r green:&g blue:&b alpha:&a]; } @catch (id e) { return @"?"; }
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)(r * 255), (int)(g * 255), (int)(b * 255)];
}

static void installSystemXFeatures(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sRunCache = [[NSMutableDictionary alloc] init]; });
    gRespringLaunch = apv_isRespringLaunch();

    // 先落一条开关快照：日志里能直接看出"是功能没生效"还是"开关/颜色根本没读到"
    sysLog([NSString stringWithFormat:
            @"开关状态: 指示点=%d(%@) 注销不锁屏=%d VPN变色=%d(%@) 禁长按=%d 禁VPN飞入=%d | 本次启动=%@ | 诊断日志=%d",
            gRunIndicator, apv_colorCode(gRunDotColor), gNoLockAfterRespring,
            gColorizeVPN, apv_colorCode(gVPNColor), gDisableHomeLongPress, gHideVPNFlyIn,
            gRespringLaunch ? @"注销(respring)" : @"冷开机", gVolDiag]);

    // ① APP 运行指示点
    apv_sys_try_hook("SBIconView", @selector(layoutSubviews),
                     (IMP)&hook_iconView_layoutSubviews, (IMP *)&orig_iconView_layoutSubviews, kProbeIconLayout);
    apv_sys_try_hook("SBApplication", @selector(_updateProcess:withState:),
                     (IMP)&hook_app_updateProcess, (IMP *)&orig_app_updateProcess, kProbeAppProcess);
    // ② 注销不锁屏：内部状态机 + 外部上锁入口两条路径都堵
    apv_sys_try_hook("SBLockScreenManager", @selector(_setUILocked:),
                     (IMP)&hook_setUILocked, (IMP *)&orig_setUILocked, kProbeSetUILocked);
    apv_sys_try_hook("SBLockScreenManager", @selector(lockUIFromSource:withOptions:),
                     (IMP)&hook_lockUIFromSource, (IMP *)&orig_lockUIFromSource, kProbeLockFromSource);
    // ③ VPN 变色 / ⑤ VPN 飞入动画（两者的方法都继承自 _UIStatusBarItem，class_getInstanceMethod 能查到）
    apv_sys_try_hook("_UIStatusBarIndicatorVPNItem", @selector(applyUpdate:toDisplayItem:),
                     (IMP)&hook_vpn_applyUpdate, (IMP *)&orig_vpn_applyUpdate, kProbeVPNApply);
    apv_sys_try_hook("_UIStatusBarIndicatorVPNItem", @selector(additionAnimationForDisplayItemWithIdentifier:),
                     (IMP)&hook_vpn_additionAnim, (IMP *)&orig_vpn_additionAnim, kProbeVPNAddAnim);
    // ④ 禁用桌面长按：SBIconView 自身 + SBHIconManager 代理，两条都堵
    apv_sys_try_hook("SBIconView", @selector(editingModeGestureRecognizerDidFire:),
                     (IMP)&hook_icon_editingFired, (IMP *)&orig_icon_editingFired, kProbeLongPress);
    apv_sys_try_hook("SBHIconManager", @selector(iconView:editingModeGestureRecognizerDidFire:),
                     (IMP)&hook_iconMgr_editingFired, (IMP *)&orig_iconMgr_editingFired, kProbeLongPressMgr);

    // 开关本来就开着时（如注销后恢复），等桌面布局完再刷一次指示点
    if (gRunIndicator) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ apv_refreshAllIconDots(); });
    }

    // 探针汇总：启动完 5s 一次（看哪些 hook 在启动期就该被触发）/
    // 30s 一次（用户已经开始划桌面、开 APP 了）。"已装/0 次"= hook 点选错了，得换。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ apv_probeSummary(@"启动5秒"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ apv_probeSummary(@"启动30秒"); });
}

// ============================================================
// 设置变更监听（v1.9.93 关键修复）
//
// ⚠️ 之前挂的是 [[NSNotificationCenter defaultCenter] addObserverForName:kAPVChanged]，
// 那是**进程内**通知中心——而 PreferenceLoader plist 的 PostNotification 发的是
// **Darwin 通知**（notify_post / CFNotificationCenterGetDarwinNotifyCenter，跨进程）。
// 两者不通，所以 SpringBoard 里的观察者**一次都没被调用过**：
//   · v1.9.83 声称修好的"40%/30% 切档立即生效"其实一直要注销才生效
//   · v1.9.91 通知合并档位"即时生效"同样没生效
//   · 用户把「诊断日志」打开后日志仍然空——因为 gVolDiag 缓存还是启动时的 NO
// 现改挂 Darwin 通知中心（跨进程收得到），回调在任意线程 → 回主队列刷新状态。
// ============================================================
static void apv_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Darwin 回调不在主线程，状态刷新回主队列（与路由事件回调同一串行域）
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL runDotWasOn = gRunIndicator;
        apv_refresh();
        // v1.9.96：APP 运行指示点开关切换 → 立即重画/收掉圆点（免注销）
        if (gRunIndicator || runDotWasOn) {
            apv_invalidateRunCache();
            apv_refreshAllIconDots();
        }
        // v1.9.83：开关变更**立即应用**——若当前戴耳机，马上按新档位重新压制。
        // （摘下状态不需要压：摘下强制 100% 常驻，下次戴上路由事件会按新档位压。）
        if (sAirPodsConnected) {
            apv_clampNotifyVolume(
                [NSClassFromString(@"AVSystemController") sharedAVSystemController]);
        }
        ccLog(@"设置开关已刷新");
    });
}

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.springboard"]) return;

    // v1.9.89：respring 卡顿修复。
    // 此前 %ctor 在 SpringBoard 主线程上同步执行了全部启动序列：dlopen 三个
    // 私有框架（ControlCenterUI/MediaRemoteUI/UserNotificationsKit，加载+重定位+
    // 类 realize）+ MPAVRoutingController 预建（首次建 MediaRemote XPC）+
    // AVSystemController 首建 + BluetoothManager/AVAudioSession 枚举 + ctor-init
    // 全套路由检测——全压在启动最忙的关键路径上，表现为「每次注销后屏幕卡一下」
    //（不装插件不卡，实锤就是这里）。
    // 现在拆成三层：
    //   1) %ctor 本体只留 O(1) 轻量注册：读 prefs + 挂观察者 + 建 timer（挂起）
    //   2) dlopen + MSHookMessageEx 丢后台队列（两者均线程安全）
    //   3) 状态初始化/音频调用回主队列，等启动最忙阶段过了再跑
    // 功能时序不变（Shortcuts/弹窗拦截晚装 1~2 秒，无感；音频兜底 clamp 仍 +3s）。
    apv_refresh(); // 启动时读一次设置开关（TGK 风格 plist）
    routeLog(@"ctor running"); // 启动标记：确认 %ctor 执行 + routeLog 写入是否正常

    // v1.9.94：把日志最终落点写进日志第一行（探测在后台日志队列做，不占主线程）。
    // SSH 排查时直接 head 日志就能确认"到底写到哪了"，不用再猜路径。
    dispatch_async(apv_log_queue(), ^{
        NSString *lp = apvLogPath();
        apvBootLog(lp ? [NSString stringWithFormat:@"日志落点 = %@（标记文件 %@）", lp, APV_LOG_MARKER]
                      : @"日志落点探测失败：全部候选路径 fopen 均被拒（诊断日志不会有输出）");
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        handleRouteEventDebounced(); // v1.9.92：burst 合并
    }];

    // 输出设备列表变化（控制中心切喇叭/切耳机、设备加入都触发，不依赖播放会话）
    [[NSNotificationCenter defaultCenter] addObserverForName:@"AVOutputContextOutputDevicesDidChangeNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        handleRouteEventDebounced(); // v1.9.92：连接抖动时每秒连发多次，合并
    }];

    // 1.5s 轮询兜底：保证"开盒必切"（系统不切输出时设备列表无变化、通知不触发）。
    // **窗口化**（老板要求）——连接/被抢时启动 1 分钟兜底窗口，
    // 窗口到期自动停；车载再次打开（再抢）→ 事件触发重启 1 分钟窗口。平时零轮询。
    sPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sPollTimer, dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
                              1.5 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sPollTimer, ^{
        // 便宜的短路（CPU 审计 v1.9.56）：
        //  1) 三个路由开关全关 → 停表，一次检测都不做
        //  2) AirPods 不在场 → 停表，等 btconnect 再开（以前会白跑满 60s 窗口）
        if ((!gAutoRoute && !gStealBack && !gStealHFP) || !sAirPodsConnected) {
            stopPoll();
            return;
        }
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        // 车模式（车载+AirPods 同时在场）：持续监控，窗口续期不断，
        // 保证"车载连接状态下打微信视频被切车载"能在 1.5s 内被抢回
        if (otherBTDeviceConnected()) {
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
        handleRouteEventDebounced(); // v1.9.92：burst 合并（冷却重置/开窗仍立即执行）
    }];
    // AirPods 蓝牙断开 → 立即停止轮询（不等窗口到期）
    [[NSNotificationCenter defaultCenter] addObserverForName:@"BluetoothDeviceDisconnectSuccessNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        stopPoll();
        handleRouteEventDebounced(); // v1.9.92：burst 合并
    }];

    // 设置变更 → 刷新开关缓存（PreferenceLoader plist 的 PostNotification）
    // v1.9.93：改用 Darwin 通知中心（跨进程）；NSNotificationCenter 收不到设置页的变更
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, apv_prefsChanged,
                                    (__bridge CFStringRef)kAPVChanged, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // ---------- v1.9.89：以下全部重活移出主线程 ----------
    // 后台队列：dlopen 三个私有框架（ControlCenterUI/MediaRemoteUI/
    // UserNotificationsKit）+ MSHook 装载 + MPAVRoutingController 预建。
    // dlopen 与 MSHookMessageEx 均线程安全，后台执行无副作用；唯一代价是
    // Shortcuts/弹窗拦截和 CC 模块 hook 晚约 1~2 秒生效（启动后无感）。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @try {
            // 预建 MPAVRoutingController 实例 + 触发刷新：消除首次连接时
            // availableRoutes 为空导致的 no-route-yet 半秒延迟（开盒即能直接切）。
            // 若主队列事件回调（btconnect 等）已抢先懒建过则跳过，避免重复实例。
            if (!sMPARouter) {
                sMPARouter = [[NSClassFromString(@"MPAVRoutingController") alloc] init];
                [sMPARouter setDiscoveryMode:1];
                [sMPARouter fetchAvailableRoutesWithCompletionHandler:^{}];
            }
        } @catch (id e) {}

        // 控制中心 Now Playing 模块压成 1x1（BetterCC 同款机制，只做 media 一支）
        installNowPlaying1x1();
        // 1×1 模块内部布局：只隐藏上一曲/下一曲（展开态完全原生）
        installNowPlayingLayoutTweaks();
        // 控制中心音量模块展开后显示铃声音量双滑块（Ring 主功能移植）
        installRingerSlider();

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

        // 通知合并成一组（NotifsDontHide Feature 1 并入，v1.9.91）：
        // 通知框架类随 SpringBoard 启动即已加载（NDH 在 %ctor 直挂同样可行），
        // 后台队列挂安全 hook（类缺失静默跳过），开关档位 hook 内实时读、免注销生效
        installNotifGrouping();

        // v1.9.96：SystemX 移植的五功能（APP 运行指示点/注销不锁屏/VPN 变色/
        // 禁用桌面长按/禁用 VPN 飞入）。全部默认关闭，装载在后台队列，不占启动主线程。
        installSystemXFeatures();

        // 回主队列：状态初始化 + 音频调用（此时 SpringBoard 启动最忙阶段已过）。
        // 放主队列是为了与各事件回调（均在 main queue）保持同一串行域，
        // sAirPodsConnected / sMPARouter 等状态不产生跨线程竞争。
        dispatch_async(dispatch_get_main_queue(), ^{
            sAirPodsConnected = airPodsInBluetoothDevices(); // 启动时初始化"AirPods 在场"
            id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
            // v1.9.76：启动时摘下状态 → 通知音确保 100%（常驻，无开关；静音跳过）
            if (!sAirPodsConnected && !isRingerMuted()) {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
            if (sAirPodsConnected) {
                // 启动时若已连 AirPods（如 respring 后仍连着）：启动轮询窗口 + 初始检测
                startPollWindow();
                handleRouteEvent(@"ctor-init");
                // v1.9.81：respring 后戴耳机 → 再主动压一次通知音（延迟 3s 等音频服务就绪），
                // 覆盖"路由事件迟迟不来（耳机一直戴着、状态无变化）"的空窗期。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        apv_clampNotifyVolume(
                            [NSClassFromString(@"AVSystemController") sharedAVSystemController]);
                    } @catch (id e) {}
                });
            }
        });
    });
}
