#ifndef OBJC_EXCEPTION_CATCHER_H
#define OBJC_EXCEPTION_CATCHER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching any Objective-C exception it raises.
/// Returns the exception's description, or nil if the block completed cleanly.
/// Needed because NSPasteboard access from background threads can raise
/// NSInternalInconsistencyException on internal races, and a C++ library in the
/// process installs a terminate handler that turns any uncaught NSException
/// into abort().
NSString *_Nullable FluidCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

#endif
