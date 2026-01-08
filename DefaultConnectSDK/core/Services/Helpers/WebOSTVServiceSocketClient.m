//
//  WebOSTVServiceSocketClient.m
//  Connect SDK
//
//  Created by Jeremy White on 6/19/14.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "WebOSTVServiceSocketClient.h"
#import "WebOSTVService.h"
#import "ConnectError.h"

#define kDeviceServicePairingTypeFirstScreen @"PROMPT"
#define kDeviceServicePairingTypePinCode @"PIN"
#define kDeviceServicePairingTypeMixed @"COMBINED"

@interface WebOSTVServiceSocketClient ()

/// Stores subscriptions that need to be automagically resubscribed after
/// reconnect. The structure is that of the @c _subscribed property.
@property (nonatomic, strong) NSDictionary *savedSubscriptions;

@end

@implementation WebOSTVServiceSocketClient
{
    int _UID;

    NSMutableArray *_commandQueue;
    NSMutableDictionary *_activeConnections;
    NSMutableDictionary *_subscribed;

    BOOL _reconnectOnWake;
    NSTimer *_registrationTimeoutTimer; // Timer for missing "registered" message
}

#pragma mark - Initial setup

- (instancetype) initWithService:(WebOSTVService *)service
{
    self = [super init];

    if (self)
    {
        _service = service;

        _UID = 0;
        _connected = NO;

        _commandQueue = [[NSMutableArray alloc] init];
        _activeConnections = [[NSMutableDictionary alloc] init];
        _subscribed = [[NSMutableDictionary alloc] init];

        _UID = 0;
    }

    return self;
}

- (NSArray *) commandQueue
{
    return [NSArray arrayWithArray:_commandQueue];
}

- (NSDictionary *) activeConnections
{
    return [NSDictionary dictionaryWithDictionary:_activeConnections];
}

#pragma mark - webOS Setup

- (NSDictionary *) manifest
{
    NSDictionary *infoDic = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleName = [infoDic valueForKey:@"CFBundleDisplayName"] ? [infoDic objectForKey:@"CFBundleDisplayName"] : [infoDic objectForKey:@"CFBundleName"];
    if(bundleName == nil){
        bundleName = @"";
    }
    
    return @{
            @"manifestVersion" : @(1),
            @"appId" : [infoDic objectForKey:@"CFBundleIdentifier"],
            @"vendorId" : @"",
            @"localizedAppNames" : @{
                    @"" :bundleName
            },
            @"permissions" : self.service.permissions
    };
}

#pragma mark - Connection & Disconnection

- (void) connect
{
    [self openSocket];
}

- (void) disconnect
{
    [self disconnectWithError:nil];
}

- (void) openSocket
{
    if (_socket)
    {
        switch (_socket.readyState)
        {
            case LGSR_OPEN:
                if (_socket.delegate != self)
                    _socket.delegate = self;
                
                [self webSocketDidOpen:_socket];
                return;
                
            case LGSR_CONNECTING:
                if (_socket.delegate != self)
                    _socket.delegate = self;
                return;
                
            case LGSR_CLOSED:
            case LGSR_CLOSING:
                _socket.delegate = nil;
                _socket = nil;
                break;
                
            default:break;
        }
    }
    
    NSString *address = self.service.serviceDescription.address;
    unsigned long port = self.service.serviceDescription.port;

    NSString *socketPath = [NSString stringWithFormat:@"wss://%@:%lu", address, port];
    NSURL *url = [[NSURL alloc] initWithString:socketPath];
    NSMutableURLRequest *urlRequest = [[NSMutableURLRequest alloc] initWithURL:url];

    if (self.service.webOSTVServiceConfig.SSLCertificates)
        [urlRequest setLGSR_SSLPinnedCertificates:self.service.webOSTVServiceConfig.SSLCertificates];

    _socket = [self createSocketWithURLRequest:[urlRequest copy]];
    _socket.delegate = self;
    [_socket open];
}

