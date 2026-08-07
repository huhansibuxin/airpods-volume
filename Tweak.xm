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

@interface NCNotificationRequest : NSObject
- (NSString *)sectionIdentifier;
@end

@interface SBVolumeControl : NSObject
- (BOOL)increaseVolume;
- (BOOL)decreaseVolume;
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

static float capForCategory(id cat) {
    if (!sAirPodsConnected) return 1.0f;
    if (isNotificationCategory(cat)) return 0.4f;
    return 0.8f; // media + everything else: cap at 80%
}

// ============================================================
// SBVolumeControl: block hardware volume buttons
// ============================================================

%hook SBVolumeControl
- (BOOL)increaseVolume {
    if (sAirPodsConnected) {
        // read current volume via AVSystemController (any non-ringer cat)
        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        float cur;
        // try media categories that might give us actual media volume
        if ([avc getVolume:&cur forCategory:@"Audio/Video"] ||
            [avc getVolume:&cur forCategory:@"AVAudioSessionCategoryPlayback"] ||
            [avc getVolume:&cur forCategory:AVAudioSessionCategoryPlayback]) {
            if (cur >= 0.8f) return NO;
        }
    }
    return %orig;
}
%end

// ============================================================
// AVSystemController: catch CC slider + all volume paths
// ============================================================

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    float cap = capForCategory(cat);
    if (cap < 1.0f) vol = MIN(vol, cap);
    return %orig(vol, cat);
}
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)cat {
    float cap = capForCategory(cat);
    if (cap >= 1.0f) return %orig(delta, cat);
    float cur;
    if ([self getVolume:&cur forCategory:cat] && (cur + delta) > cap) {
        if (cur >= cap) return YES;
        return [self setVolumeTo:cap forCategory:cat];
    }
    return %orig(delta, cat);
}
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig(vol, cat);
    if (r) {
        float cap = capForCategory(cat);
        if (cap < 1.0f) *vol = MIN(*vol, cap);
    }
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
// Block Shortcuts automation notifications
// ============================================================

%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(NCNotificationRequest *)req {
    if ([[req sectionIdentifier] isEqualToString:@"com.apple.shortcuts"])
        return;
    %orig;
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
            [avc setVolumeTo:0.8f forCategory:@"Audio/Video"];
        } else {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }
    }];
}
