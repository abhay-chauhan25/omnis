#import "OmnisTry.h"

NSException * _Nullable OmnisCatch(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