- (void) disconnectWithError:(NSError *)error
{
    if (!_reconnectOnWake)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    }

    _connected = NO;

    if (_socket && _socket.readyState != LGSR_CLOSED && _socket.readyState != LGSR_CLOSING)
    {
        if (error)
            [_socket closeWithCode:LGSRStatusCodeNormal reason:error.localizedDescription];
        else
            [_socket closeWithCode:LGSRStatusCodeNormal reason:@"Disconnected by client"];
    }
    
    _subscribed = [[NSMutableDictionary alloc] init];

    if (self.delegate)
        [self.delegate socket:self didCloseWithError:error];
}

#pragma mark - App state management

- (void) hAppDidEnterBackground:(NSNotification *)notification
{
    if (_connected)
    {
        _reconnectOnWake = YES;
        self.savedSubscriptions = [_subscribed copy];
        [self disconnect];
    }
}

- (void) hAppDidBecomeActive:(NSNotification *)notification
{
    if (_reconnectOnWake)
    {
        [self connect];
        _reconnectOnWake = NO;
    }
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
}

#pragma mark - Hello & Registration

-(void) helloTv
{
    NSDictionary *infoDic = [[NSBundle mainBundle] infoDictionary];

    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    CGSize screenSize = CGSizeMake(screenBounds.size.width * screenScale, screenBounds.size.height * screenScale);
    NSString *screenResolution = [NSString stringWithFormat:@"%dx%d", (int)screenSize.width, (int)screenSize.height];

    NSDictionary *payload = @{
            @"sdkVersion" : CONNECT_SDK_VERSION,
            @"deviceModel" : ensureString([[UIDevice currentDevice] model]),
            @"OSVersion" : ensureString([infoDic objectForKey:@"DTPlatformVersion"]),
            @"resolution" : screenResolution,
            @"appId" : ensureString([infoDic objectForKey:@"CFBundleIdentifier"]),
            @"appName" : ensureString([infoDic objectForKey:@"CFBundleDisplayName"]),
            @"appRegion" : ensureString([infoDic objectForKey:@"CFBundleDevelopmentRegion"])
    };

    ServiceCommand *hello = [[ServiceCommand alloc] init];
    hello.payload = payload;

    hello.delegate = self;
    hello.callbackComplete = ^(NSDictionary* response){
        if (self.service.serviceConfig.UUID != nil)
        {
            if (![self.service.serviceConfig.UUID isEqualToString:[response objectForKey:@"deviceUUID"]])
            {
                //Imposter UUID, kill it, kill it with fire
                self.service.webOSTVServiceConfig.clientKey = nil;
                self.service.webOSTVServiceConfig.SSLCertificates = nil;
                self.service.serviceConfig.UUID = nil;
                self.service.serviceDescription.address = nil;
                self.service.serviceDescription.UUID = nil;

                NSError *UUIDError = [ConnectError generateErrorWithCode:ConnectStatusCodeCertificateError andDetails:nil];
                [self disconnectWithError:UUIDError];
            }
        } else
        {
            self.service.serviceConfig.UUID = self.service.serviceDescription.UUID = [response objectForKey:@"deviceUUID"];
        }

        [self registerWithTv];
    };

    hello.callbackError = ^(NSError*err)
    {
        NSError *connectionError = [ConnectError generateErrorWithCode:ConnectStatusCodeSocketError andDetails:nil];
        [self disconnectWithError:connectionError];
    };

    if (_activeConnections == nil)
        _activeConnections = [[NSMutableDictionary alloc] init];

    [_activeConnections setValue:hello forKey:@"hello"];

    int dataId = [self getNextId];

    NSDictionary *sendData = @{
            @"id" : @(dataId),
            @"type" : @"hello",
            @"payload" : hello.payload
    };

    NSString *sendString = [self writeToJSON:sendData];

    DLog(@"[OUT] : %@", sendString);

    [_socket send:sendString];

    if ([_commandQueue containsObject:sendString])
        [_commandQueue removeObject:sendString];
}

