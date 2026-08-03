#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <substrate.h>

// ============================================================
// Config
// ============================================================
static const float kVolumeCap = 0.0625;
static const char *kDarwinNotifyName = "com.huhansibuxin.airpodsvolume.state";

// ============================================================
// Process detection
// ============================================================
static BOOL isSpringBoard = NO;
static BOOL isMediaserverd = NO;

// ============================================================
// AirPods state cache
// ============================================================
static BOOL sAirPodsConnected = NO;
static BOOL sAirPodsCurrentRoute = NO;
static int _airpodsStateToken = -1;

static void updateAirPodsCache(void) {
    if (!isSpringBoard) return;

    AVAudioSession *session = [AVAudioSession sharedInstance];

    BOOL found = NO;
    for (AVAudioSessionPortDescription *input in session.availableInputs) {
        if ([input.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [input.portType isEqualToString:AVAudioSessionPortBluetoothA2DP]) {
            found = YES;
            break;
        }
    }

    BOOL isCurrent = NO;
    for (AVAudioSessionPortDescription *output in session.currentRoute.outputs) {
        if ([output.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [output.portType isEqualToString:AVAudioSessionPortBluetoothA2DP]) {
            isCurrent = YES;
            break;
        }
    }

    sAirPodsConnected = found;
    sAirPodsCurrentRoute = isCurrent;

    uint64_t state = (found ? 1 : 0) | (isCurrent ? 2 : 0);
    notify_set_state(_airpodsStateToken, state);
    notify_post(kDarwinNotifyName);

    NSLog(@"[AirPodsVolume] State: connected=%d currentRoute=%d", found, isCurrent);
}

static void readAirPodsCache(void) {
    uint64_t state = 0;
    notify_get_state(_airpodsStateToken, &state);
    sAirPodsConnected = (state & 1) != 0;
    sAirPodsCurrentRoute = (state & 2) != 0;
}

// ============================================================
// Forward declarations
// ============================================================
@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)changeActiveCategoryVolumeBy:(float)delta forRoute:(id)route andDeviceIdentifier:(id)identifier;
- (BOOL)changeVolumeForRouteBy:(float)delta forCategory:(id)category mode:(id)mode route:(id)route deviceIdentifier:(id)identifier andRouteSubtype:(id)subtype;
- (id)pickableRoutesForCategory:(id)category andMode:(id)mode;
@end

// ============================================================
// C API hook: AudioSessionSetProperty
// ============================================================
typedef UInt32 AudioSessionPropertyID;
static const AudioSessionPropertyID kPropertyOverrideAudioRoute = 'ovrd';

typedef OSStatus (*AudioSessionSetProperty_t)(AudioSessionPropertyID inID,
    UInt32 inDataSize, const void *inData);
static AudioSessionSetProperty_t original_AudioSessionSetProperty = NULL;

static OSStatus hooked_AudioSessionSetProperty(AudioSessionPropertyID inID,
    UInt32 inDataSize, const void *inData) {
    if (isMediaserverd && inID == kPropertyOverrideAudioRoute && inDataSize == sizeof(UInt32)) {
        UInt32 override = *(const UInt32 *)inData;
        if (override == 'spkr') {  // kAudioSessionOverrideAudioRoute_Speaker
            readAirPodsCache();
            if (sAirPodsConnected) {
                NSLog(@"[AirPodsVolume] Blocked AudioSessionSetProperty override to speaker");
                return 0;
            }
        }
    }
    return original_AudioSessionSetProperty(inID, inDataSize, inData);
}

// ============================================================
// mediaserverd: Route switching hooks
// ============================================================

// Hook 1: AVAudioSessionRouteDescription - mark AirPods routes as active
%hook AVAudioSessionRouteDescription
- (id)initWithRouteDictionary:(NSDictionary *)dict {
    if (!isMediaserverd) return %orig;

    readAirPodsCache();
    if (!sAirPodsConnected) return %orig;

    NSMutableDictionary *mDict = [dict mutableCopy];
    for (NSString *key in @[@"Inputs", @"Outputs"]) {
        NSArray *ports = mDict[key];
        if (!ports) continue;
        NSMutableArray *mPorts = [ports mutableCopy];
        for (NSUInteger i = 0; i < mPorts.count; i++) {
            NSMutableDictionary *port = [mPorts[i] mutableCopy];
            NSString *type = port[@"RouteType"] ?: port[@"routeType"];
            if ([type isEqualToString:@"BluetoothHFP"] || [type isEqualToString:@"BluetoothA2DP"]) {
                port[@"Active"] = @YES;
            }
            mPorts[i] = port;
        }
        mDict[key] = mPorts;
    }
    return %orig(mDict);
}
%end

// Hook 2: AVSystemController - redirect route picking to AirPods + volume control
%hook AVSystemController
- (void)setPickedRouteWithPassword:(id)route withPassword:(id)password {
    if (!isMediaserverd) { %orig; return; }

    readAirPodsCache();
    if (!sAirPodsConnected || sAirPodsCurrentRoute) { %orig; return; }

    // AirPods connected but not current → try to redirect to AirPods route
    id routes = [self pickableRoutesForCategory:@"AVAudioSessionCategoryPlayback" andMode:@"AVAudioSessionModeDefault"];
    if (![routes isKindOfClass:[NSArray class]]) { %orig; return; }

    for (id r in (NSArray *)routes) {
        NSString *type = [r valueForKey:@"routeType"] ?: [r valueForKey:@"type"];
        if (type && ([type isEqualToString:@"BluetoothHFP"] || [type isEqualToString:@"BluetoothA2DP"])) {
            // Redirect: pick AirPods route instead of whatever was requested
            %orig(r, password);
            NSLog(@"[AirPodsVolume] media: redirected setPickedRoute to AirPods");
            return;
        }
    }
    %orig;
}

// Volume control (both processes, reads cached state)
- (BOOL)changeActiveCategoryVolumeBy:(float)delta forRoute:(id)route andDeviceIdentifier:(id)identifier {
    if (sAirPodsConnected && delta > 0) {
        static float sApproxVolume = 0.1;
        float maxDelta = kVolumeCap - sApproxVolume;
        if (maxDelta <= 0) {
            return YES;
        }
        if (maxDelta < delta) delta = maxDelta;
        BOOL result = %orig(delta, route, identifier);
        if (result) {
            sApproxVolume += delta;
            if (sApproxVolume > kVolumeCap) sApproxVolume = kVolumeCap;
        }
        return result;
    }
    return %orig;
}

- (BOOL)changeVolumeForRouteBy:(float)delta forCategory:(id)category mode:(id)mode route:(id)route deviceIdentifier:(id)identifier andRouteSubtype:(id)subtype {
    if (sAirPodsConnected && delta > 0) {
        static float sApproxVolume2 = 0.1;
        float maxDelta = kVolumeCap - sApproxVolume2;
        if (maxDelta <= 0) return YES;
        if (maxDelta < delta) delta = maxDelta;
        BOOL result = %orig(delta, category, mode, route, identifier, subtype);
        if (result) {
            sApproxVolume2 += delta;
            if (sApproxVolume2 > kVolumeCap) sApproxVolume2 = kVolumeCap;
        }
        return result;
    }
    return %orig;
}
%end

// SpringBoard: route change for state tracking only
%hook AVAudioSession
%new
- (void)airpods_routeChangeForState:(NSNotification *)notification {
    updateAirPodsCache();
}
%end

// ============================================================
// Constructor
// ============================================================
%ctor {
    isSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    isMediaserverd = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mediaserverd"];

    if (isSpringBoard || isMediaserverd) {
        notify_register_check(kDarwinNotifyName, &_airpodsStateToken);

        if (isSpringBoard) {
            updateAirPodsCache();

            [[NSNotificationCenter defaultCenter] addObserver:[objc_getClass("AVAudioSession") sharedInstance]
                                                     selector:@selector(airpods_routeChangeForState:)
                                                         name:AVAudioSessionRouteChangeNotification
                                                       object:nil];

            NSLog(@"[AirPodsVolume] SpringBoard v1.0: volume control + state detection");
        }

        if (isMediaserverd) {
            AudioSessionSetProperty_t func = (AudioSessionSetProperty_t)dlsym(RTLD_DEFAULT, "AudioSessionSetProperty");
            if (func) {
                MSHookFunction(func, (void *)hooked_AudioSessionSetProperty, (void **)&original_AudioSessionSetProperty);
            }

            dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
            int token;
            notify_register_dispatch(kDarwinNotifyName, &token, q, ^(int t) {
                readAirPodsCache();
                if (!sAirPodsConnected || sAirPodsCurrentRoute) return;

                static CFAbsoluteTime lastForce = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastForce < 3.0) return;
                lastForce = now;

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), q, ^{
                    readAirPodsCache();
                    if (!sAirPodsConnected || sAirPodsCurrentRoute) return;

                    AVSystemController *avs = [objc_getClass("AVSystemController") sharedAVSystemController];
                    id routes = [avs pickableRoutesForCategory:@"AVAudioSessionCategoryPlayback" andMode:@"AVAudioSessionModeDefault"];
                    if (![routes isKindOfClass:[NSArray class]]) return;

                    for (id r in (NSArray *)routes) {
                        NSString *type = [r valueForKey:@"routeType"] ?: [r valueForKey:@"type"];
                        if (type && ([type isEqualToString:@"BluetoothHFP"] || [type isEqualToString:@"BluetoothA2DP"])) {
                            [avs changeActiveCategoryVolumeBy:0 forRoute:r andDeviceIdentifier:nil];
                            NSLog(@"[AirPodsVolume] media: Darwin notify triggered force-route to AirPods");
                            break;
                        }
                    }
                });
            });

            NSLog(@"[AirPodsVolume] mediaserverd v1.0: route switching + volume control");
        }
    }
}
