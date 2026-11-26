#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the Objective-C exception it raised, or nil.
///
/// Some of Apple's audio calls report a problem by raising an exception that
/// Swift cannot catch. Left alone, one of those unwinds through Swift code and
/// leaves the app in a state it later crashes from. This is the one place
/// such an exception is caught, so it can be reported as an ordinary error.
NSException * _Nullable OmnisCatch(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