-(void) registerWithTv
{
    ServiceCommand *reg = [[ServiceCommand alloc] init];
    reg.delegate = self;
    reg.callbackComplete = ^(NSDictionary *response) {
        // Kiểm tra nếu có client-key trong response, đây là trường hợp TV đã nhớ thiết bị
        if (response[@"client-key"]) {
            NSLog(@"[ConnectSDK] Received client-key in initial response: %@", response[@"client-key"]);
            self.service.webOSTVServiceConfig.clientKey = response[@"client-key"];
            
            // Xóa bộ đếm thời gian nếu đang chạy
            [self cancelRegistrationTimeoutTimer];
            
            // Thông báo kết nối thành công
            if (self.delegate && [self.delegate respondsToSelector:@selector(socketDidConnect:)]) {
                NSLog(@"[ConnectSDK] Client-key detected, notifying connection success");
                [self.delegate socketDidConnect:self];
            }
            
            // Cài đặt các thông báo và xử lý lệnh trong hàng đợi
            if ([DeviceService shouldDisconnectOnBackground]) {
                [[NSNotificationCenter defaultCenter] addObserver:self 
                                                        selector:@selector(hAppDidEnterBackground:) 
                                                            name:UIApplicationDidEnterBackgroundNotification 
                                                            object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self 
                                                        selector:@selector(hAppDidBecomeActive:) 
                                                            name:UIApplicationDidBecomeActiveNotification 
                                                            object:nil];
            }
            
            // Gửi lệnh trong hàng đợi
            if([_commandQueue count] > 0) {
                [_commandQueue enumerateObjectsUsingBlock:^(NSString *sendString, NSUInteger idx, BOOL *stop) {
                    DLog(@"[OUT] : %@", sendString);
                    [_socket send:sendString];
                }];
                _commandQueue = [[NSMutableArray alloc] init];
            }
            
            // Đăng ký lại nếu cần
            if (self.savedSubscriptions.count > 0) {
                [self resubscribeSubscriptions:self.savedSubscriptions];
                self.savedSubscriptions = nil;
            }
            
            return; // Dừng xử lý tiếp theo
        }
        
        // Kiểm tra nếu TV trả về returnValue = 1 (thành công) - trường hợp thông thường
        BOOL isSuccessful = [[response objectForKey:@"returnValue"] boolValue];
        
        if (isSuccessful) {
            // Đây là phản hồi từ lệnh đăng ký, không phải thông điệp "registered"
            // client-key sẽ được gửi trong thông điệp "registered" riêng biệt sau này
            NSLog(@"[ConnectSDK] Registration request was accepted, waiting for pairing confirmation");
            
            NSString *pairingString = [response valueForKey:@"pairingType"];
            if (pairingString) {
                self.service.pairingType = [self pairingStringToType:pairingString];
                // Hiển thị hộp thoại ghép nối nếu cần (PROMPT hoặc MIXED)
                if (self.delegate && [self.delegate respondsToSelector:@selector(socketWillRegister:)] && 
                   (self.service.pairingType == DeviceServicePairingTypeFirstScreen || 
                    self.service.pairingType == DeviceServicePairingTypeMixed)) {
                    NSLog(@"[ConnectSDK] Triggering pairing alert display via socketWillRegister.");
                    [self.delegate socketWillRegister:self];
                    
                    // Bắt đầu bộ đếm thời gian chờ chỉ cho kiểu ghép nối PROMPT
                    if (self.service.pairingType == DeviceServicePairingTypeFirstScreen) {
                        NSLog(@"[ConnectSDK] Starting registration timeout timer (30s).");
                        [self startRegistrationTimeoutTimer];
                    }
                }
            }
            
            // Cấu hình các thông báo và xử lý lệnh trong hàng đợi
            if ([DeviceService shouldDisconnectOnBackground]) {
                [[NSNotificationCenter defaultCenter] addObserver:self 
                                                         selector:@selector(hAppDidEnterBackground:) 
                                                             name:UIApplicationDidEnterBackgroundNotification 
                                                           object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self 
                                                         selector:@selector(hAppDidBecomeActive:) 
                                                             name:UIApplicationDidBecomeActiveNotification 
                                                           object:nil];
            }
            
            // Gửi bất kỳ lệnh nào trong hàng đợi
            if([_commandQueue count] > 0) {
                [_commandQueue enumerateObjectsUsingBlock:^(NSString *sendString, NSUInteger idx, BOOL *stop) {
                    DLog(@"[OUT] : %@", sendString);
                    [_socket send:sendString];
                }];
                
                _commandQueue = [[NSMutableArray alloc] init];
            }
            
            // Đăng ký lại nếu cần
            if (self.savedSubscriptions.count > 0) {
                [self resubscribeSubscriptions:self.savedSubscriptions];
                self.savedSubscriptions = nil;
            }
        } else {
            // Thực sự có lỗi từ TV
            NSError *regError = [ConnectError generateErrorWithCode:ConnectStatusCodeTvError 
                                                        andDetails:@"Registration command failed: TV returned failure"];
            NSLog(@"[ConnectSDK] Registration command failed in callbackComplete: %@", response);
            
            if (self.delegate && [self.delegate respondsToSelector:@selector(socket:registrationFailed:)]) {
                [self.delegate socket:self registrationFailed:regError];
            }
        }
    };
    // TODO: this is getting cleaned up before a potential pairing cancelled message is received
    reg.callbackError = ^(NSError *error) {
        // Existing callbackError logic remains
        if (self.delegate && [self.delegate respondsToSelector:@selector(socket:registrationFailed:)])
            [self.delegate socket:self registrationFailed:error];
    };

    int dataId = [self getNextId];

    [_activeConnections setObject:reg forKey:[self connectionKeyForMessageId:@(dataId)]];

    NSDictionary *registerInfo = @{
            @"manifest" : self.manifest,
            @"pairingType" : [self pairingTypeToString:self.service.pairingType]
    };

    NSString *sendString = [self encodeData:registerInfo andAddress:nil withId:dataId];

    DLog(@"[OUT] : %@", sendString);

    [_socket send:sendString];

    if ([_commandQueue containsObject:sendString])
        [_commandQueue removeObject:sendString];
}

