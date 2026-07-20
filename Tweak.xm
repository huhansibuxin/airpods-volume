#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

static BOOL airPodsConnected = NO;

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
            vol = 1.0f; // always 100% without AirPods
    }
    return %orig;
}
%end

%ctor {
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        // Init state
        AVAudioSession *s = [AVAudioSession sharedInstance];
        for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
            if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                airPodsConnected = YES;
        }

        // Keep it at 100% initially
        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        if (!airPodsConnected) {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }

        // Listen for connect/disconnect
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            BOOL nowConnected = NO;
            for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
                if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                    nowConnected = YES;
            }
            if (nowConnected != airPodsConnected) {
                airPodsConnected = nowConnected;
                if (!nowConnected)
                    [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                    [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
        }];
    }
}
