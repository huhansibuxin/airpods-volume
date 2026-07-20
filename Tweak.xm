#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

static BOOL airPodsConnected = NO;
#define kAPNotify CFSTR("com.airpodsvolume.state")

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
@end

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    if (isNotificationCategory(cat)) {
        if (airPodsConnected)
            vol = MIN(vol, 0.4f);
        else
            vol = 1.0f;
    }
    return %orig;
}
%end

static void onStateChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *d, CFDictionaryRef u) {
    airPodsConnected = ((int)(intptr_t)d == 1);
}

static void postState(int connected) {
    int v = connected;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(), kAPNotify,
        (const void *)(intptr_t)v, NULL, YES);
}

%ctor {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, onStateChanged, kAPNotify, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        BOOL connected = NO;
        for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
            if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                connected = YES;
        }
        airPodsConnected = connected;
        postState(connected);

        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        if (!connected) {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            BOOL now = NO;
            for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
                if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                    now = YES;
            }
            if (now != airPodsConnected) {
                airPodsConnected = now;
                postState(now);
                if (!now) {
                    [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                    [avc setVolumeTo:1.0f forCategory:@"Alert"];
                }
            }
        }];
    }
}