-(NSString *)pairingTypeToString:(DeviceServicePairingType)pairingType{
    NSString *pairingTypeString = @"";
    
    if(pairingType == DeviceServicePairingTypeFirstScreen){
        pairingTypeString = kDeviceServicePairingTypeFirstScreen;
    }else
        if(pairingType == DeviceServicePairingTypePinCode)
        {
            pairingTypeString = kDeviceServicePairingTypePinCode;
        }
        else
            if(pairingType == DeviceServicePairingTypeMixed)
            {
                pairingTypeString = kDeviceServicePairingTypeMixed;
            }
    return pairingTypeString;
}

-(DeviceServicePairingType)pairingStringToType:(NSString *)pairingString{
    DeviceServicePairingType pairingType = DeviceServicePairingTypeNone;
    
    if([pairingString isEqualToString:kDeviceServicePairingTypeFirstScreen]){
        pairingType = DeviceServicePairingTypeFirstScreen;
    }else
        if([pairingString isEqualToString:kDeviceServicePairingTypePinCode])
        {
            pairingType = DeviceServicePairingTypePinCode;
        }
        else
            if([pairingString isEqualToString:kDeviceServicePairingTypeMixed])
            {
                pairingType = DeviceServicePairingTypeMixed;
            }
    return pairingType;
}

#pragma mark - LGSRWebSocketDelegate

- (void)webSocketDidOpen:(LGSRWebSocket *)webSocket
{
    _connected = YES;

    [self helloTv];
}

- (void)webSocket:(LGSRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
    _connected = NO;

    _activeConnections = [NSMutableDictionary new];

    _socket.delegate = nil;
    _socket = nil;

    NSError *error;

    if (!wasClean)
        error = [ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:reason];

    if (self.delegate)
        [self.delegate socket:self didCloseWithError:error];
}

