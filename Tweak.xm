#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MAX_VOLUME 0.4f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category;
- (BOOL)getVolume:(float *)volume forCategory:(id)category;
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category;
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

%hook AVSystemController

- (BOOL)setVolumeTo:(float)volume forCategory:(id)category {
    if (isBluetoothConnected() && isNotificationCategory(category)) {
        volume = MIN(volume, MAX_VOLUME);
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
    NSLog(@"[AirPodsVolume] installed, cap 40%%");
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if ([proc isEqualToString:@"SpringBoard"]) {
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
}
