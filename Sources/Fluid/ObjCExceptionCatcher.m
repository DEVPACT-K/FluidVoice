#import "ObjCExceptionCatcher.h"

NSString *FluidCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.description ?: @"unknown Objective-C exception";
    }
}