- (void)webSocket:(LGSRWebSocket *)webSocket didFailWithError:(NSError *)error
{
    BOOL shouldRetry = NO;
    BOOL wasConnected = _connected;
    _connected = NO;

    NSError *intError;

    if (error.code == 23556)
    {
        intError = [ConnectError generateErrorWithCode:ConnectStatusCodeCertificateError andDetails:nil];

        self.service.webOSTVServiceConfig.SSLCertificates = nil;
        self.service.webOSTVServiceConfig.clientKey = nil;

        shouldRetry = YES;
    } else
        intError = [ConnectError generateErrorWithCode:ConnectStatusCodeSocketError andDetails:error.localizedDescription];

    for (NSString *key in _activeConnections)
    {
        ServiceCommand *comm = (ServiceCommand *)[_activeConnections objectForKey:key];

        if (comm.callbackError)
            dispatch_on_main(^{ comm.callbackError(intError); });
    }

    _activeConnections = [NSMutableDictionary dictionary];

    if (shouldRetry)
    {
        [self connect];
        return;
    }

    if (wasConnected)
    {
        if ([self.delegate respondsToSelector:@selector(socket:didCloseWithError:)])
            [self.delegate socket:self didCloseWithError:intError];
    } else
    {
        if ([self.delegate respondsToSelector:@selector(socket:didCloseWithError:)])
            [self.delegate socket:self didFailWithError:intError];
    }
}

- (void)webSocket:(LGSRWebSocket *)webSocket didGetCertificates:(NSArray *)certs
{
    self.service.webOSTVServiceConfig.SSLCertificates = certs;
}

- (void)webSocket:(LGSRWebSocket *)webSocket didReceiveMessage:(id)message
{
    NSDictionary *decodeData = [self decodeData:message];

    NSLog(@"[ConnectSDK] Received WebSocket message: %@", decodeData);

    DLog(@"[IN] : %@", decodeData);

    if (self.delegate && [self.delegate respondsToSelector:@selector(socket:didReceiveMessage:)])
    {
        BOOL shouldProcessMessage = [self.delegate socket:self didReceiveMessage:decodeData];

        if (!shouldProcessMessage)
            return;
    }

    NSNumber *comId = [decodeData objectForKey:@"id"];
    NSString *type = [decodeData objectForKey:@"type"];
    NSDictionary *payload = [decodeData objectForKey:@"payload"];

    NSString *connectionKey = [self connectionKeyForMessageId:comId];
    ServiceCommand *connectionCommand = [_activeConnections objectForKey:connectionKey];

    if ([type isEqualToString:@"error"])
    {
        // Kiểm tra lỗi quyền
        NSString *errorMessage = [decodeData objectForKey:@"error"];
        if (errorMessage && [errorMessage rangeOfString:@"insufficient permissions"].location != NSNotFound) {
            NSLog(@"[ConnectSDK] Received insufficient permissions error. User may not have accepted pairing.");
            NSError *permissionsError = [ConnectError generateErrorWithCode:ConnectStatusCodeTvError 
                                                        andDetails:@"TV access denied: User did not accept pairing request"];
            
            // Báo lỗi và ngắt kết nối
            [self disconnectWithError:permissionsError];
            return;
        }
        
        if (comId && connectionCommand.callbackError)
        {
            NSError *err = [ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:decodeData];
            dispatch_on_main(^{ connectionCommand.callbackError(err); });
        }
    } else
    {
        if ([type isEqualToString:@"registered"])
        {
            NSLog(@"[ConnectSDK] Received 'registered' message. Payload: %@", payload);
            [self cancelRegistrationTimeoutTimer]; // Hủy bộ đếm thời gian vì đã nhận được thông điệp
            
            // Kiểm tra xem đã xử lý kết nối chưa (thông qua client-key trong callback đăng ký)
            BOOL alreadyConnected = (self.service.webOSTVServiceConfig.clientKey != nil && 
                                  [self.service.webOSTVServiceConfig.clientKey isEqualToString:payload[@"client-key"]]);
            
            // Lưu client-key mới nếu có và chưa được đặt
            if (payload && [payload objectForKey:@"client-key"]) {
                NSString *client = [payload objectForKey:@"client-key"];
                NSLog(@"[ConnectSDK] Saving client-key from 'registered' message: %@", client);
                self.service.webOSTVServiceConfig.clientKey = client;
                
                // Chỉ thông báo kết nối thành công nếu chưa được xử lý trước đó
                if (!alreadyConnected && self.delegate) {
                    NSLog(@"[ConnectSDK] Notifying connection success");
                    [self.delegate socketDidConnect:self];
                } else if (alreadyConnected) {
                    NSLog(@"[ConnectSDK] Already connected, skipping duplicate connection notification");
                }
            } else {
                NSLog(@"[ConnectSDK] Warning: No client-key in 'registered' message");
            }
        } else if ([type isEqualToString:@"hello"])
        {
            //Store information here
            ServiceCommand *comm = _activeConnections[@"hello"];

            if (comm && comm.callbackComplete)
                dispatch_on_main(^{ comm.callbackComplete(payload); });

            [_activeConnections removeObjectForKey:@"hello"];
        }

        if (comId && connectionCommand.callbackComplete) {
            dispatch_on_main(^{ connectionCommand.callbackComplete(payload); });
        }
    }

    // don't remove subscriptions and "register" command
    const BOOL leaveConnection = ([connectionCommand isKindOfClass:[ServiceSubscription class]]);
    if (!leaveConnection) {
        [_activeConnections removeObjectForKey:connectionKey];
    }
}

