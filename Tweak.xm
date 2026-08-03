#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>


@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
- (BOOL)changeVolumeBy:(float)v forCategory:(id)c;
- (BOOL)getVolume:(float *)v forCategory:(id)c;
- (void)overrideToPartnerRoute;
- (void)setPickedRouteWithPassword:(id)route withPassword:(id)password;
@end

@interface MPAVRoutingController : NSObject
- (void)fetchAvailableRoutesWithCompletionHandler:(void(^)(NSArray *))handler;
- (void)selectRoutes:(NSArray *)routes operation:(NSInteger)op completion:(void(^)(void))completion;
@end

static void apv_log(NSString *fmt, ...) __attribute__((format(NSString, 1, 2)));

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

static BOOL sAirPodsCached = NO;

static BOOL isBluetoothPort(AVAudioSessionPortDescription *p) {
    NSString *type = p.portType;
    return [type isEqualToString:AVAudioSessionPortBluetoothA2DP]
        || [type isEqualToString:AVAudioSessionPortBluetoothHFP]
        || [type isEqualToString:AVAudioSessionPortBluetoothLE];
}

static void updateAirPodsCache(void) {
    sAirPodsCached = NO;
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *p in route.outputs) {
        if (isBluetoothPort(p)) {
            sAirPodsCached = YES;
            break;
        }
    }
    // fallback: check inputs (for Bluetooth headsets with mic)
    if (!sAirPodsCached) {
        for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
            if (isBluetoothPort(p)) {
                sAirPodsCached = YES;
                break;
            }
        }
    }
}


#define kDarwinNotifyName "com.apv.airpods.state"
static int _airpodsStateToken = -1;
static NSTimeInterval lastBluetoothSeen = 0;
static const NSTimeInterval kBTGraceWindow = 5.0;

static void readAirPodsCache(void);

static BOOL sAirPodsConnected = NO;
static BOOL sAirPodsCurrentRoute = NO;

static void readAirPodsCache(void) {
    uint64_t state = 0;
    if (notify_get_state(_airpodsStateToken, &state) == NOTIFY_STATUS_OK) {
        sAirPodsConnected = (state & 1);
        sAirPodsCurrentRoute = (state & 2);
    }
}

static __attribute__((used)) void writeAirPodsCache(BOOL connected, BOOL current) {
    uint64_t state = (connected ? 1 : 0) | (current ? 2 : 0);
    uint32_t ret = notify_set_state(_airpodsStateToken, state);
    apv_log(@"APV: SB writeAirPodsCache connected=%d current=%d state=%llu notify_ret=%u token=%d",
            connected, current, state, ret, _airpodsStateToken);
    sAirPodsConnected = connected;
    sAirPodsCurrentRoute = current;
}

typedef int (*AudioSessionSetProperty_t)(unsigned int, unsigned int, const void *);
static int (*original_AudioSessionSetProperty)(unsigned int, unsigned int, const void *) = NULL;
static __attribute__((used)) void forceRouteToAirPods(int reason);

static int hooked_AudioSessionSetProperty(unsigned int inID, unsigned int inDataSize, const void *inData) {
    readAirPodsCache();
    if (sAirPodsConnected && inID == 'ovrt' && inDataSize >= sizeof(unsigned int)) {
        unsigned int route = *(unsigned int *)inData;
        char routeStr[5] = {0};
        memcpy(routeStr, &route, 4);
        apv_log(@"APV: AudioSessionSetProperty ovrt=%.4s connected=%d currentRoute=%d", routeStr, sAirPodsConnected, sAirPodsCurrentRoute);
        if (route == 'spkr') {
            apv_log(@"APV: blocked speaker route, forcing AirPods");
            dispatch_async(dispatch_get_main_queue(), ^{
                forceRouteToAirPods(99);
            });
            return 0; // block speaker route
        }
    }
    return original_AudioSessionSetProperty(inID, inDataSize, inData);
}

static BOOL isAirPodsConnected(void) {
    return sAirPodsCached;
}

static float applyVolumeCap(float vol) {
    if (isAirPodsConnected())
        return MIN(vol, 0.4f);
    return 1.0f;
}


