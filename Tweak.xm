#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <fcntl.h>
#import <unistd.h>

#define STATE_FILE "/tmp/.airpods_state"

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
- (BOOL)changeVolumeBy:(float)delta forCategory:(id)cat {
    if (isNotificationCategory(cat)) {
        float cur;
        if ([self getVolume:&cur forCategory:cat])
            return [self setVolumeTo:applyVolumeCap(cur + delta) forCategory:cat];
    }
    return %orig;
}
// Cap getters so HUD always reads capped value (no flicker)
- (BOOL)getVolume:(float *)vol forCategory:(id)cat {
    BOOL r = %orig;
    if (r && isNotificationCategory(cat))
        *vol = applyVolumeCap(*vol);
    return r;
}
%end

// HUD: suppress auto-triggered, only show manual
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

// Keep volume HUD always wide, never collapse to narrow bar.
// Also disable touch on HUD slider — volume only via physical buttons.
// (Control Center volume module is a different view hierarchy, not affected.)
%hook SBHUDWindow
- (void)addSubview:(UIView *)view {
    // Disable touch on all HUD subviews — buttons only
    view.userInteractionEnabled = NO;
    %orig;
}
%end

// Force the volume slider to always stay wide — never collapse to narrow bar
// Also disable touch
@interface SBElasticVolumeSliderView : UIView
@end
%hook SBElasticVolumeSliderView
- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    self.userInteractionEnabled = NO;
    return self;
}
- (void)setFrame:(CGRect)frame {
    if (frame.size.width < 100) {
        frame.size.width = 200;
    }
    %orig;
}
%end

// Hide replaykit CC modules (mic mode / video effects) during calls
// Block the bundle's principal class so the module never instantiates
%hook NSBundle
- (Class)principalClass {
    NSString *bid = [self bundleIdentifier];
    if (bid && ([bid isEqualToString:@"com.apple.replaykit.AudioConferenceControlCenterModule"] ||
                [bid isEqualToString:@"com.apple.replaykit.VideoConferenceControlCenterModule"])) {
        return nil;
    }
    return %orig;
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