#pragma mark - Subscription methods

- (ServiceSubscription *) addSubscribe:(NSURL *)URL payload:(NSDictionary *)payload success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (_subscribed == nil)
        _subscribed = [[NSMutableDictionary alloc] init];

    NSString *subscriptionReferenceId = [self subscriptionReferenceForURL:URL payload:payload];
    ServiceSubscription *subscription = [_subscribed objectForKey:subscriptionReferenceId];

    if (subscription == nil)
    {
        int callId = [self getNextId];
        subscription = [ServiceSubscription subscriptionWithDelegate:self target:URL payload:payload callId:callId];
        [_subscribed setObject:subscription forKey:subscriptionReferenceId];
    }

    if (success)
        [subscription addSuccess:success];

    if (failure)
        [subscription addFailure:failure];

    if (![subscription isSubscribed])
        [subscription subscribe];

    return subscription;
}

- (ServiceSubscription *) killSubscribe:(NSURL *)URL payload:(NSDictionary *)payload
{
    NSString *subscriptionReferenceId = [self subscriptionReferenceForURL:URL payload:payload];
    ServiceSubscription *subscription = [_subscribed objectForKey:subscriptionReferenceId];

    if (subscription)
        [_subscribed removeObjectForKey:subscriptionReferenceId];

    return subscription;
}

/// Stores the given @c subscriptions dictionary as @c _subscribed and
/// subscribes to all of them.
- (void)resubscribeSubscriptions:(NSDictionary *)subscriptions {
    _subscribed = [subscriptions mutableCopy];
    [[_subscribed allValues] makeObjectsPerformSelector:@selector(subscribe)];
}

- (NSString *)subscriptionReferenceForURL:(NSURL *)URL payload:(NSDictionary *)payload
{
    NSString *subscriptionReferenceId;

    if (payload)
    {
        NSString *payloadKeys = [[payload allValues] componentsJoinedByString:@""];
        subscriptionReferenceId = [NSString stringWithFormat:@"%@%@", URL.absoluteString, payloadKeys];
    } else
    {
        subscriptionReferenceId = URL.absoluteString;
    }

    return subscriptionReferenceId;
}

#pragma mark - Helper methods

