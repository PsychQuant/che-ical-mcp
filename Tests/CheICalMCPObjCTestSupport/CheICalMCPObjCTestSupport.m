#import "CheICalMCPObjCTestSupport.h"

@implementation CheICalRaisingEventStore {
    NSExceptionName _name;
}

- (instancetype)initRaising:(nullable NSExceptionName)name {
    if ((self = [super init])) {
        _name = name;
    }
    return self;
}

- (nullable EKEvent *)eventWithIdentifier:(NSString *)identifier {
    if (_name != nil) {
        [NSException raise:_name format:@"raised for %@", identifier];
    }
    return nil;
}

- (nullable EKCalendarItem *)calendarItemWithIdentifier:(NSString *)identifier {
    return nil;
}

@end
