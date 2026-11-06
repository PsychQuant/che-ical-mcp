#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

/// #288: a store whose event lookup raises from Objective-C, as `EKEventStore` does, so a test
/// crosses the frames production crosses and no Swift frame. Its item lookup returns nil, which is
/// what the kind check may see with Reminders access denied. Neither touches the calendar database.
@interface CheICalRaisingEventStore : EKEventStore
/// With a nil name the event lookup returns nil instead.
- (instancetype)initRaising:(nullable NSExceptionName)name;
@end

NS_ASSUME_NONNULL_END
