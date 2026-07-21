#import <substrate.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <fcntl.h>
#import <unistd.h>

#define STATE_FILE "/tmp/.airpods_state"

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)v forCategory:(id)c;
- (BOOL)setActiveCategoryVolumeTo:(float)v;
- (id)getActiveCategory:(BOOL)arg1;
- (BOOL)changeVolumeBy:(float)v forCategory:(id)c;
- (BOOL)getVolume:(float *)v forCategory:(id)c;
@end

static BOOL isNotificationCategory(id cat) {
    NSString *s = [cat description];
    return [s containsString:@"Ringtone"] || [s containsString:@"Alert"];
}

static BOOL readAirPodsState(void) {
    int fd = open(STATE_FILE, O_RDONLY);
    if (fd < 0) return NO;
    char c = '0';
    read(fd, &c, 1);
    close(fd);
    return c == '1';
}

static float applyVolumeCap(float vol) {
    if (readAirPodsState())
        return MIN(vol, 0.4f);
    return 1.0f;
}

%hook AVSystemController
- (BOOL)setVolumeTo:(float)vol forCategory:(id)cat {
    if (isNotificationCategory(cat))
        vol = applyVolumeCap(vol);
    return %orig;
}
- (BOOL)setActiveCategoryVolumeTo:(float)vol {
    id cat = [self getActiveCategory:YES];
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
%end

// HUD suppression: block system-triggered volume HUD, allow manual button presses
@interface SBHUDManager : NSObject
+ (instancetype)sharedInstance;
- (void)presentVolumeHUDForCategory:(NSString *)category reason:(NSString *)reason;
@end
%hook SBHUDManager
- (void)presentVolumeHUDForCategory:(NSString *)category reason:(NSString *)reason {
    if ([reason containsString:@"ExplicitVolumeChange"]) {
        %orig;
    }
}
%end

static void writeAirPodsState(BOOL connected) {
    int fd = open(STATE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char c = connected ? '1' : '0';
        write(fd, &c, 1);
        close(fd);
    }
}

%ctor {
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        BOOL connected = NO;
        for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
            if ([p.portName containsString:@"AirPods"] && [p.portName containsString:@"Pro"])
                connected = YES;
        }
        writeAirPodsState(connected);

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
            writeAirPodsState(now);
            if (now) {
                // Actively cap current volume on connect
                float cur;
                id avc2 = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                if ([avc2 getVolume:&cur forCategory:@"Ringtone"] && cur > 0.4f)
                    [avc2 setVolumeTo:0.4f forCategory:@"Ringtone"];
                if ([avc2 getVolume:&cur forCategory:@"Alert"] && cur > 0.4f)
                    [avc2 setVolumeTo:0.4f forCategory:@"Alert"];
            } else {
                [avc setVolumeTo:1.0f forCategory:@"Ringtone"];
                [avc setVolumeTo:1.0f forCategory:@"Alert"];
            }
        }];
    }
}
