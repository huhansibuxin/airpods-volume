#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
static BOOL gLimitAlert = YES, gHideReplayKit = YES;
static BOOL gShrinkNowPlaying = YES, gHidePrevNext = YES;
static BOOL gBlockPopup = YES, gBlockShortcuts = YES;
static BOOL gMiniVolumeHUD = YES, gDisableHUDTouch = YES;
static BOOL gVolDiag = NO;      // 音量诊断日志（默认关：每次 setVolumeTo 都记，排查用）
static BOOL gCallVolumeGuard = YES; // 通话期间媒体音量兜底压制（默认开）
static BOOL gShowRingerSlider = YES; // 控制中心音量模块展开后显示铃声音量滑块（默认开）

static void apv_refresh(void) {
    gAutoRoute = apv_bool(@"autoRouteToAirPods", YES);
    gStealBack = apv_bool(@"stealBackFromCar", YES);
    gStealHFP = apv_bool(@"stealBackHFPCalls", YES);
    gLimitAlert = apv_bool(@"limitAlertVolume", YES);
    gHideReplayKit = apv_bool(@"hideReplayKitCCModules", YES);
    gShrinkNowPlaying = apv_bool(@"shrinkNowPlayingCCModule", YES);
    gHidePrevNext = apv_bool(@"hideNowPlayingPrevNext", YES);
    gBlockPopup = apv_bool(@"blockAirPodsPopup", YES);
    gBlockShortcuts = apv_bool(@"blockShortcutsNotifications", YES);
    gMiniVolumeHUD = apv_bool(@"miniVolumeHUD", YES);
    gDisableHUDTouch = apv_bool(@"disableVolumeHUDTouch", YES);
    gVolDiag = apv_bool(@"volumeDiagLog", NO);
    gCallVolumeGuard = apv_bool(@"callVolumeGuard", YES);
    gShowRingerSlider = apv_bool(@"showRingerSlider", YES);
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

// 前向声明：日志函数定义在下方，但上面的音量 hook 就要用到
static void routeLog(NSString *msg);
static void volLog(NSString *msg);
static NSString *volStack(NSUInteger n);

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

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    // 开关：设置里"限制铃声/通知音量"关闭 → 完全不介入音量
    if (!gLimitAlert) return %orig(vol, cat);
    float vol_orig = vol; // 原始请求值（诊断用：看系统/App 到底想要多少）
    float cap = capForCategory(cat);
    // 摘下时通知音强制 100%（静音跳过）；戴上时各类音量按 cap 封顶
    // （媒体 70%/通知 40%——hook 层兜底，控制中心滑动条走 MediaRemote
    // 路径不经此 hook，由 handleRouteEvent 戴上时读当前值主动压兜底）
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
    if (!gLimitAlert) return %orig;
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
    if (r && gLimitAlert) {
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
// 全部写进同一个文件 /var/jb/tmp/airpods_vol.log，方便 tail -f 一次看全。
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

static NSString * const kAPVLogPath = @"/var/jb/tmp/airpods_vol.log";

// 节流：同一个 key 在 interval 秒内只放行一次（返回 NO = 抑制）
static BOOL apv_throttle(NSString *key, NSTimeInterval interval) {
    @try {
        static NSMutableDictionary *last = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ last = [[NSMutableDictionary alloc] init]; });
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSNumber *prev = [last objectForKey:key];
        if (prev && (now - [prev doubleValue]) < interval) return NO;
        [last setObject:[NSNumber numberWithDouble:now] forKey:key];
        return YES;
    } @catch (id e) { return YES; }
}

static void apvWrite(NSString *tag, NSString *msg, NSTimeInterval throttle) {
    if (!gVolDiag) return;
    if (throttle > 0.0 && !apv_throttle(msg, throttle)) return;
    FILE *f = fopen([kAPVLogPath UTF8String], "a");
    if (!f) return;
    fprintf(f, "[%s] %s %s\n", [[[NSDate date] description] UTF8String],
            [tag UTF8String], [msg UTF8String]);
    fclose(f);
}

