#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define MAX_VOLUME 0.4f

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
@end

static BOOL isAirPodsProConnected(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (!s) return NO;
    for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
        if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
            return YES;
    }
    return NO;
}

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    if (isAirPodsProConnected() && isNotificationCategory(cat))
        vol = MIN(vol, MAX_VOLUME);
    return %orig;
}
%end

%ctor {
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            AVAudioSessionRouteDescription *prev = n.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
            BOOL wasAirPods = NO;
            for (AVAudioSessionPortDescription *p in prev.outputs) {
                if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                    wasAirPods = YES;
            }
            if (wasAirPods) {
                id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
        }];
    }
}
