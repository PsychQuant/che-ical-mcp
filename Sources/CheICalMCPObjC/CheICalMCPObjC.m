#import "CheICalMCPObjC.h"

EKEvent * _Nullable CheICalEventWithIdentifier(EKEventStore *store, NSString *identifier,
                                               NSString * _Nullable * _Nonnull exceptionName) {
    @try {
        return [store eventWithIdentifier:identifier];
    } @catch (NSException *exception) {
        *exceptionName = exception.name ?: @"";
        return nil;
    }
}