static BOOL isSpringBoard = NO;
static BOOL isMediaserverd = NO;

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    if (isNotificationCategory(cat))
        vol = applyVolumeCap(vol);
    return %orig;
}
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)cat {
    if (isNotificationCategory(cat)) {
        float cur;
        if ([self getVolume:&cur forCategory:cat])
            return [self setVolumeTo:applyVolumeCap(cur + delta) forCategory:cat];
    }
    return %orig;
}
// Cap getters so HUD always reads capped value (no flicker)
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig;
    if (r && isNotificationCategory(cat))
        *vol = applyVolumeCap(*vol);
    return r;
}
// Spy on hijack attempts
- (BOOL)shouldClientWithAudioScore:(unsigned int)score hijackRoute:(id)route hijackDeniedReason:(id *)reason {
    BOOL r = %orig;
    apv_log(@"APV: HIJACK score=%u route=%@ deniedReason=%@ result=%@", score, route, reason ? *reason : nil, r ? @"ALLOW" : @"DENY");
    return r;
}
%end

// Disable touch on HUD slider — volume only via physical buttons.
%hook SBHUDWindow
- (void)addSubview:(UIView *)view {
    // Disable touch on all HUD subviews — buttons only
    view.userInteractionEnabled = NO;
    %orig;
}
%end

// Also disable touch on the elastic slider
@interface SBElasticVolumeSliderView : UIView
@end
%hook SBElasticVolumeSliderView
- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    self.userInteractionEnabled = NO;
    return self;
}
%end

// Hide replaykit CC modules (mic mode / video effects) during calls
// Block the bundle's principal class so the module never instantiates
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
// mediaserverd: Route switching hook
// ============================================================

%hook AVAudioSessionRouteDescription
- (id)initWithRouteDictionary:(NSDictionary *)dict {
    if (!isMediaserverd) return %orig;
    return %orig;
}
%end

// SpringBoard: route change for state tracking only
%hook AVAudioSession
%new
- (void)airpods_routeChangeForState:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSInteger reason = [info[AVAudioSessionRouteChangeReasonKey] integerValue];
    AVAudioSessionRouteDescription *prev = info[AVAudioSessionRouteChangePreviousRouteKey];
    AVAudioSessionRouteDescription *cur = [AVAudioSession sharedInstance].currentRoute;
    NSString *curPort = [[cur.outputs firstObject] portName] ?: @"?";
    NSString *prevPort = [[prev.outputs firstObject] portName] ?: @"?";
    apv_log(@"APV: SB routeChange reason=%ld prev=%@ -> cur=%@", (long)reason, prevPort, curPort);
    BOOL isBT = NO;
    for (AVAudioSessionPortDescription *p in cur.outputs) {
        if (isBluetoothPort(p)) { isBT = YES; break; }
    }
    sAirPodsCached = isBT;
    writeAirPodsCache(sAirPodsCached, sAirPodsCached && isBT);
    apv_log(@"APV: SB cache=%d connected=%d currentRoute=%d", sAirPodsCached, sAirPodsConnected, sAirPodsCurrentRoute);

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (isBT) lastBluetoothSeen = now;

    // If we were on Bluetooth and now switched away, force route back
    BOOL wasBT = NO;
    for (AVAudioSessionPortDescription *p in prev.outputs) {
        apv_log(@"APV: SB prev portType=%@ portName=%@", p.portType, p.portName);
        if (isBluetoothPort(p)) { wasBT = YES; break; }
    }
    BOOL btRecent = (now - lastBluetoothSeen) < kBTGraceWindow;
    apv_log(@"APV: SB force decision: wasBT=%d isBT=%d cached=%d btRecent=%d reason=%ld",
            wasBT, isBT, sAirPodsCached, btRecent, (long)reason);
    if (wasBT && !isBT && reason != 2 && (sAirPodsCached || btRecent)) {
        apv_log(@"APV: SB force route: BT->nonBT (reason=%ld)", (long)reason);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            forceRouteToAirPods((int)reason);
        });
    }
}
%end

#define LOG_FILE "/tmp/apv.log"
static void apv_log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [[NSString alloc] initWithFormat:@"%@\n", msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, data.bytes, data.length);
        close(fd);
    }
}


static NSTimeInterval lastForceSuccess = 0;

