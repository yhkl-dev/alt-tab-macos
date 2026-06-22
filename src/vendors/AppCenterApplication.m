@import Cocoa;
#import "AppCenterApplication.h"

@implementation AppCenterApplication

- (void)sendEvent:(NSEvent *)theEvent {
    @try {
        [super sendEvent:theEvent];
    } @catch (NSException *exception) {
        [super reportException:exception];
    }
}

@end
