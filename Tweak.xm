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
// Minimal test: just pass-through
- (void)setPickedRouteWithPassword:(id)route withPassword:(id)password { %orig; }
- (BOOL)changeActiveCategoryVolumeBy:(float)delta forRoute:(id)route andDeviceIdentifier:(id)identifier { return %orig; }
- (BOOL)changeVolumeForRouteBy:(float)delta forCategory:(id)category mode:(id)mode route:(id)route deviceIdentifier:(id)identifier andRouteSubtype:(id)subtype { return %orig; }
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
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        updateAirPodsCache();

        // Dump routing-related methods once
        static dispatch_once_t onceDump;
        dispatch_once(&onceDump, ^{
            apv_log(@"APV: === METHOD DUMP ===");
            Class cls = NSClassFromString(@"MPAVRoutingController");
            if (cls) {
                unsigned int count;
                Method *methods = class_copyMethodList(cls, &count);
                for (unsigned int i = 0; i < count; i++) {
                    SEL sel = method_getName(methods[i]);
                    apv_log(@"APV: MPAVRoutingController.%s", sel_getName(sel));
                }
                free(methods);
            }
            cls = NSClassFromString(@"AVSystemController");
            if (cls) {
                unsigned int count;
                Method *methods = class_copyMethodList(cls, &count);
                for (unsigned int i = 0; i < count; i++) {
                    SEL sel = method_getName(methods[i]);
                    const char *n = sel_getName(sel);
                    if (strstr(n, "oute") || strstr(n, "ick") || strstr(n, "elect") || strstr(n, "etActive") || strstr(n, "ttribute"))
                        apv_log(@"APV: AVSystemController.%s", n);
                }
                free(methods);
            }
            apv_log(@"APV: === END DUMP ===");
        });

        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        if (!isAirPodsConnected()) {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }

        static NSOperationQueue *sRouteQueue = nil;
        sRouteQueue = [[NSOperationQueue alloc] init];
        sRouteQueue.maxConcurrentOperationCount = 1;
        sRouteQueue.name = @"com.apv.route";
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:sRouteQueue usingBlock:^(NSNotification *n) {
            NSNumber *reasonNum = n.userInfo[AVAudioSessionRouteChangeReasonKey];
            NSInteger reason = reasonNum ? [reasonNum integerValue] : 0;
            apv_log(@"APV: route changed, reason=%ld, current=%@", (long)reason, [[s.currentRoute.outputs valueForKey:@"portName"] componentsJoinedByString:@", "]);
            
            updateAirPodsCache();
            BOOL now = isAirPodsCurrentRoute();
            BOOL connected = isAirPodsConnected();

            if (now) {
                float cur;
                if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                    [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
                if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                    [avc setVolumeTo:0.4f forCategory:@"Alert"];
            } else if (connected) {
                forceRouteToAirPods((int)reason);
            } else {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
        }];
    }
}