- (NSDictionary *) decodeData:(NSString *) data
{
    return [NSJSONSerialization JSONObjectWithData:[data dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

- (NSString *) writeToJSON:(id) obj
{
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    return jsonString;
}

- (NSString*) encodeData:(NSDictionary*)data andAddress:(NSURL*)add withId:(int)reqId{
    NSMutableDictionary *sendData = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *payloadData = [[NSMutableDictionary alloc] initWithDictionary:data];

    if (reqId < 0)
        reqId = [self getNextId];

    [sendData setObject:[NSString stringWithFormat:@"%d", reqId] forKey:@"id"];
    [sendData setObject:payloadData forKey:@"payload"];

    if (add != nil)
    {
        [sendData setObject:[add absoluteString] forKey:@"uri"];
        [sendData setObject:@"request" forKey:@"type"];
    } else
    {
        if (self.service.webOSTVServiceConfig.clientKey)
            [payloadData setObject:self.service.webOSTVServiceConfig.clientKey forKey:@"client-key"];

        [sendData setObject:@"register" forKey:@"type"];
    }

    return [self writeToJSON:sendData];
}

- (int) getNextId
{
    _UID = _UID + 1;
    return _UID;
}

/// Returns a connection key unique for the given message id.
- (NSString *)connectionKeyForMessageId:(NSNumber *)messageId {
    return [NSString stringWithFormat:@"req%@", messageId];
}

#pragma mark - ServiceCommandDelegate

- (int) sendCommand:(ServiceCommand *)comm withPayload:(NSDictionary *)payload toURL:(NSURL *)URL
{
    int callId = [self getNextId];

    [_activeConnections setObject:comm forKey:[self connectionKeyForMessageId:@(callId)]];

    NSString *sendString = [self encodeData:payload andAddress:URL withId:callId];

    [self sendStringOverSocket:sendString];

    return callId;
}

- (void) sendDictionaryOverSocket:(NSDictionary *)payload
{
    NSString *sendString = [self writeToJSON:payload];

    [self sendStringOverSocket:sendString];
}

- (void) sendStringOverSocket:(NSString *)payload
{
    if (_socket == nil)
        [self openSocket];

    if (_socket.readyState == LGSR_OPEN)
    {
        DLog(@"[OUT] : %@", payload);

        [_socket send:payload];

        if ([_commandQueue containsObject:payload])
            [_commandQueue removeObject:payload];
    } else if (_socket.readyState == LGSR_CONNECTING ||
            _socket.readyState == LGSR_CLOSING)
    {
        [_commandQueue addObject:payload];
    } else
    {
        [_commandQueue addObject:payload];
        [self openSocket];
    }
}

- (int) sendSubscription:(ServiceSubscription *)subscription type:(ServiceSubscriptionType)type payload:(id)payload toURL:(NSURL *)URL withId:(int)callId
{
    if (callId < 0)
        callId = [self getNextId];

    [_activeConnections setObject:subscription forKey:[self connectionKeyForMessageId:@(callId)]];

    NSMutableDictionary *subscriptionPayload = [[NSMutableDictionary alloc] init];
    [subscriptionPayload setObject:@(callId) forKey:@"id"];
    [subscriptionPayload setObject:URL.absoluteString forKey:@"uri"];

    if (type == ServiceSubscriptionTypeSubscribe)
    {
        [subscriptionPayload setObject:@"subscribe" forKey:@"type"];

        if (payload)
            [subscriptionPayload setObject:payload forKey:@"payload"];
    } else
    {
        if (!_connected)
            return -1;

        [subscriptionPayload setObject:@"unsubscribe" forKey:@"type"];
        [self killSubscribe:URL payload:payload];
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:subscriptionPayload options:0 error:nil];
    NSString *sendString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    [self sendStringOverSocket:sendString];

    return callId;
}

#pragma mark - Private

- (LGSRWebSocket *)createSocketWithURLRequest:(NSURLRequest *)request {
    return [[LGSRWebSocket alloc] initWithURLRequest:request];
}

#pragma mark - Timer methods

- (void)startRegistrationTimeoutTimer {
    [self cancelRegistrationTimeoutTimer]; // Ensure any existing timer is stopped
    _registrationTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 // 30 second timeout 
                                                               target:self
                                                             selector:@selector(handleRegistrationTimeout:)
                                                             userInfo:nil
                                                              repeats:NO];
    NSLog(@"[ConnectSDK] Starting registration timeout timer (30s).");
}

- (void)cancelRegistrationTimeoutTimer {
    if (_registrationTimeoutTimer) {
        NSLog(@"[ConnectSDK] Cancelling registration timeout timer.");
        [_registrationTimeoutTimer invalidate];
        _registrationTimeoutTimer = nil;
    }
}

- (void)handleRegistrationTimeout:(NSTimer *)timer {
    NSLog(@"[ConnectSDK] Registration timeout reached. No response from TV.");
    _registrationTimeoutTimer = nil;

    // Thay vì tự động kết nối, báo lỗi timeout
    NSError *timeoutError = [ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected 
                                                   andDetails:@"TV did not respond to pairing request in time"];
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(socket:registrationFailed:)]) {
        NSLog(@"[ConnectSDK] Timeout - calling registration failed");
        [self.delegate socket:self registrationFailed:timeoutError];
    }
}

@end
