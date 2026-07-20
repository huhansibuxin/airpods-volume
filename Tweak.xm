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
    NSString *s = [category description];
    return [s containsString:@"Ringtone"] ||
           [s containsString:@"Alert"] ||
           [s containsString:@"SoloAmbient"] ||
           [s containsString:@"Ambient"];
}

static BOOL isBluetoothConnected(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
        NSString *t = p.portType;
        if ([t isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [t isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [t isEqualToString:AVAudioSessionPortBluetoothLE]) {
            return YES;
        }
    }
    return NO;
}

static float savedMediaVolume = 0.8f;
static BOOL mediaDucked = NO;

%hook AVSystemController

- (BOOL)setVolumeTo:(float)volume forCategory:(id)category {
    if (isBluetoothConnected()) {
        if (isNotificationCategory(category)) {
            volume = MIN(volume, MAX_VOLUME);
            if (!mediaDucked) {
                [self getVolume:&savedMediaVolume forCategory:@"Audio/Video"];
                mediaDucked = YES;
            }
            [self setVolumeTo:MAX_VOLUME forCategory:@"Audio/Video"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                if (!isNotificationCategory([avc activeCategory])) {
                    [avc setVolumeTo:savedMediaVolume forCategory:@"Audio/Video"];
                    mediaDucked = NO;
                }
            });
        }
    }
    return %orig;
}

- (BOOL)setActiveCategoryVolumeTo:(float)volume {
    if (isBluetoothConnected()) {
        id active = [self activeCategory];
        if (isNotificationCategory(active)) {
            volume = MIN(volume, MAX_VOLUME);
            if (!mediaDucked) {
                [self getVolume:&savedMediaVolume forCategory:@"Audio/Video"];
                mediaDucked = YES;
            }
            [self setVolumeTo:MAX_VOLUME forCategory:@"Audio/Video"];
        }
    }
    return %orig;
}

- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category {
    if (isBluetoothConnected() && delta > 0 && isNotificationCategory(category)) {
        float cur;
        if ([self getVolume:&cur forCategory:category] && cur >= MAX_VOLUME) {
            return YES;
        }
    }
    return %orig;
}

%end

%ctor {
    NSLog(@"[AirPodsVolume] installed, 3 hooks + duck media");
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                           object:nil queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification *note) {
            NSInteger reason = [[note.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
            NSLog(@"[AirPodsVolume] route change reason=%ld", (long)reason);
            if (reason == 1) {
                id c = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                [c setVolumeTo:1.0f forCategory:@"Ringtone"];
                [c setVolumeTo:1.0f forCategory:@"Alert"];
                [c setVolumeTo:savedMediaVolume forCategory:@"Audio/Video"];
            }
        }];
    }
}
