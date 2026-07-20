#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MAX_VOLUME 0.4f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category;
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
               [s containsString:@"PhoneCall"] ||
               [s containsString:@"VoIP"] ||
               [s containsString:@"Communication"];
    } @catch (NSException *e) {
        return NO;
    }
}

static BOOL isActiveCallRelated(AVSystemController *avc) {
    @try {
        NSString *s = [[avc activeCategory] description];
        return [s containsString:@"PhoneCall"] ||
               [s containsString:@"VoIP"] ||
               [s containsString:@"Communication"];
    } @catch (NSException *e) {}
    return NO;
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
    } @catch (NSException *e) {}
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
        BOOL shouldCap = NO;
        if (isAirPodsProConnected()) {
            if (isNotificationCategory(category)) {
                shouldCap = YES;
            }
            else if (isActiveCallRelated(self)) {
                // During a call (WeChat etc), any volume change (incl Audio/Video) must be capped
                NSString *s = [category description];
                if ([s containsString:@"Audio/Video"] || [s containsString:@"AVMedia"]) {
                    shouldCap = YES;
                }
            }
        }
        if (shouldCap) {
            volume = MIN(volume, MAX_VOLUME);
            [duckLock lock];
            if (!mediaDucked) {
                [self getVolume:&savedMediaVolume forCategory:@"Audio/Video"];
                mediaDucked = YES;
            }
            [duckLock unlock];
            [self setVolumeTo:MAX_VOLUME forCategory:@"Audio/Video"];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @try {
                    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                    if (!isActiveCallRelated(avc)) {
                        [duckLock lock];
                        float restore = savedMediaVolume;
                        mediaDucked = NO;
                        [duckLock unlock];
                        [avc setVolumeTo:restore forCategory:@"Audio/Video"];
                    }
                } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
    return %orig;
}

- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category {
    @try {
        if (isAirPodsProConnected() && delta > 0) {
            if (isNotificationCategory(category) || isActiveCallRelated(self)) {
                float cur;
                if ([self getVolume:&cur forCategory:category] && cur >= MAX_VOLUME) {
                    return YES;
                }
            }
        }
    } @catch (NSException *e) {}
    return %orig;
}

%end


%group SpringBoardHUD

static void suppressVolumeHUDs(void) {
    // Left-side media volume HUD
    Class leftHUD = NSClassFromString(@"_UIVolumeHUDViewController");
    if (leftHUD) {
        MSHookMessageEx(leftHUD,
            @selector(setVisible:animated:),
            imp_implementationWithBlock(^(id self, BOOL v, BOOL a) { return; }),
            NULL);
    }

    // Left-side HUD view fallback
    Class leftView = NSClassFromString(@"_UIVolumeHUDView");
    if (leftView) {
        MSHookMessageEx(leftView,
            @selector(showAtPoint:),
            imp_implementationWithBlock(^(id self, CGPoint p) { return; }),
            NULL);
    }

    // Dynamic Island ringer HUD
    Class dinHUD = NSClassFromString(@"_UIRingerHUDViewController");
    if (dinHUD) {
        MSHookMessageEx(dinHUD,
            @selector(presentHUDWithVolume:),
            imp_implementationWithBlock(^(id self, float v) { return; }),
            NULL);
    }
}

%end

%ctor {
    duckLock = [[NSLock alloc] init];
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        suppressVolumeHUDs();
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
                }
            } @catch (NSException *e) {}
        }];
    }
}
