#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MAX_VOLUME 0.4f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category;
- (BOOL)setActiveCategoryVolumeTo:(float)volume;
- (BOOL)getVolume:(float *)volume forCategory:(id)category;
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category;
- (id)activeCategory;
@end

static BOOL isNotificationCategory(id category) {
    if (!category) return NO;
    @try {
        NSString *s = [category description];
        return [s containsString:@"Ringtone"] ||
               [s containsString:@"Alert"] ||
               [s containsString:@"Ambient"];
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
            volume = MIN(volume, MAX_VOLUME);

            [duckLock lock];
            if (!mediaDucked) {
                [self getVolume:&savedMediaVolume forCategory:@"Audio/Video"];
                mediaDucked = YES;
            }
            [duckLock unlock];

            [self setVolumeTo:MAX_VOLUME forCategory:@"Audio/Video"];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @try {
                    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                    if (!isNotificationCategory([avc activeCategory])) {
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

- (BOOL)setActiveCategoryVolumeTo:(float)volume {
    @try {
        if (isAirPodsProConnected()) {
            id active = [self activeCategory];
            if (isNotificationCategory(active)) {
                volume = MIN(volume, MAX_VOLUME);
                [duckLock lock];
                if (!mediaDucked) {
                    [self getVolume:&savedMediaVolume forCategory:@"Audio/Video"];
                    mediaDucked = YES;
                }
                [duckLock unlock];
                [self setVolumeTo:MAX_VOLUME forCategory:@"Audio/Video"];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[AirPodsVolume] setActiveCategory exception: %@", e);
    }
    return %orig;
}

- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category {
    @try {
        if (isAirPodsProConnected() && delta > 0 && isNotificationCategory(category)) {
            float cur;
            if ([self getVolume:&cur forCategory:category] && cur >= MAX_VOLUME) {
                return YES;
            }
        }
    } @catch (NSException *e) {}
    return %orig;
}

%end

%ctor {
    duckLock = [[NSLock alloc] init];
    NSLog(@"[AirPodsVolume] installed v2");
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
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
                    NSLog(@"[AirPodsVolume] AirPods Pro gone, ringtone 100%%");
                }
            } @catch (NSException *e) {
                NSLog(@"[AirPodsVolume] route change exception: %@", e);
            }
        }];
    }
}
