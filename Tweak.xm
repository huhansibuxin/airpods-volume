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
            return 0;
        }
    }
    return original_AudioSessionSetProperty(inID, inDataSize, inData);
}

static BOOL isAirPodsConnected(void) {
    return sAirPodsConnected;
}

static float applyVolumeCap(float vol) {
    if (isAirPodsConnected())
        return MIN(vol, 0.4f);
    return 1.0f;
}

static BOOL isSpringBoard = NO;
static BOOL isMediaserverd = NO;

// ============================================================
// Volume cap: AVSystemController
// ============================================================

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
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig;
    if (r && isNotificationCategory(cat))
        *vol = applyVolumeCap(*vol);
    return r;
}
- (BOOL)shouldClientWithAudioScore:(unsigned int)score hijackRoute:(id)route hijackDeniedReason:(id *)reason {
    BOOL r = %orig;
    apv_log(@"APV: HIJACK score=%u route=%@ deniedReason=%@ result=%@", score, route, reason ? *reason : nil, r ? @"ALLOW" : @"DENY");
    return r;
}
%end

// ============================================================
// Disable touch on volume HUD slider
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
// Hide replaykit CC modules during calls
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
// SpringBoard: route change monitoring & auto-switch
// ============================================================

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

    // AirPods available? Check availableInputs too (handles car HFP stealing, system not switching, etc.)
    BOOL btAvailable = sAirPodsCached;
    if (!btAvailable) {
        for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
            if (isBluetoothPort(p)) { btAvailable = YES; break; }
        }
    }
    if (btAvailable) lastBluetoothSeen = now;

    BOOL force = NO;
    if (!isBT && btAvailable) {
        // AirPods connected but not the current route — force back
        force = YES;
    }
    apv_log(@"APV: SB force decision: isBT=%d btAvailable=%d reason=%ld force=%d",
            isBT, btAvailable, (long)reason, force);
    if (force) {
        apv_log(@"APV: SB force route: AirPods available but not current route (reason=%ld)", (long)reason);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            forceRouteToAirPods((int)reason);
        });
    }
}
%end

// ============================================================
// apv_log
// ============================================================

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

// ============================================================
// forceRouteToAirPods
// ============================================================

static __attribute__((used)) void forceRouteToAirPods(int reason) {
    static NSTimeInterval lastCall = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastCall < 5.0) return;
    lastCall = now;
    apv_log(@"APV: overrideToPartnerRoute trigger reason=%d", reason);

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    if ([avc respondsToSelector:@selector(overrideToPartnerRoute)]) {
        [avc overrideToPartnerRoute];
        apv_log(@"APV: overrideToPartnerRoute done");
    } else {
        apv_log(@"APV: overrideToPartnerRoute not available, trying setPickedRoute");
        id rc = [[NSClassFromString(@"MPAVRoutingController") alloc] init];
        [rc fetchAvailableRoutesWithCompletionHandler:^(NSArray *routes) {
            id target = nil;
            for (id r in routes) {
                id desc = [r valueForKey:@"routeDescription"];
                if (!desc) {
                    NSString *type = [r valueForKey:@"routeType"];
                    if ([type isEqualToString:@"BluetoothA2DP"] || [type isEqualToString:@"BluetoothHFP"] || [type isEqualToString:@"BluetoothLE"]) {
                        target = r; break;
                    }
                    continue;
                }
                NSArray *outs = [desc valueForKey:@"outputs"];
                for (id out in outs) {
                    NSString *pt = [out valueForKey:@"portType"];
                    if ([pt isEqualToString:AVAudioSessionPortBluetoothA2DP]
                     || [pt isEqualToString:AVAudioSessionPortBluetoothHFP]
                     || [pt isEqualToString:AVAudioSessionPortBluetoothLE]) {
                        target = r; break;
                    }
                }
                if (target) break;
            }
            if (!target) { apv_log(@"APV: no BT route in available routes"); return; }
            apv_log(@"APV: setPickedRouteWithPassword %@", [target valueForKey:@"routeName"]);
            [avc setPickedRouteWithPassword:target withPassword:nil];
            apv_log(@"APV: setPickedRouteWithPassword done");
        }];
    }
}

// ============================================================
// %ctor
// ============================================================

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    isSpringBoard = [bid isEqualToString:@"com.apple.springboard"];
    isMediaserverd = [bid isEqualToString:@"com.apple.mediaserverd"];

    if (isSpringBoard) {
        updateAirPodsCache();
        notify_register_check(kDarwinNotifyName, &_airpodsStateToken);
        apv_log(@"APV: SB notify_register_check token=%d", _airpodsStateToken);

        [[NSNotificationCenter defaultCenter] addObserver:[objc_getClass("AVAudioSession") sharedInstance]
                                                 selector:@selector(airpods_routeChangeForState:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];

        apv_log(@"APV: SpringBoard v1.7.0 initialized");
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
                if (sAirPodsConnected && !sAirPodsCurrentRoute) {
                    apv_log(@"APV: media notify force: AirPods connected but not current route");
                    forceRouteToAirPods(200);
                } else if (sAirPodsConnected) {
                    apv_log(@"APV: media notify setActive:YES");
                    [[AVAudioSession sharedInstance] setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
                }
            });
        apv_log(@"APV: media notify_register status=%u token=%d", status, _airpodsStateToken);

        // Periodic check: AirPods might connect without triggering any notification
        // Every 10 seconds, verify: if AirPods available but not current route → force
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        __block int tickCount = 0;
        dispatch_source_set_event_handler(timer, ^{
            tickCount++;
            if (tickCount % 6 == 0) apv_log(@"APV: media timer heartbeat #%d, cached=%d", tickCount, sAirPodsCached);
            updateAirPodsCache();
            if (!sAirPodsCached) return;
            // AirPods are somewhere in the system — are they the current route?
            AVAudioSessionRouteDescription *cur = [AVAudioSession sharedInstance].currentRoute;
            BOOL curIsBT = NO;
            for (AVAudioSessionPortDescription *p in cur.outputs) {
                if (isBluetoothPort(p)) { curIsBT = YES; break; }
            }
            if (curIsBT) {
                // AirPods are the current route, update state
                writeAirPodsCache(YES, YES);
            } else {
                // AirPods connected but NOT the current route → force
                apv_log(@"APV: media timer: AirPods available but not current route, forcing");
                writeAirPodsCache(YES, NO);
                forceRouteToAirPods(201);
            }
        });
        dispatch_resume(timer);
        apv_log(@"APV: media periodic timer started (10s)");

        apv_log(@"APV: mediaserverd v1.7.0 initialized");
    }
}
