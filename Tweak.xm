#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <pthread.h>
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


static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

static BOOL sAirPodsCached = NO;
static time_t sLastAirPodsSeen = 0;

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
        if (route == 'spkr') {
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
// mediaserverd: polling thread (pthread, no GCD/runloop dependency)
// ============================================================

static void *pollingThread(void *arg) {
    int tick = 0;
    while (1) {
        sleep(5);
        tick++;
        updateAirPodsCache();
        if (sAirPodsCached) {
            sLastAirPodsSeen = time(NULL);
            AVAudioSessionRouteDescription *cur = [AVAudioSession sharedInstance].currentRoute;
            BOOL curIsBT = NO;
            for (AVAudioSessionPortDescription *p in cur.outputs) {
                if (isBluetoothPort(p)) { curIsBT = YES; break; }
            }
            if (curIsBT) {
                writeAirPodsCache(YES, YES);
            } else {
                writeAirPodsCache(YES, NO);
                forceRouteToAirPods(201);
            }
        } else if (sLastAirPodsSeen > 0 && time(NULL) - sLastAirPodsSeen < 300) {
            forceRouteToAirPods(202);
        }
    }
    return NULL;
}

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

    BOOL isBT = NO;
    for (AVAudioSessionPortDescription *p in cur.outputs) {
        if (isBluetoothPort(p)) { isBT = YES; break; }
    }
    sAirPodsCached = isBT;
    writeAirPodsCache(sAirPodsCached, sAirPodsCached && isBT);

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
            isBT, btAvailable, (long)reason, force);
    if (force) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            forceRouteToAirPods((int)reason);
        });
    }
}
%end

// ============================================================
// forceRouteToAirPods
// ============================================================

static __attribute__((used)) void forceRouteToAirPods(int reason) {
    static NSTimeInterval lastCall = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastCall < 5.0) return;
    lastCall = now;

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    if ([avc respondsToSelector:@selector(overrideToPartnerRoute)]) {
        [avc overrideToPartnerRoute];
    } else {
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
            [avc setPickedRouteWithPassword:target withPassword:nil];
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

        [[NSNotificationCenter defaultCenter] addObserver:[objc_getClass("AVAudioSession") sharedInstance]
                                                 selector:@selector(airpods_routeChangeForState:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];

    }

    if (isMediaserverd) {
        void *aHandle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
        if (aHandle) {
            void *sym = dlsym(aHandle, "AudioSessionSetProperty");
            if (sym && original_AudioSessionSetProperty == NULL) {
                MSHookFunction(sym, (void *)hooked_AudioSessionSetProperty, (void **)&original_AudioSessionSetProperty);
            }
            dlclose(aHandle);
        }

        uint32_t status = notify_register_dispatch(kDarwinNotifyName, &_airpodsStateToken,
            dispatch_get_main_queue(), ^(int token) {
                readAirPodsCache();
                if (sAirPodsConnected) sLastAirPodsSeen = time(NULL);
                if (sAirPodsConnected && !sAirPodsCurrentRoute) {
                    forceRouteToAirPods(200);
                } else if (sAirPodsConnected) {
                    [[AVAudioSession sharedInstance] setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
                }
            });

        pthread_t pt;
        pthread_create(&pt, NULL, pollingThread, NULL);
        pthread_detach(pt);

    }
}
