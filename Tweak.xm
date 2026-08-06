#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
- (BOOL)changeVolumeBy:(float)v forCategory:(id)c;
- (BOOL)getVolume:(float *)v forCategory:(id)c;
@end

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

static BOOL isBluetoothPort(AVAudioSessionPortDescription *p) {
    NSString *type = p.portType;
    return [type isEqualToString:AVAudioSessionPortBluetoothA2DP]
        || [type isEqualToString:AVAudioSessionPortBluetoothHFP]
        || [type isEqualToString:AVAudioSessionPortBluetoothLE];
}

static BOOL sAirPodsConnected = NO;

static void updateAirPodsCache(void) {
    sAirPodsConnected = NO;
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *p in route.outputs) {
        if (isBluetoothPort(p)) {
            sAirPodsConnected = YES;
            break;
        }
    }
    if (!sAirPodsConnected) {
        for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs) {
            if (isBluetoothPort(p)) {
                sAirPodsConnected = YES;
                break;
            }
        }
    }
}

static float applyVolumeCap(float vol) {
    if (sAirPodsConnected)
        return MIN(vol, 0.4f);
    return 1.0f;
}

// ============================================================
// Volume cap: AVSystemController
// ============================================================

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
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig;
    if (r && isNotificationCategory(cat))
        *vol = applyVolumeCap(*vol);
    return r;
}
%end

// ============================================================
// Disable touch on volume HUD
// ============================================================

%hook SBHUDWindow
- (void)addSubview:(UIView *)view {
    view.userInteractionEnabled = NO;
    %orig;
}
%end

@interface SBElasticVolumeSliderView : UIView
@end
%hook SBElasticVolumeSliderView
- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    self.userInteractionEnabled = NO;
    return self;
}
%end

// ============================================================
// Hide replaykit CC modules
// ============================================================

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
// %ctor
// ============================================================

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.springboard"]) return;

    updateAirPodsCache();

    id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
    if (!sAirPodsConnected) {
        [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
        [avc setVolumeTo:1.0f forCategory:@"Alert"];
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        updateAirPodsCache();
        if (sAirPodsConnected) {
            float cur;
            if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
            if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                [avc setVolumeTo:0.4f forCategory:@"Alert"];
        } else {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }
    }];
}
