#import "CheICalMCPObjC.h"

id _Nullable CheICalCatchingException(NS_NOESCAPE id _Nullable (^body)(void),
                                      NSString * _Nullable * _Nullable exceptionName) {
    @try {
        return body();
    } @catch (NSException *exception) {
        if (exceptionName != NULL) {
            *exceptionName = exception.name;
        }
        return nil;
    }
}