static __attribute__((used)) void forceRouteToAirPods(int reason) {
    static NSTimeInterval lastCall = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    BOOL retaliation = (reason == 3 || reason == 4) && (now - lastForceSuccess < 2.0);
    if (!retaliation && now - lastCall < 3.0) return;
    lastCall = now;
    apv_log(@"APV: setPickedRoute trigger reason=%d retaliation=%d", reason, retaliation);

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    id rc = [[NSClassFromString(@"MPAVRoutingController") alloc] init];
    [rc fetchAvailableRoutesWithCompletionHandler:^(NSArray *routes) {
        id target = nil;
        for (id r in routes) {
            id desc = [r valueForKey:@"routeDescription"];
            if (!desc) {
                // try direct port type
                NSString *type = [r valueForKey:@"routeType"];
                if ([type isEqualToString:@"BluetoothA2DP"] || [type isEqualToString:@"BluetoothHFP"] || [type isEqualToString:@"BluetoothLE"]) {
                    target = r;
                    break;
                }
                continue;
            }
            NSArray *outs = [desc valueForKey:@"outputs"];
            for (id out in outs) {
                NSString *pt = [out valueForKey:@"portType"];
                if ([pt isEqualToString:AVAudioSessionPortBluetoothA2DP]
                 || [pt isEqualToString:AVAudioSessionPortBluetoothHFP]
                 || [pt isEqualToString:AVAudioSessionPortBluetoothLE]) {
                    target = r;
                    break;
                }
            }
            if (target) break;
        }
        if (!target) {
            apv_log(@"APV: no Bluetooth route in available routes");
            return;
        }
        apv_log(@"APV: setPickedRouteWithPassword %@", [target valueForKey:@"routeName"]);
        [avc setPickedRouteWithPassword:target withPassword:nil];
        lastForceSuccess = [[NSDate date] timeIntervalSince1970];
        apv_log(@"APV: setPickedRouteWithPassword done");
    }];
}

// ============================================================
// Block AirPods popup when opening case
// ============================================================
@interface BTAirPodsBatteryViewController : UIViewController
@end
%hook BTAirPodsBatteryViewController
- (void)viewWillAppear:(BOOL)animated {
    apv_log(@"APV: AirPods popup blocked");
    [self dismissViewControllerAnimated:NO completion:nil];
}
%end

%ctor {
    isSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    isMediaserverd = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mediaserverd"];

    if (isSpringBoard || isMediaserverd) {
        if (isSpringBoard) {
            updateAirPodsCache();
            notify_register_check(kDarwinNotifyName, &_airpodsStateToken);
            apv_log(@"APV: SB notify_register_check token=%d", _airpodsStateToken);

            [[NSNotificationCenter defaultCenter] addObserver:[objc_getClass("AVAudioSession") sharedInstance]
                                                     selector:@selector(airpods_routeChangeForState:)
                                                         name:AVAudioSessionRouteChangeNotification
                                                       object:nil];

            apv_log(@"APV: SpringBoard v1.2.0 initialized");
        }

        if (isMediaserverd) {
            void *aHandle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
            if (aHandle) {
                void *sym = dlsym(aHandle, "AudioSessionSetProperty");
                apv_log(@"APV: media dlsym AudioSessionSetProperty=%p original=%p", sym, original_AudioSessionSetProperty);
                if (sym && original_AudioSessionSetProperty == NULL) {
                    MSHookFunction(sym, (void *)hooked_AudioSessionSetProperty, (void **)&original_AudioSessionSetProperty);
                    apv_log(@"APV: media MSHookFunction done, original=%p", original_AudioSessionSetProperty);
                }
                dlclose(aHandle);
            } else {
                apv_log(@"APV: media dlopen AudioToolbox FAILED");
            }

            uint32_t status = notify_register_dispatch(kDarwinNotifyName, &_airpodsStateToken,
                dispatch_get_main_queue(), ^(int token) {
                    readAirPodsCache();
                    apv_log(@"APV: media notify connected=%d currentRoute=%d", sAirPodsConnected, sAirPodsCurrentRoute);
                    if (sAirPodsConnected) {
                        apv_log(@"APV: media notify setActive:YES");
                        [[AVAudioSession sharedInstance] setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
                    }
                });
            apv_log(@"APV: media notify_register status=%u token=%d", status, _airpodsStateToken);

            apv_log(@"APV: mediaserverd v1.2.0 initialized");
        }
    }
}