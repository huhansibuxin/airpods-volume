#import <substrate.h>
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

static void updateAirPodsCache(void) {
    sAirPodsCached = NO;
    for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
        if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"]) {
            sAirPodsCached = YES;
            break;
        }
    }
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
    updateAirPodsCache();
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
        if (isSpringBoard) {
            updateAirPodsCache();

            [[NSNotificationCenter defaultCenter] addObserver:[objc_getClass("AVAudioSession") sharedInstance]
                                                     selector:@selector(airpods_routeChangeForState:)
                                                         name:AVAudioSessionRouteChangeNotification
                                                       object:nil];

            NSLog(@"[AirPodsVolume] SpringBoard v1.0: volume control + state detection");
        }
    }
}