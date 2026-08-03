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

static void forceRouteToAirPods(int reason) {
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
            if ([[r valueForKey:@"isAirpodsRoute"] boolValue]) {
                target = r;
                break;
            }
        }
        if (!target) {
            apv_log(@"APV: no AirPods in available routes");
            return;
        }
        apv_log(@"APV: setPickedRouteWithPassword %@", [target valueForKey:@"routeName"]);
        [avc setPickedRouteWithPassword:target withPassword:nil];
        lastForceSuccess = [[NSDate date] timeIntervalSince1970];
        apv_log(@"APV: setPickedRouteWithPassword done");
    }];
}


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
