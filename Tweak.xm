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

- (BOOL)changeVolumeBy:(float)delta forCategory:(id)category {
    if (isBluetoothConnected() && delta > 0) {
        float current;
        if ([self getVolume:&current forCategory:category] && current >= MAX_VOLUME) {
            return YES;
        }
    }
    return %orig;
}

%end

%ctor {
    NSLog(@"[AirPodsVolume] Hooks installed, cap 40%% on Bluetooth");
}
