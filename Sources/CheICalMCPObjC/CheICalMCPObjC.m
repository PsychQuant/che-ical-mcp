#import "CheICalMCPObjC.h"

EKEvent * _Nullable CheICalEventWithIdentifier(EKEventStore *store, NSString *identifier,
                                               NSString * _Nullable * _Nullable exceptionName) {
    @try {
        return [store eventWithIdentifier:identifier];
    } @catch (NSException *exception) {
        if (exceptionName != NULL) {
            *exceptionName = exception.name;
        }
        return nil;
    }
}
