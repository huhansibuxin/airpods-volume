#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Shared state via Darwin notification, no AVAudioSession in mediaserverd
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
    CFNumberRef num = (CFNumberRef)d;
    int val = 0;
    if (num && CFNumberGetValue(num, kCFNumberIntType, &val))
        airPodsConnected = (BOOL)val;
}

%ctor {
    // Listen for state changes from SpringBoard (works in all processes incl mediaserverd)
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, onStateChanged, kAPNotify, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        // Init state from current route
        AVAudioSession *s = [AVAudioSession sharedInstance];
        BOOL connected = NO;
        for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
            if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                connected = YES;
        }
        airPodsConnected = connected;
        int val = connected ? 1 : 0;
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &val);
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), kAPNotify, (__bridge const void *)num, NULL, YES);
        CFRelease(num);

        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        if (!connected) {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }

        // Listen for route changes
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            BOOL now = NO;
            for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
                if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                    now = YES;
            }
            if (now != airPodsConnected) {
                airPodsConnected = now;
                int v = now ? 1 : 0;
                CFNumberRef n2 = CFNumberCreate(NULL, kCFNumberIntType, &v);
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(), kAPNotify, (__bridge const void *)n2, NULL, YES);
                CFRelease(n2);
                if (!now) {
                    [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                    [avc setVolumeTo:1.0f forCategory:@"Alert"];
                }
            }
        }];
    }
}
