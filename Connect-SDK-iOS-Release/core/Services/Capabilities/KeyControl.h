#import <Foundation/Foundation.h>
#import "Capability.h"
#define kKeyControlAny @"KeyControl.Any"
#define kKeyControlUp @"KeyControl.Up"
#define kKeyControlDown @"KeyControl.Down"
#define kKeyControlLeft @"KeyControl.Left"
#define kKeyControlRight @"KeyControl.Right"
#define kKeyControlOK @"KeyControl.OK"
#define kKeyControlBack @"KeyControl.Back"
#define kKeyControlHome @"KeyControl.Home"
#define kKeyControlSendKeyCode @"KeyControl.Send.KeyCode"
#define kKeyControlCapabilities @[\
    kKeyControlUp,\
    kKeyControlDown,\
    kKeyControlLeft,\
    kKeyControlRight,\
    kKeyControlOK,\
    kKeyControlBack,\
    kKeyControlHome,\
    kKeyControlSendKeyCode\
]
@protocol KeyControl <NSObject>
- (id<KeyControl>) keyControl;
- (CapabilityPriorityLevel) keyControlPriority;
- (void) upWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) menuWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) downWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) leftWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) rightWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) okWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) backWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) homeWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) sendKeyCode:(NSUInteger)keyCode success:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)exitWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p0WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p1WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p2WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p3WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p4WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p5WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p6WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p7WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p8WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)p9WithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)infoWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)cCWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;
- (void)listWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure;

@end
