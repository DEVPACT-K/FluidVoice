#ifndef OBJC_EXCEPTION_CATCHER_H
#define OBJC_EXCEPTION_CATCHER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, returning a raised exception's description or nil if it completed.
/// Pasteboard and file-promise calls raise, and a C++ terminate handler in-process
/// turns any uncaught NSException into abort().
NSString *_Nullable FluidCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

#endif
