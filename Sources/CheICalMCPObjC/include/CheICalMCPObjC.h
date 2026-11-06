#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// #288: `[store eventWithIdentifier:]`, with an Objective-C exception caught here, in the frame
/// that made the call: Swift cannot catch one, and unwinding through Swift frames is not supported,
/// so no Swift code runs between the raise and this catch. When it raises, `exceptionName` is set
/// (to @"" for an exception with no name), so a non-nil name means it raised; it stays nil otherwise
/// and the result is the lookup's. The reason is left out, because it can quote the caller's input.
/// This wraps one call on purpose: each EventKit call that needs this gets its own function, not a
/// shared wrapper taking a block written in Swift.
EKEvent * _Nullable CheICalEventWithIdentifier(EKEventStore *store, NSString *identifier,
                                               NSString * _Nullable * _Nonnull exceptionName);

NS_ASSUME_NONNULL_END
