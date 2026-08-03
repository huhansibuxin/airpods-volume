#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>
#import <substrate.h>

#define kDarwinNotifyName "com.apv.airpods.state"
#define kVolumeCap 0.4f

static BOOL isSpringBoard = NO;
static BOOL isMediaserverd = NO;
static int _airpodsStateToken = -1;

static BOOL sAirPodsConnected = NO;
static BOOL sAirPodsCurrentRoute = NO;

static void readAirPodsCache(void) {
    uint64_t state = 0;
    if (notify_get_state(_airpodsStateToken, &state) == NOTIFY_STATUS_OK) {
        sAirPodsConnected = (state & 1);
        sAirPodsCurrentRoute = (state & 2);
    }
}

static void writeAirPodsCache(BOOL connected, BOOL current) {
    uint64_t state = (connected ? 1 : 0) | (current ? 2 : 0);
    notify_set_state(_airpodsStateToken, state);
    sAirPodsConnected = connected;
    sAirPodsCurrentRoute = current;
}

static void updateAirPodsCache(void) {
    if (!isSpringBoard) return;
    BOOL connected = NO;
    BOOL current = NO;
    for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
        if ([p.portName containsString:@"AirPods"]) { connected = YES; break; }
    }
    for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].currentRoute.outputs) {
        if ([p.portName containsString:@"AirPods"]) { current = YES; break; }
    }
    writeAirPodsCache(connected, current);
    notify_post(kDarwinNotifyName);
}

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

static BOOL isAirPodsConnected(void) {
    readAirPodsCache();
    return sAirPodsConnected;
}

static BOOL isAirPodsCurrentRoute(void) {
    readAirPodsCache();
    return sAirPodsCurrentRoute;
}

static float applyVolumeCap(float vol) {
    if (isAirPodsConnected())
        return MIN(vol, kVolumeCap);
    return 1.0f;
}

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
- (BOOL)changeVolumeBy:(float)v forCategory:(id)c;
- (BOOL)getVolume:(float *)v forCategory:(id)c;
- (void)overrideToPartnerRoute;
- (void)setPickedRouteWithPassword:(id)route withPassword:(id)password;
- (id)pickableRoutesForCategory:(NSString *)category andMode:(NSString *)mode;
- (BOOL)changeActiveCategoryVolumeBy:(float)delta forRoute:(id)route andDeviceIdentifier:(id)identifier;
- (BOOL)changeVolumeForRouteBy:(float)delta forCategory:(id)category mode:(id)mode route:(id)route deviceIdentifier:(id)identifier andRouteSubtype:(id)subtype;
@end

typedef int (*AudioSessionSetProperty_t)(unsigned int, unsigned int, const void *);

static int (*original_AudioSessionSetProperty)(unsigned int, unsigned int, const void *) = NULL;

static int hooked_AudioSessionSetProperty(unsigned int inID, unsigned int inDataSize, const void *inData) {
    readAirPodsCache();
    if (sAirPodsConnected && inID == 'ovrt' && inDataSize >= sizeof(unsigned int)) {
        unsigned int route = *(unsigned int *)inData;
        if (route == 'spkr') {
            return original_AudioSessionSetProperty(inID, inDataSize, inData);
        }
    }
    return original_AudioSessionSetProperty(inID, inDataSize, inData);
}

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