// 音量重点日志：**盯紧**，只做 1s 内完全相同消息的去重
static void volLog(NSString *msg)   { apvWrite(@"[VOL]", msg, 1.0); }
// 路由事件日志：同类 5s 一条
static void routeLogImpl(NSString *msg) { apvWrite(@"[ROUTE]", msg, 5.0); }
// 控制中心模块日志：同类 30s 一条（下拉控制中心会连刷 6 条一样的）
static void ccLog(NSString *msg)    { apvWrite(@"[CC]", msg, 30.0); }

// 不受 gVolDiag 门控的启动/装载日志：写独立文件，关诊断也能确认 hook 是否真生效。
// 用于排查铃声音量双滑块——诊断关时 apvWrite 一行都不写，无从定位。
static NSString * const kAPVBootLogPath = @"/var/jb/tmp/airpods_boot.log";
static void apvBootLog(NSString *msg) {
    @try {
        FILE *f = fopen([kAPVBootLogPath UTF8String], "a");
        if (!f) return;
        fprintf(f, "[%s] %s\n", [[[NSDate date] description] UTF8String], [msg UTF8String]);
        fclose(f);
    } @catch (id e) {}
}

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
// 控制中心音量模块长按展开后显示「铃声音量」双滑块
// 逆向 Ring.dylib（com.yan.ring 1.0.2）实锤：
//   主功能不是百分比，而是展开 MRUVolumeViewController 后在右侧加一个
//   MediaControlsVolumeRingerSliderView（自定义类），左侧保留媒体音量滑块，
//   顶部放铃铛图标。Ring 通过 AVSystemController 的 Ringtone 类别读写铃声音量。
// 这里用更简单的 APVRingerSliderView（UIView + pan 手势 + fillView）复刻核心功能，
// 不引入 Ring 的完整自定义类体系，避免过度复杂。
// ============================================================

@interface APVRingerSliderView : UIView
@property (nonatomic, assign) float value;
@property (nonatomic, copy) void (^valueChanged)(float value);
- (void)setValue:(float)value animated:(BOOL)animated;
@end

@implementation APVRingerSliderView {
    UIView *_bgView;
    UIView *_fillView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = YES;
        _bgView = [[UIView alloc] initWithFrame:self.bounds];
        _bgView.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.15f];
        _bgView.layer.cornerRadius = frame.size.width * 0.5f;
        _bgView.layer.masksToBounds = YES;
        _bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_bgView];

        _fillView = [[UIView alloc] initWithFrame:CGRectZero];
        _fillView.backgroundColor = [UIColor whiteColor];
        _fillView.layer.cornerRadius = frame.size.width * 0.5f;
        _fillView.layer.masksToBounds = YES;
        [self addSubview:_fillView];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        [self setValue:0.5f animated:NO];
    }
    return self;
}

- (void)layoutFill {
    CGFloat h = self.bounds.size.height * _value;
    _fillView.frame = CGRectMake(0, self.bounds.size.height - h, self.bounds.size.width, h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutFill];
}

- (void)setValue:(float)value {
    [self setValue:value animated:NO];
}

