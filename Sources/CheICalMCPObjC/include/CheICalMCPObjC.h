#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// #288: runs `body` and returns its result, or nil when it raises an Objective-C exception, which
/// Swift cannot catch. `exceptionName`, when given, receives the exception's name; its reason is
/// left out because it can quote what the caller passed in. Keep `body` to one EventKit call: a
/// wider one would turn real failures into a nil.
id _Nullable CheICalCatchingException(NS_NOESCAPE id _Nullable (^body)(void),
                                      NSString * _Nullable * _Nullable exceptionName);

NS_ASSUME_NONNULL_END
