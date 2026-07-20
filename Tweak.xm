#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MIN_VOLUME 0.05f
#define MAX_NOTIFY_VOLUME 0.5f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category;
- (BOOL)setActiveCategoryVolumeTo:(float)volume;
- (BOOL)getVolume:(float *)volume forCategory:(id)category;
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category;
@end

static float getMediaVolume(void) {
    id c = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    float v = 0.5f;
    [c getVolume:&v forCategory:@"Audio/Video"];
    return v;
}

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

static float clampNotifyVolume(void) {
    float mv = getMediaVolume();
    float cap = mv - 0.2f;
    if (cap > MAX_NOTIFY_VOLUME) cap = MAX_NOTIFY_VOLUME;
    if (cap < MIN_VOLUME) cap = MIN_VOLUME;
    return cap;
}

%hook AVSystemController

- (BOOL)setVolumeTo:(float)volume forCategory:(id)category {
    NSString *cd = [category description];
    if (isBluetoothConnected() && isNotificationCategory(category)) {
        float cap = clampNotifyVolume();
        volume = MIN(volume, cap);
        NSLog(@"[AV] notify %.2f -> cap %.2f (media=%.2f) cat=%@", volume, cap, getMediaVolume(), cd);
    }
    return %orig;
}

- (BOOL)setActiveCategoryVolumeTo:(float)volume {
    if (isBluetoothConnected()) {
        float cap = clampNotifyVolume();
        volume = MIN(volume, cap);
    }
    return %orig;
}

- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category {
    if (isBluetoothConnected() && delta > 0 && isNotificationCategory(category)) {
        float cur;
        float cap = clampNotifyVolume();
        if ([self getVolume:&cur forCategory:category] && cur >= cap) {
            return YES;
        }
    }
    return %orig;
}

%end

%ctor {
    NSLog(@"[AirPodsVolume] installed (notify < media-20%%, max 50%%)");
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                       object:nil queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        NSInteger reason = [[note.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
        if (reason == 1) {
            id c = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
            [c setVolumeTo:1.0f forCategory:@"Ringtone"];
            [c setVolumeTo:1.0f forCategory:@"Alert"];
            NSLog(@"[AirPodsVolume] BT gone, ringtone 100%%");
        }
    }];
}
