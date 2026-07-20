#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MAX_VOLUME 0.4f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category;
- (BOOL)getVolume:(float *)volume forCategory:(id)category;
@end

static BOOL isNotificationCategory(id category) {
    if (!category) return NO;
    @try {
        NSString *s = [category description];
        return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
    } @catch (NSException *e) {
        return NO;
    }
}

static BOOL isAirPodsProConnected(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (!s) return NO;
        for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
            if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"]) {
                return YES;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[AirPodsVolume] isAirPodsProConnected exception: %@", e);
    }
    return NO;
}

static BOOL routeHasAirPodsPro(AVAudioSessionRouteDescription *route) {
    if (!route) return NO;
    @try {
        for (AVAudioSessionPortDescription *p in route.outputs) {
            if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"]) {
                return YES;
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

static float savedMediaVolume = 0.8f;
static BOOL mediaDucked = NO;
static NSLock *duckLock = nil;

%hook AVSystemController

- (BOOL)setVolumeTo:(float)volume forCategory:(id)category {
    @try {
        if (isAirPodsProConnected() && isNotificationCategory(category)) {
            // Cap notification volume
            volume = MIN(volume, MAX_VOLUME);

            // Duck media volume: save and force to 40%
            [duckLock lock];
            if (!mediaDucked) {
                [self getVolume:&savedMediaVolume forCategory:@"Audio/Video"];
                mediaDucked = YES;
            }
            [duckLock unlock];
            [self setVolumeTo:MAX_VOLUME forCategory:@"Audio/Video"];

            // Restore after 5s if notification ended
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @try {
                    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                    float cur;
                    [avc getVolume:&cur forCategory:@"Ringtone"];
                    // If ringtone volume is still at cap, notification may still be active, skip restore
                    if (cur > MAX_VOLUME + 0.01f) {
                        [duckLock lock];
                        float restore = savedMediaVolume;
                        mediaDucked = NO;
                        [duckLock unlock];
                        [avc setVolumeTo:restore forCategory:@"Audio/Video"];
                    }
                } @catch (NSException *e) {
                    NSLog(@"[AirPodsVolume] restore exception: %@", e);
                }
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[AirPodsVolume] setVolumeTo exception: %@", e);
    }
    return %orig;
}

%end


%group SpringBoardHUD

// Left-side traditional volume HUD
%hook SBVolumeHUDView
- (void)showAnimated:(BOOL)animated { return; }
%end

// Dynamic Island ringer HUD
%hook SBHUDController
- (void)presentHUDView:(id)arg autoDismissWithDelay:(double)delay {
    if (delay < 10.0) return; // volume HUD dismisses fast, keep others
    %orig;
}
%end

%end

%ctor {
    duckLock = [[NSLock alloc] init];
    NSLog(@"[AirPodsVolume] installed, Ringtone/Alert only");
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        %init(SpringBoardHUD);
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                           object:nil queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification *note) {
            @try {
                AVAudioSessionRouteDescription *prev = [note.userInfo objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
                if (routeHasAirPodsPro(prev)) {
                    id c = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                    [c setVolumeTo:1.0f forCategory:@"Ringtone"];
                    [c setVolumeTo:1.0f forCategory:@"Alert"];
                    [c setVolumeTo:savedMediaVolume forCategory:@"Audio/Video"];
                    NSLog(@"[AirPodsVolume] AirPods Pro gone, restored 100%%");
                }
            } @catch (NSException *e) {
                NSLog(@"[AirPodsVolume] route change exception: %@", e);
            }
        }];
    }
}
