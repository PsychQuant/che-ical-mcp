#import "CheICalMCPObjCTestSupport.h"

@implementation CheICalRaisingEventStore {
    NSExceptionName _name;
    BOOL _unnamed;
}

- (instancetype)initRaisingWithoutAName {
    if ((self = [super init])) {
        _unnamed = YES;
    }
    return self;
}

- (instancetype)initRaising:(nullable NSExceptionName)name {
    if ((self = [super init])) {
        _name = name;
    }
    return self;
}

- (nullable EKEvent *)eventWithIdentifier:(NSString *)identifier {
    if (_unnamed) {
        NSExceptionName none = nil;
        @throw [NSException exceptionWithName:none reason:nil userInfo:nil];
    }
    if (_name != nil) {
        [NSException raise:_name format:@"raised for %@", identifier];
    }
    return nil;
}

- (nullable EKCalendarItem *)calendarItemWithIdentifier:(NSString *)identifier {
    return nil;
}

@end
