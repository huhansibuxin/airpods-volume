#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <substrate.h>

// Hook 2: AVSystemController - redirect route picking to AirPods + volume control
%hook AVSystemController
// Minimal test: just pass-through
- (void)setPickedRouteWithPassword:(id)route withPassword:(id)password { %orig; }
- (BOOL)changeActiveCategoryVolumeBy:(float)delta forRoute:(id)route andDeviceIdentifier:(id)identifier { return %orig; }
- (BOOL)changeVolumeForRouteBy:(float)delta forCategory:(id)category mode:(id)mode route:(id)route deviceIdentifier:(id)identifier andRouteSubtype:(id)subtype { return %orig; }
%end

// ============================================================
// Constructor
// ============================================================

%ctor {
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        updateAirPodsCache();

        // Dump routing-related methods once
        static dispatch_once_t onceDump;
        dispatch_once(&onceDump, ^{
            apv_log(@"APV: === METHOD DUMP ===");
            Class cls = NSClassFromString(@"MPAVRoutingController");
            if (cls) {
                unsigned int count;
                Method *methods = class_copyMethodList(cls, &count);
                for (unsigned int i = 0; i < count; i++) {
                    SEL sel = method_getName(methods[i]);
                    apv_log(@"APV: MPAVRoutingController.%s", sel_getName(sel));
                }
                free(methods);
            }
            cls = NSClassFromString(@"AVSystemController");
            if (cls) {
                unsigned int count;
                Method *methods = class_copyMethodList(cls, &count);
                for (unsigned int i = 0; i < count; i++) {
                    SEL sel = method_getName(methods[i]);
                    const char *n = sel_getName(sel);
                    if (strstr(n, "oute") || strstr(n, "ick") || strstr(n, "elect") || strstr(n, "etActive") || strstr(n, "ttribute"))
                        apv_log(@"APV: AVSystemController.%s", n);
                }
                free(methods);
            }
            apv_log(@"APV: === END DUMP ===");
        });

        id avc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
        if (!isAirPodsConnected()) {
            [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
            [avc setVolumeTo:1.0f forCategory:@"Alert"];
        }

        static NSOperationQueue *sRouteQueue = nil;
        sRouteQueue = [[NSOperationQueue alloc] init];
        sRouteQueue.maxConcurrentOperationCount = 1;
        sRouteQueue.name = @"com.apv.route";
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:sRouteQueue usingBlock:^(NSNotification *n) {
            NSNumber *reasonNum = n.userInfo[AVAudioSessionRouteChangeReasonKey];
            NSInteger reason = reasonNum ? [reasonNum integerValue] : 0;
            apv_log(@"APV: route changed, reason=%ld, current=%@", (long)reason, [[s.currentRoute.outputs valueForKey:@"portName"] componentsJoinedByString:@", "]);
            
            updateAirPodsCache();
            BOOL now = isAirPodsCurrentRoute();
            BOOL connected = isAirPodsConnected();

            if (now) {
                float cur;
                if ([avc getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                    [avc setVolumeTo:0.4f forCategory:@"Ringtone"];
                if ([avc getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                    [avc setVolumeTo:0.4f forCategory:@"Alert"];
            } else if (connected) {
                forceRouteToAirPods((int)reason);
            } else {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
        }];
    }
}
