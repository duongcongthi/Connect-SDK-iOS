#import <Foundation/Foundation.h>
#import "Capability.h"
typedef enum {
    WebOSTVMouseButtonHome = 1000,
    WebOSTVMouseButtonBack = 1001,
    WebOSTVMouseButtonUp = 1002,
    WebOSTVMouseButtonDown = 1003,
    WebOSTVMouseButtonLeft = 1004,
    WebOSTVMouseButtonRight = 1005,
    WebOSTVMouseButtonEnter = 1006,
    WebOSTVMouseButtonMenu = 1007,
    WebOSTVMouseButtonInfo = 1008,
    WebOSTVMouseButtonExit = 1009,
    WebOSTVMouseButton0 = 1010,
    WebOSTVMouseButton1 = 1011,
    WebOSTVMouseButton2 = 1012,
    WebOSTVMouseButton3 = 1013,
    WebOSTVMouseButton4 = 1014,
    WebOSTVMouseButton5 = 1015,
    WebOSTVMouseButton6 = 1016,
    WebOSTVMouseButton7 = 1017,
    WebOSTVMouseButton8 = 1018,
    WebOSTVMouseButton9 = 1019,
    WebOSTVMouseButtonCC = 1020,
    WebOSTVMouseButtonList = 1021,

} WebOSTVMouseButton;
@interface WebOSTVServiceMouse : NSObject
- (instancetype) initWithSocket:(NSString*)socket success:(SuccessBlock)success failure:(FailureBlock)failure;
- (void) move:(CGVector)distance;
- (void) scroll:(CGVector)distance;
- (void) click;
- (void) button:(WebOSTVMouseButton)keyName;
- (void) disconnect;
@end
