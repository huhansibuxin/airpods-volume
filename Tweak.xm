#import <substrate.h>
#import <Foundation/Foundation.h>

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category;
@end

%hook AVSystemController
- (BOOL)setVolumeTo:(float)volume forCategory:(id)category {
    return %orig;
}
%end

%ctor {
    NSLog(@"[AirPodsVolume] Hooked AVSystemController");
}
