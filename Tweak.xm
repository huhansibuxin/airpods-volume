#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>

// ============================================================================
// AirPodsVolume - Prevent ear-blasting ringer/notification volume
// when Bluetooth headphones (AirPods, etc.) are connected.
//
// iOS keeps ringer/alert volume separate from media volume. When you wear
// AirPods and set media volume to a comfortable level, incoming calls/
// notifications still play at max ringer volume because the ringer channel
// is independent. This tweak clamps ringer volume when headphones are connected
// and restores it when disconnected.
// ============================================================================

// Safe max volume for ringer/notifications when headphones are connected (0.0 ~ 1.0)
static const float kSafeRingerVolume = 0.5;

// UserDefaults for persisting ringer state across resprings
static NSUserDefaults *g_defaults = nil;

// Track current headphone connection state
static BOOL g_headphonesConnected = NO;

// Saved ringer volume before clamping (restored on disconnect)
static float g_savedRingerVolume = -1.0;

// ============================================================================
// Audio Route Detection
// ============================================================================

static BOOL isHeadphoneRouteActive(void) {
    AVAudioSessionRouteDescription *route = [[AVAudioSession sharedInstance] currentRoute];
    for (AVAudioSessionPortDescription *output in route.outputs) {
        NSString *portType = output.portType;
        if ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [portType isEqualToString:AVAudioSessionPortBluetoothLE] ||
            [portType isEqualToString:AVAudioSessionPortHeadphones] ||
            [portType isEqualToString:AVAudioSessionPortUSBAudio]) {
            return YES;
        }
    }
    return NO;
}

// ============================================================================
// AVSystemController — private class in Celestial.framework
// Controls system-wide volume (ringer, media, etc.)
// ============================================================================

@interface AVSystemController : NSObject
+ (instancetype)sharedAVSystemController;
- (BOOL)getVolume:(float *)outVolume forCategory:(NSString *)category;
- (BOOL)setVolumeTo:(float)volume forCategory:(NSString *)category;
@end

static NSString * const kRingerCategory = @"Ringtone";
static NSString * const kNotificationCategory = @"Alert";

static void clampRingerVolume(void) {
    AVSystemController *avs = [objc_getClass("AVSystemController") sharedAVSystemController];
    if (!avs) return;

    float currentVolume = 0;
    [avs getVolume:&currentVolume forCategory:kRingerCategory];

    // Save current volume if not already clamped
    if (g_savedRingerVolume < 0) {
        g_savedRingerVolume = currentVolume;
        [g_defaults setFloat:g_savedRingerVolume forKey:@"savedRingerVolume"];
    }

    // Clamp to safe level if too loud
    if (currentVolume > kSafeRingerVolume) {
        [avs setVolumeTo:kSafeRingerVolume forCategory:kRingerCategory];
        [avs setVolumeTo:kSafeRingerVolume forCategory:kNotificationCategory];
        NSLog(@"[AirPodsVolume] Clamped ringer from %.2f to %.2f", currentVolume, kSafeRingerVolume);
    } else {
        // Volume already low enough, save as-is
        g_savedRingerVolume = currentVolume;
        [g_defaults setFloat:g_savedRingerVolume forKey:@"savedRingerVolume"];
    }
}

static void restoreRingerVolume(void) {
    if (g_savedRingerVolume < 0) return;

    AVSystemController *avs = [objc_getClass("AVSystemController") sharedAVSystemController];
    if (!avs) return;

    [avs setVolumeTo:g_savedRingerVolume forCategory:kRingerCategory];
    [avs setVolumeTo:g_savedRingerVolume forCategory:kNotificationCategory];
    NSLog(@"[AirPodsVolume] Restored ringer to %.2f", g_savedRingerVolume);

    g_savedRingerVolume = -1.0;
    [g_defaults removeObjectForKey:@"savedRingerVolume"];
}

// ============================================================================
// Hook: AVAudioSession — detect route changes
// ============================================================================

%hook AVAudioSession

- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    BOOL ret = %orig;
    return ret;
}

%end

// ============================================================================
// Hook: AudioServicesPlaySystemSound — intercept notification/ring sounds
// ============================================================================

static void (*orig_AudioServicesPlaySystemSound)(SystemSoundID);
static void hook_AudioServicesPlaySystemSound(SystemSoundID inSystemSoundID) {
    if (g_headphonesConnected) {
        // Before playing the system sound, ensure ringer volume is clamped.
        // This catches the case where route changed but ringer wasn't yet clamped
        // (e.g., right after connection before the notification fires).
        clampRingerVolume();
    }
    orig_AudioServicesPlaySystemSound(inSystemSoundID);
}

// ============================================================================
// Core: Route change handler
// ============================================================================

static void handleRouteChange(NSNotification *note) {
    BOOL nowConnected = isHeadphoneRouteActive();

    if (nowConnected && !g_headphonesConnected) {
        // Headphones just connected
        NSLog(@"[AirPodsVolume] Headphones connected — clamping ringer");
        g_headphonesConnected = YES;
        g_savedRingerVolume = [g_defaults floatForKey:@"savedRingerVolume"];
        if (g_savedRingerVolume == 0) g_savedRingerVolume = -1.0;
        clampRingerVolume();
    } else if (!nowConnected && g_headphonesConnected) {
        // Headphones just disconnected
        NSLog(@"[AirPodsVolume] Headphones disconnected — restoring ringer");
        g_headphonesConnected = NO;
        restoreRingerVolume();
    }
}

// ============================================================================
// Constructor
// ============================================================================

%ctor {
    // Only inject into SpringBoard — ringer volume is a system-wide setting
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (![bundleID isEqualToString:@"com.apple.springboard"]) {
        return;
    }

    NSLog(@"[AirPodsVolume] Initializing...");

    g_defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.UIKit"];

    // Init state
    g_headphonesConnected = isHeadphoneRouteActive();
    g_savedRingerVolume = [g_defaults floatForKey:@"savedRingerVolume"];
    if (g_savedRingerVolume == 0) g_savedRingerVolume = -1.0;

    if (g_headphonesConnected) {
        clampRingerVolume();
    }

    // Hook AudioServicesPlaySystemSound via fishhook / MSHookFunction
    void *AudioToolbox = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    if (AudioToolbox) {
        MSHookFunction(dlsym(AudioToolbox, "AudioServicesPlaySystemSound"),
                       (void *)hook_AudioServicesPlaySystemSound,
                       (void **)&orig_AudioServicesPlaySystemSound);
        dlclose(AudioToolbox);
    }

    %init;

    // Listen for audio route changes
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        handleRouteChange(note);
    }];

    NSLog(@"[AirPodsVolume] Ready. Headphones: %@", g_headphonesConnected ? @"YES" : @"NO");
}
