//
//  CastService.h
//  Connect SDK
//
//  Created by Jeremy White on 2/7/14.
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

#define kConnectSDKCastServiceId @"Chromecast"

#import <GoogleCast/GoogleCast.h>
#import "CastServiceChannel.h"
#import "VolumeControl.h"

@interface CastService : DeviceService <GCKSessionManagerListener, GCKRemoteMediaClientListener, MediaPlayer, MediaControl, VolumeControl, WebAppLauncher>

/*! The GCKSessionManager used by the CastService. */
@property(nonatomic, strong, readonly) GCKSessionManager *sessionManager;

/*! The CastServiceChannel is used for app-to-app communication that is handling by the Connect SDK JavaScript Bridge. */
@property (nonatomic, retain, readonly) CastServiceChannel *castServiceChannel;

/*! The CastService will launch the specified web app id. */
@property (nonatomic, copy)NSString *castWebAppId;

// @cond INTERNAL
- (void) playMedia:(GCKMediaInformation *)mediaInformation webAppId:(NSString *)webAppId success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure;
// @endcond

@end