- (void)setValue:(float)value animated:(BOOL)animated {
    _value = fmaxf(0.0f, fminf(1.0f, value));
    if (animated) {
        [UIView animateWithDuration:0.05 animations:^{ [self layoutFill]; }];
    } else {
        [self layoutFill];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint loc = [pan locationInView:self];
    CGFloat h = self.bounds.size.height;
    if (h <= 0) return;
    float value = 1.0f - (float)(loc.y / h);
    value = fmaxf(0.0f, fminf(1.0f, value));
    self.value = value;
    if (self.valueChanged) self.valueChanged(value);
}

@end

// 创建系统原生 MediaControlsVolumeRingerSliderView 作为铃声音量滑块。
// Ring.dylib 反编译证实：ringerSlider 类就是系统自带的 MediaControlsVolumeRingerSliderView，
// 自带原生毛玻璃背景/白色填充/圆角/触摸交互。我们之前用 APVRingerSliderView 自绘，所以
// 右边是纯白方块。这里优先用原生类；取不到或初始化失败再降级到自绘。
static UIView *apv_createNativeRingerSlider(CGRect frame, float value, UIView *styleReference) {
    // 该类在 MediaControls.framework 里，不在 MediaRemoteUI。
    dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
    Class c = NSClassFromString(@"MediaControlsVolumeRingerSliderView");
    if (!c && styleReference) {
        // 兜底：用和左边 primarySlider 一模一样的类，保证视觉风格一致
        c = [styleReference class];
        apvBootLog([NSString stringWithFormat:@"原生铃声音量类未找到，降级用 primarySlider 同类: %@", c]);
    }
    if (!c) {
        apvBootLog(@"MediaControlsVolumeRingerSliderView 及 styleReference 均为 nil，走 APVRingerSliderView 自绘");
        return nil;
    }
    apvBootLog([NSString stringWithFormat:@"铃声音量 slider 使用类: %@", c]);
    id raw = [c alloc];
    UIView *slider = nil;
    SEL initSel = NSSelectorFromString(@"initWithFrame:minimumValue:cornerRadius:");
    if ([raw respondsToSelector:initSel]) {
        // cornerRadius=0 时该类内部默认 42；minimumValue=0 即可（Ring 用 0/0.0625 两种，看偏好）
        slider = ((id (*)(id, SEL, CGRect, double, double))objc_msgSend)(raw, initSel, frame, 0.0, 0.0);
    } else if ([raw respondsToSelector:@selector(initWithFrame:)]) {
        slider = ((id (*)(id, SEL, CGRect))objc_msgSend)(raw, @selector(initWithFrame:), frame);
    }
    if (!slider) {
        apvBootLog(@"原生 slider init 返回 nil，走 APVRingerSliderView 自绘");
        return nil;
    }
    SEL curSel = NSSelectorFromString(@"setCurrentValue:");
    if ([slider respondsToSelector:curSel]) {
        ((void (*)(id, SEL, double))objc_msgSend)(slider, curSel, (double)value);
    }
    slider.tag = 0xA9B0;
    return slider;
}

static const void *kRingerSliderKey = &kRingerSliderKey;
static const void *kRingerBellKey   = &kRingerBellKey;

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
        SEL viewSel = NSSelectorFromString(@"view");
        id view = ((id (*)(id, SEL))objc_msgSend)(self, viewSel);
        if (![view isKindOfClass:[UIView class]]) return;
        UIView *moduleView = (UIView *)view;

        // isExpanded 发在 self.view 上（Ring FUN_00006590 行723：isExpanded(view)）。
        // 先查 view，再退而查 self，双保险；都不响应时按"展开"处理。
        SEL expandedSel = NSSelectorFromString(@"isExpanded");
        BOOL expanded = YES;
        if ([moduleView respondsToSelector:expandedSel]) {
            expanded = ((BOOL (*)(id, SEL))objc_msgSend)(moduleView, expandedSel);
        } else if ([self respondsToSelector:expandedSel]) {
            expanded = ((BOOL (*)(id, SEL))objc_msgSend)(self, expandedSel);
        }

        // ★ primarySlider / secondarySlider 是 self.view 的属性，不是控制器的！
        // 之前错写成 objc_msgSend(self, primarySlider) → 返回 nil → 永远提前 return，
        // 滑块从不创建（Ring FUN_00006590 行744：primarySlider(view)）。
        SEL sliderSel = NSSelectorFromString(@"primarySlider");
        id slider = nil;
        if ([moduleView respondsToSelector:sliderSel]) {
            slider = ((id (*)(id, SEL))objc_msgSend)(moduleView, sliderSel);
        } else if ([self respondsToSelector:sliderSel]) {
            slider = ((id (*)(id, SEL))objc_msgSend)(self, sliderSel);
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
            // 优先使用系统原生 MediaControlsVolumeRingerSliderView（Ring 同款）
            ringer = apv_createNativeRingerSlider(rFrame, apv_ringerVolume(), primarySlider);
            if (!ringer) {
                // 降级：自己画一个（样式不如原生，但能工作）
                APVRingerSliderView *custom = [[APVRingerSliderView alloc] initWithFrame:rFrame];
                custom.valueChanged = ^(float value) { apv_setRingerVolume(value); };
                ringer = custom;
            }
            objc_setAssociatedObject(self, kRingerSliderKey, ringer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [moduleView addSubview:ringer];
        }
        ringer.hidden = NO;
        ringer.frame = CGRectMake(rightX, sliderY, sliderW, sliderH);

        // 同步铃声音量：原生类走 setCurrentValue:；自定义类走 .value
        float rv = apv_ringerVolume();
        SEL setCurSel = NSSelectorFromString(@"setCurrentValue:");
        if ([ringer respondsToSelector:setCurSel]) {
            ((void (*)(id, SEL, double))objc_msgSend)(ringer, setCurSel, (double)rv);
        } else if ([ringer isKindOfClass:[APVRingerSliderView class]]) {
            ((APVRingerSliderView *)ringer).value = rv;
        }

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
        SEL assetSel = NSSelectorFromString(@"primaryAssetView");
        if ([moduleView respondsToSelector:assetSel]) {
            id asset = ((id (*)(id, SEL))objc_msgSend)(moduleView, assetSel);
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

// 是否正处于蓝牙 HFP 通话（微信视频/语音、系统电话都走这个端口）。
// 只看端口类型，不区分是车载还是 AirPods——只要 BluetoothHFP 端口出现在
// 当前路由里，就是"正在煲电话粥"，音量兜底窗口就该开着。
static BOOL hfpCallActive(void) {
    @try {
        AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
        for (AVAudioSessionPortDescription *p in route.outputs)
            if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) return YES;
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

static dispatch_source_t sCallVolTimer = NULL;
static BOOL sCallVolRunning = NO;
static NSTimeInterval sCallVolStopAt = 0;
static BOOL sPrevHFP = NO;

static void startCallVolumeGuard(void) {
    if (!sCallVolTimer) return;
    sCallVolStopAt = [[NSDate date] timeIntervalSince1970] + 12.0;
    if (!sCallVolRunning) { dispatch_resume(sCallVolTimer); sCallVolRunning = YES; }
}

static void stopCallVolumeGuard(void) {
    sCallVolStopAt = 0;
    if (sCallVolRunning) { dispatch_suspend(sCallVolTimer); sCallVolRunning = NO; }
}

static void callVolumeGuardTick(void) {
    @try {
        // 零成本短路：开关关了 / AirPods 不在场 → 直接停表
        if (!gCallVolumeGuard || !gLimitAlert || !sAirPodsConnected) {
            stopCallVolumeGuard();
            return;
        }
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (hfpCallActive()) {
            sCallVolStopAt = now + 12.0;   // 还在通话 → 续期
        } else if (now > sCallVolStopAt) {
            stopCallVolumeGuard();         // 挂断 12s 后收工
            return;
        }
        if (!currentOutputIsAirPods()) return; // 通话走听筒/车载时不碰音量
        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        // v1.9.62：不再每 2s 无条件 setVolumeTo（可能干扰微信视频音频流），
        // 只在当前值确实高于 cap 时才写。getVolume 无播放会话时返回假值 0.70，
        // 此时 (cur > cap) 为假，不会触发多余写入。
        float cur = 0.0f;
        if ([avc getVolume:&cur forCategory:@"Audio/Video"] && cur > 0.70f) {
            [avc setVolumeTo:0.7f forCategory:@"Audio/Video"];
            if (gVolDiag) volLog(@"callGuard press Audio/Video >70");
        }
        if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.40f) {
            [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
            if (gVolDiag) volLog(@"callGuard press Ringtone >40");
        }
        if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.40f) {
            [avc setVolumeTo:0.4f forCategory:@"Alert"];
            if (gVolDiag) volLog(@"callGuard press Alert >40");
        }
    } @catch (id e) {}
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

        // 通话音量兜底窗口：HFP 端口 0→1 跳变（打视频/接电话）时启动。
        // 事件驱动，不是常驻轮询——挂断后 tick 自己到期停表。
        // ⚠️ 这里只能用 gCallVolumeGuard 作门控：诊断开关(gVolDiag)单独开、
        // 兜底关时，绝不能因为日志开着就误触发 startCallVolumeGuard()。
        // 日志由内部的 if (gVolDiag) 单独门控。
        if (gCallVolumeGuard) {
            BOOL hfpNow = hfpCallActive();
            if (hfpNow != sPrevHFP) {
                if (gVolDiag) {
                    volLog([NSString stringWithFormat:
                        @"HFP %d->%d (src=%@ conn=%d outAir=%d)",
                        sPrevHFP, hfpNow, source, sAirPodsConnected, currentOutputIsAirPods()]);
                }
                if (hfpNow) startCallVolumeGuard();
                sPrevHFP = hfpNow;
            }
        }
        if (sAirPodsConnected) {
            float cur;
            // 开关：设置里"音量保护"关闭时不改任何音量
            if (gLimitAlert) {
                if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                    [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
                if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                    [avc setVolumeTo:0.4f forCategory:@"Alert"];
            }
            // 媒体音量：只在"新戴上"（conn 0→1 跳变）时压到 70（v1.9.27）。
            // ⚠️ 关键时序修复：**绝不立即压**——btconnect 瞬间输出还在喇叭，
            // setVolumeTo(0.7) 会改喇叭音量+污染喇叭记忆（摘下后系统恢复的
            // 喇叭记忆被我们改成 70 → 回不到戴前值，老板实测"摘下停在 70"）。
            // 正确做法：等 attached 切换完成（输出确认是 AirPods）再压——
            // 只改 AirPods 音量/记忆，喇叭记忆不碰，摘下后系统正常恢复。
            // 压三次（0.8s/2.0s/3.2s，输出是 AirPods 才压）：覆盖系统经
            // MediaRemote 路径的延迟音量设置。getVolume 恒假值不读取。
            // 开关：音量保护关掉时不压媒体音量
            BOOL newlyAttached = !sPrevAttached && gLimitAlert;
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
            // ⚠️ v1.9.57：旧的"路由事件 5s 后复查媒体音量"已删除。
            // 它用 `[avc getVolume:&mv] && mv > 0.7f` 判断要不要压，但无播放
            // 会话时 getVolume 返回缓存假值 0.70 → 判断恒假 → 真 100% 也压不动
            // （老板实测"两次压回来了、两次没有"）。改由 callVolumeGuard 在
            // 通话期间每 2s 无条件压，绕开假值问题。
        } else {
            // 摘下 AirPods（不管车载是否还在）：恢复通知音 100%，静音模式下不强制
            if (!isRingerMuted() && gLimitAlert) {
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

    apv_refresh(); // 启动时读一次设置开关（TGK 风格 plist）
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
    // 开关：设置里"限制铃声/通知音量"
    if (gLimitAlert && !sAirPodsConnected && !isRingerMuted()) {
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

    // 通话期间音量兜底：2s 一跳，初始挂起，等 HFP 0→1 跳变（打视频/接电话）才开。
    // 挂断 12s 后 tick 自己停表 → 平时零开销。
    sCallVolTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sCallVolTimer, dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC),
                              2.0 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sCallVolTimer, ^{ callVolumeGuardTick(); });
    dispatch_suspend(sCallVolTimer);

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
    // 1×1 模块内部布局：只隐藏上一曲/下一曲（展开态完全原生）
    installNowPlayingLayoutTweaks();
    // 控制中心音量模块展开后显示铃声音量双滑块（Ring 主功能移植）
    installRingerSlider();

    // 设置变更 → 刷新开关缓存（PreferenceLoader plist 的 PostNotification）
    [[NSNotificationCenter defaultCenter] addObserverForName:kAPVChanged
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        apv_refresh();
        ccLog(@"设置开关已刷新");
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
