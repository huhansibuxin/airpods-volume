#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MAX_VOLUME 0.4f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
@end

static BOOL isBluetoothConnected(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs) {
        NSString *type = port.portType;
        if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            return YES;
        }
    }
    return NO;
}

%hook AVSystemController
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category {
    if (isBluetoothConnected()) {
        volume = MIN(volume, MAX_VOLUME);
    }
    return %orig;
}

- (BOOL)setActiveCategoryVolumeTo:(float)volume {
    if (isBluetoothConnected()) {
        volume = MIN(volume, MAX_VOLUME);
    }
    return %orig;
}
%end

%ctor {
    NSLog(@"[AirPodsVolume] Hooks installed, max volume capped at 40%% when Bluetooth connected");
}
