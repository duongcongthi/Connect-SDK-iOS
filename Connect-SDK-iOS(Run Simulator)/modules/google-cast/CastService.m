//
//  CastService.m
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

#import "CastService_Private.h"

#import "ConnectError.h"
#import "CastWebAppSession.h"
#import "SubtitleInfo.h"

#import "NSObject+FeatureNotSupported_Private.h"
#import "NSMutableDictionary+NilSafe.h"

#import <GoogleCast/GoogleCast.h>

#define kCastServiceMuteSubscriptionName @"mute"
#define kCastServiceVolumeSubscriptionName @"volume"

static const NSInteger kSubtitleTrackIdentifier = 42;

static NSString *const kSubtitleTrackDefaultLanguage = @"en";

@interface CastService () <ServiceCommandDelegate>

- (void)commonSetup;

// Declare helper methods used internally
- (MediaControlPlayState)getPlayStateFromMediaStatus:(GCKMediaStatus *)mediaStatus;
- (void)sendNotSupportedFailure:(FailureBlock)failure message:(NSString *)message;

@property (nonatomic, strong) MediaPlayStateSuccessBlock immediatePlayStateCallback;
@property (nonatomic, strong) ServiceSubscription *playStateSubscription;
@property (nonatomic, strong) ServiceSubscription *mediaInfoSubscription;

@end

@implementation CastService
{
    int UID;

    GCKSessionManager *_sessionManager;
    GCKRemoteMediaClient *_remoteMediaClient;

    NSString *_currentAppId;
    NSString *_launchingAppId;

    NSMutableDictionary *_launchSuccessBlocks;
    NSMutableDictionary *_launchFailureBlocks;

    NSMutableDictionary *_sessions; // TODO: are we using this? get rid of it if not
    NSMutableArray *_subscriptions;

    float _currentVolumeLevel;
    BOOL _currentMuteStatus;
}

- (void)commonSetup
{
    GCKCastContext *castContext = [GCKCastContext sharedInstance];
    _sessionManager = castContext.sessionManager;
    [_sessionManager addListener:self];

    _launchSuccessBlocks = [NSMutableDictionary new];
    _launchFailureBlocks = [NSMutableDictionary new];

    _sessions = [NSMutableDictionary new];
    _subscriptions = [NSMutableArray new];

    UID = 0;
}

- (instancetype) init
{
    self = [super init];

    if (self)
        [self commonSetup];

    return self;
}

- (instancetype)initWithServiceConfig:(ServiceConfig *)serviceConfig
{
    self = [super initWithServiceConfig:serviceConfig];

    if (self)
        [self commonSetup];

    return self;
}

+ (NSDictionary *) discoveryParameters
{
    return @{
             @"serviceId":kConnectSDKCastServiceId
             };
}

- (BOOL)isConnectable
{
    return YES;
}

- (void) updateCapabilities
{
    NSArray *capabilities = [NSArray new];

    capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaPlayerCapabilities];
    capabilities = [capabilities arrayByAddingObjectsFromArray:kVolumeControlCapabilities];
    capabilities = [capabilities arrayByAddingObjectsFromArray:@[
            kMediaPlayerSubtitleWebVTT,

            kMediaControlPlay,
            kMediaControlPause,
            kMediaControlStop,
            kMediaControlDuration,
            kMediaControlSeek,
            kMediaControlPosition,
            kMediaControlPlayState,
            kMediaControlPlayStateSubscribe,
            kMediaControlMetadata,
            kMediaControlMetadataSubscribe,

            kWebAppLauncherLaunch,
            kWebAppLauncherMessageSend,
            kWebAppLauncherMessageReceive,
            kWebAppLauncherMessageSendJSON,
            kWebAppLauncherMessageReceiveJSON,
            kWebAppLauncherConnect,
            kWebAppLauncherDisconnect,
            kWebAppLauncherJoin,
            kWebAppLauncherClose
    ]];

    [self setCapabilities:capabilities];
}

-(NSString *)castWebAppId
{
    if(_castWebAppId == nil){
        _castWebAppId = kGCKDefaultMediaReceiverApplicationID;
    }
    return _castWebAppId;
}

#pragma mark - Connection

- (void)connect
{
    if (self.connected)
        return;

    // Connection is now managed implicitly by GCKSessionManager starting/resuming a session.
    // We add self as a listener to observe session state changes.
    [_sessionManager addListener:self];

    // Attempt to resume existing session or trigger discovery/dialog if needed.
    // Actual connection happens when user selects a device from the Cast dialog
    // or a session is resumed automatically.
    // If a session is already active, the listener methods will be called.
    if (_sessionManager.hasConnectedCastSession) {
        [self sessionManager:_sessionManager didResumeCastSession:_sessionManager.currentCastSession];
    } else {
        // Optionally trigger discovery or UI prompt here if needed,
        // but standard GCKUICastButton handles this.
        DLog(@"No current session, waiting for user interaction or discovery.");
    }
}

- (void)disconnect
{
    // Remove listener before ending session to avoid redundant callbacks
    [_sessionManager removeListener:self];

    if (_sessionManager.hasConnectedCastSession) {
        [_sessionManager endSessionAndStopCasting:YES];
    } else {
        // If not connected, just ensure state is clean
        self.connected = NO;
        if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)]) {
            dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:nil]; });
        }
    }
    // The actual disconnection logic will be handled in the sessionManager:didEndCastSession:withError: listener method.
}

#pragma mark - Subscriptions

- (int)sendSubscription:(ServiceSubscription *)subscription type:(ServiceSubscriptionType)type payload:(id)payload toURL:(NSURL *)URL withId:(int)callId
{
    if (type == ServiceSubscriptionTypeUnsubscribe) {
        if (subscription == _playStateSubscription) {
            _playStateSubscription = nil;
        } else if (subscription == _mediaInfoSubscription) {
            _mediaInfoSubscription = nil;
        } else {
            [_subscriptions removeObject:subscription];
        }
    } else if (type == ServiceSubscriptionTypeSubscribe) {
        [_subscriptions addObject:subscription];
    }

    return callId;
}

- (int) getNextId
{
    UID = UID + 1;
    return UID;
}

#pragma mark - GCKSessionManagerListener

- (void)sessionManager:(GCKSessionManager *)sessionManager didStartCastSession:(GCKCastSession *)session {
    DLog(@"Session started for device: %@ (%@)", session.device.friendlyName, session.device.deviceID);
    self.connected = YES;

    // Get the remote media client and add listener
    _remoteMediaClient = session.remoteMediaClient;
    if (_remoteMediaClient) {
        // Remove first to avoid potential duplicates if start is called multiple times
        [_remoteMediaClient removeListener:self];
        [_remoteMediaClient addListener:self];
    } else {
        DLog(@"Remote media client is nil!");
    }

    if (session.applicationMetadata) {
        _currentAppId = session.applicationMetadata.applicationID;
    } else {
        DLog(@"Application metadata is nil on start!");
        _currentAppId = nil;
    }

    dispatch_on_main(^{ [self.delegate deviceServiceConnectionSuccess:self]; });

    // Handle potential launching app callbacks
    if (_launchingAppId && _currentAppId && [_launchingAppId isEqualToString:_currentAppId]) {
        WebAppLaunchSuccessBlock success = [_launchSuccessBlocks objectForKey:_launchingAppId];
        if (success) {
            LaunchSession *launchSession = [LaunchSession launchSessionForAppId:_currentAppId];
            launchSession.name = session.applicationMetadata.applicationName;
            launchSession.sessionId = session.sessionID; // Use GCKCastSession's sessionID
            launchSession.sessionType = LaunchSessionTypeWebApp; // Or Media if applicable
            launchSession.service = self;

            CastWebAppSession *webAppSession = [[CastWebAppSession alloc] initWithLaunchSession:launchSession service:self];
            webAppSession.metadata = session.applicationMetadata;
            if (_currentAppId) {
                [_sessions setObject:webAppSession forKey:_currentAppId];
            }

            // Connect the service channel after creating the session
            [webAppSession connectWithSuccess:^(id launchSession) {
                DLog(@"CastServiceChannel connected for %@.", webAppSession.launchSession.appId);
            } failure:^(NSError *error) {
                DLog(@"CastServiceChannel connection failed for %@: %@", webAppSession.launchSession.appId, error);
            }];

            dispatch_on_main(^{ success(webAppSession); });
        }
        [_launchSuccessBlocks removeObjectForKey:_launchingAppId];
        [_launchFailureBlocks removeObjectForKey:_launchingAppId];
        _launchingAppId = nil;
    }

    // No explicit requestDeviceStatus needed, listener provides updates.
}

- (void)sessionManager:(GCKSessionManager *)sessionManager didResumeCastSession:(GCKCastSession *)session {
    DLog(@"Session resumed for device: %@ (%@)", session.device.friendlyName, session.device.deviceID);
    self.connected = YES;
    // Re-establish remote media client and listener
    _remoteMediaClient = session.remoteMediaClient;
    if (_remoteMediaClient) {
        // Remove first to avoid duplicate listeners if somehow added before
        [_remoteMediaClient removeListener:self];
        [_remoteMediaClient addListener:self];
    } else {
        DLog(@"Remote media client is nil on resume!");
    }

    if (session.applicationMetadata) {
        _currentAppId = session.applicationMetadata.applicationID;
    } else {
        DLog(@"Application metadata is nil on resume!");
        _currentAppId = nil; // Or try to get it differently if possible
    }

    dispatch_on_main(^{ [self.delegate deviceServiceConnectionSuccess:self]; });

    // Request status to sync state
    if (_remoteMediaClient) {
        [_remoteMediaClient requestStatus]; // Keep request for media status
    }
    // No explicit requestDeviceStatus needed for volume/mute.
}

- (void)sessionManager:(GCKSessionManager *)sessionManager didEndCastSession:(GCKCastSession *)session withError:(NSError *)error {
    DLog(@"Session ended for device: %@ with error: %@", session.device.friendlyName, error);
    self.connected = NO;
    _currentAppId = nil;

    if (_remoteMediaClient) {
        [_remoteMediaClient removeListener:self];
    }
    _remoteMediaClient = nil;
    // Maybe clear _sessions? [_sessions removeAllObjects];

    // Clear subscriptions
    _playStateSubscription = nil;
    _mediaInfoSubscription = nil;
    [_subscriptions removeAllObjects];

    // Call disconnect delegate
    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)]) {
        dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:error]; });
    }
}

- (void)sessionManager:(GCKSessionManager *)sessionManager didFailToStartSessionWithError:(NSError *)error {
    DLog(@"Failed to start session with error: %@", error);
    // This is where the failure logic likely belongs
    if (_launchingAppId) {
        FailureBlock failure = [_launchFailureBlocks objectForKey:_launchingAppId];
        if (failure) {
            dispatch_on_main(^{ failure(error); });
        }
        [_launchSuccessBlocks removeObjectForKey:_launchingAppId];
        [_launchFailureBlocks removeObjectForKey:_launchingAppId];
        _launchingAppId = nil;
    }
    self.connected = NO; // Ensure connected state is false
    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:didFailConnectWithError:)]) {
        dispatch_on_main(^{ [self.delegate deviceService:self didFailConnectWithError:error]; });
    } else {
        DLog(@"Delegate does not respond to deviceService:didFailConnectWithError:");
    }
}

- (void)sessionManager:(GCKSessionManager *)sessionManager didSuspendCastSession:(GCKCastSession *)session withReason:(GCKConnectionSuspendReason)reason {
    DLog(@"Session suspended for device: %@ with reason: %ld", session.device.friendlyName, (long)reason);
    self.connected = NO; // Or a different state for suspended?
    if (_remoteMediaClient) {
        [_remoteMediaClient removeListener:self]; // Stop listening while suspended
    }
    _remoteMediaClient = nil; // Clear client while suspended
    _currentAppId = nil;
    // Notify delegate about suspension if applicable/needed
}

#pragma mark - Media Player

- (id<MediaPlayer>)mediaPlayer
{
    return self;
}

- (CapabilityPriorityLevel)mediaPlayerPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)displayImage:(NSURL *)imageURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypePhoto];
    [metaData setString:title forKey:kGCKMetadataKeyTitle];
    [metaData setString:description forKey:kGCKMetadataKeySubtitle];

    if (iconURL)
    {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }
    
    // Use GCKMediaInformationBuilder (Recommended way for SDK v4+)
    GCKMediaInformationBuilder *builder = [[GCKMediaInformationBuilder alloc] initWithContentURL:imageURL];
    builder.contentID = imageURL.absoluteString; // Still useful for some receivers?
    builder.streamType = GCKMediaStreamTypeNone;
    builder.contentType = mimeType;
    builder.metadata = metaData;
    builder.streamDuration = 0;
    GCKMediaInformation *mediaInformation = [builder build];

    [self playMedia:mediaInformation webAppId:self.castWebAppId success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) displayImage:(MediaInfo *)mediaInfo
              success:(MediaPlayerDisplaySuccessBlock)success
              failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    [self displayImage:mediaInfo.url iconURL:iconURL title:mediaInfo.title description:mediaInfo.description mimeType:mediaInfo.mimeType success:success failure:failure];
}

- (void) displayImageWithMediaInfo:(MediaInfo *)mediaInfo success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypePhoto];
    [metaData setString:mediaInfo.title forKey:kGCKMetadataKeyTitle];
    [metaData setString:mediaInfo.description forKey:kGCKMetadataKeySubtitle];
    
    if (iconURL)
    {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }
    
    // Use GCKMediaInformationBuilder
    GCKMediaInformationBuilder *builder = [[GCKMediaInformationBuilder alloc] initWithContentURL:mediaInfo.url];
    builder.contentID = mediaInfo.url.absoluteString;
    builder.streamType = GCKMediaStreamTypeNone;
    builder.contentType = mediaInfo.mimeType;
    builder.metadata = metaData;
    builder.streamDuration = 0;
    GCKMediaInformation *mediaInformation = [builder build];
    
    [self playMedia:mediaInformation webAppId:self.castWebAppId success:success failure:failure];
}

- (void) playMedia:(NSURL *)videoURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypeMovie];
    [metaData setString:title forKey:kGCKMetadataKeyTitle];
    [metaData setString:description forKey:kGCKMetadataKeySubtitle];

    if (iconURL)
    {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }
    
    // Use GCKMediaInformationBuilder
    GCKMediaInformationBuilder *builder = [[GCKMediaInformationBuilder alloc] initWithContentURL:videoURL];
    builder.contentID = videoURL.absoluteString;
    builder.streamType = GCKMediaStreamTypeBuffered;
    builder.contentType = mimeType;
    builder.metadata = metaData;
    builder.streamDuration = 1000; // Or determine duration differently?
    // builder.mediaTracks = nil; // Assume no tracks for this method signature
    // builder.textTrackStyle = nil;
    // builder.customData = nil;
    GCKMediaInformation *mediaInformation = [builder build];

    [self playMedia:mediaInformation webAppId:self.castWebAppId success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) playMedia:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    [self playMedia:mediaInfo.url iconURL:iconURL title:mediaInfo.title description:mediaInfo.description mimeType:mediaInfo.mimeType shouldLoop:shouldLoop success:success failure:failure];
}

- (void) playMediaWithMediaInfo:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypeMovie];
    [metaData setString:mediaInfo.title forKey:kGCKMetadataKeyTitle];
    [metaData setString:mediaInfo.description forKey:kGCKMetadataKeySubtitle];
    
    if (iconURL)
    {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }

    NSArray *mediaTracks;
    if (mediaInfo.subtitleInfo) {
        mediaTracks = @[
            [self mediaTrackFromSubtitleInfo:mediaInfo.subtitleInfo]];
    }

    // Use GCKMediaInformationBuilder
    GCKMediaInformationBuilder *builder = [[GCKMediaInformationBuilder alloc] initWithContentURL:mediaInfo.url];
    builder.contentID = mediaInfo.url.absoluteString;
    // Determine streamType based on media or assume buffered?
    builder.streamType = GCKMediaStreamTypeBuffered; // Or GCKMediaStreamTypeLive
    builder.contentType = mediaInfo.mimeType;
    builder.metadata = metaData;
    builder.streamDuration = mediaInfo.duration; // Use provided duration
    builder.mediaTracks = mediaTracks; // Set tracks if available
    builder.textTrackStyle = [GCKMediaTextTrackStyle createDefault]; // Set default style
    // builder.customData = nil;
    GCKMediaInformation *mediaInformation = [builder build];
    
    [self playMedia:mediaInformation webAppId:self.castWebAppId success:success failure:failure];
}

- (void) playMedia:(GCKMediaInformation *)mediaInformation webAppId:(NSString *)webAppId success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    // NOTE: This method's signature and logic are based on the old SDK flow where
    // playing media also handled launching the web app. In SDK v4, session management
    // and media loading are usually separate.
    // This implementation assumes a session is already active and uses _remoteMediaClient.
    // The webAppId parameter might be redundant now.

    if (!_remoteMediaClient) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"No active Cast session to load media."]);
        }
        return;
    }

    // The old success block expected a WebAppSession. We need to adapt.
    // For now, let's assume the caller just wants to know if the load command was sent.
    // We can create a new success block type if needed, or simplify the interface.

    GCKMediaLoadOptions *options = [[GCKMediaLoadOptions alloc] init];
    options.autoplay = YES;
    // Handle subtitle tracks if needed
    if (mediaInformation.mediaTracks.count > 0) {
         options.activeTrackIDs = @[@(kSubtitleTrackIdentifier)]; // Assuming kSubtitleTrackIdentifier is defined
    }

    GCKRequest *request = [_remoteMediaClient loadMedia:mediaInformation withOptions:options];

    if (!request) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send load media command."]);
        }
    } else {
        // The old success block expected a MediaLaunchObject containing the session
        // and mediaControl. This is hard to replicate directly.
        // We can call success indicating the load command was sent, but provide nil or a simplified object.
        // Or, the calling code needs to be updated to handle the new async flow.
        DLog(@"Load media request sent successfully.");

        // TEMPORARY: Call success with nil, assuming caller handles the async nature.
        // A proper solution might involve using the GCKRequest delegate or observing media status.
        if (success) {
             // Create a placeholder LaunchSession and MediaControl if required by the block signature?
             // This is problematic as the session is managed elsewhere.
             GCKCastSession *currentSession = _sessionManager.currentCastSession;
             if (currentSession) {
                 LaunchSession *launchSession = [LaunchSession launchSessionForAppId:currentSession.applicationMetadata.applicationID];
                 launchSession.name = currentSession.applicationMetadata.applicationName;
                 launchSession.sessionId = currentSession.sessionID;
                 launchSession.sessionType = LaunchSessionTypeMedia; // Indicate media session
                 launchSession.service = self;

                 // The concept of returning a specific MediaControl instance tied to this load is less direct.
                 // The CastService itself acts as the MediaControl delegate.
                 MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:launchSession andMediaControl:self];
                 success(launchObject);
             } else {
                  // Should not happen if _remoteMediaClient exists, but handle defensively.
                  if (failure) {
                      failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Cast session missing unexpectedly."]);
                  }
             }
        }
    }
}

- (void)closeMedia:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    // Stopping media is handled by [remoteMediaClient stop] or ending the session.
    // This method seems intended to stop the media playback specifically.
    // Calling stop on remoteMediaClient is more appropriate here than ending the session.
    [self stopWithSuccess:success failure:failure];
}

#pragma mark - Media Control

- (id<MediaControl>)mediaControl
{
    return self;
}

- (CapabilityPriorityLevel)mediaControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)playWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!_remoteMediaClient) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"Remote media client is not available."]);
        }
        return;
    }

    GCKRequest *request = [_remoteMediaClient play];

    if (!request)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send play command."]);
    } else
    {
        if (success)
            success(nil);
        // Optionally add delegate to request for detailed success/failure
    }
}

- (void)pauseWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!_remoteMediaClient) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"Remote media client is not available."]);
        }
        return;
    }

    GCKRequest *request = [_remoteMediaClient pause];

    if (!request)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send pause command."]);
    } else
    {
        if (success)
            success(nil);
        // Optionally add delegate to request
    }
}

- (void)stopWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!_remoteMediaClient) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"Remote media client is not available."]);
        }
        return;
    }

    GCKRequest *request = [_remoteMediaClient stop];

    if (!request)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send stop command."]);
    } else
    {
        if (success)
            success(nil);
        // Optionally add delegate to request
    }
}

- (void)rewindWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)fastForwardWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)seek:(NSTimeInterval)position
     success:(SuccessBlock)success
     failure:(FailureBlock)failure {
    if (!_remoteMediaClient) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"Remote media client is not available."]);
        }
        return;
    }

    GCKRequest *request = [_remoteMediaClient seekToTimeInterval:position];

    if (!request)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
    } else
    {
        if (success)
            success(nil);
        // Optionally add delegate to request
    }
}

- (void)getDurationWithSuccess:(MediaDurationSuccessBlock)success
                       failure:(FailureBlock)failure {
    GCKMediaStatus *mediaStatus = _remoteMediaClient.mediaStatus;

    if (mediaStatus && mediaStatus.mediaInformation)
    {
        if (success)
            success(mediaStatus.mediaInformation.streamDuration);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"There is no media currently available or media info is missing."]);
    }
}

- (void)getPositionWithSuccess:(MediaPositionSuccessBlock)success
                       failure:(FailureBlock)failure {
    if (_remoteMediaClient)
    {
        if (success)
            success([_remoteMediaClient approximateStreamPosition]);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"Remote media client is not available."]);
    }
}

- (void)getPlayStateWithSuccess:(MediaPlayStateSuccessBlock)success
                        failure:(FailureBlock)failure {
    if (!_remoteMediaClient) {
        if (failure) {
             failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"Remote media client is not available."]);
        }
        return;
    }

    // If mediaStatus is available immediately, return it
    GCKMediaStatus *currentStatus = _remoteMediaClient.mediaStatus;
    if (currentStatus) {
        if (success) {
            success([self getPlayStateFromMediaStatus:currentStatus]);
        }
        return; // Don't request status again if we already have it
    }

    // Otherwise, request status and use the callback
    _immediatePlayStateCallback = success;

    GCKRequest *request = [_remoteMediaClient requestStatus];

    if (!request)
    {
        // Clear callback if request fails
        _immediatePlayStateCallback = nil;

        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
    }
}

- (ServiceSubscription *)subscribePlayStateWithSuccess:(MediaPlayStateSuccessBlock)success
                                               failure:(FailureBlock)failure {
    if (!_playStateSubscription)
        _playStateSubscription = [ServiceSubscription subscriptionWithDelegate:self target:nil payload:nil callId:-1];

    [_playStateSubscription addSuccess:success];
    [_playStateSubscription addFailure:failure];

    // Request initial status if client is available
    if (_remoteMediaClient) {
        [_remoteMediaClient requestStatus];
    } else {
        DLog(@"Cannot request initial play state, no remote client.");
        // Optionally call failure immediately?
        // if (failure) failure(...);
    }

    return _playStateSubscription;
}

- (void)getMediaMetaDataWithSuccess:(SuccessBlock)success
                            failure:(FailureBlock)failure {
    GCKMediaStatus *mediaStatus = _remoteMediaClient.mediaStatus;
    if (mediaStatus && mediaStatus.mediaInformation && mediaStatus.mediaInformation.metadata)
    {
        if (success) {
            success([self metadataInfoFromMediaMetadata:mediaStatus.mediaInformation.metadata]);
        }
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Media status or metadata not available."]);
    }
}

- (ServiceSubscription *)subscribeMediaInfoWithSuccess:(SuccessBlock)success
                                               failure:(FailureBlock)failure {
    if (!_mediaInfoSubscription)
        _mediaInfoSubscription = [ServiceSubscription subscriptionWithDelegate:self target:nil payload:nil callId:-1];

    [_mediaInfoSubscription addSuccess:success];
    [_mediaInfoSubscription addFailure:failure];

    // Request initial status if client is available
    if (_remoteMediaClient) {
        [_remoteMediaClient requestStatus];
    } else {
        DLog(@"Cannot request initial media info, no remote client.");
        // Optionally call failure immediately?
        // if (failure) failure(...);
    }

    return _mediaInfoSubscription;
}

#pragma mark - WebAppLauncher

- (id<WebAppLauncher>)webAppLauncher
{
    return self;
}

- (CapabilityPriorityLevel)webAppLauncherPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)launchWebApp:(NSString *)webAppId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchWebApp:webAppId relaunchIfRunning:YES success:success failure:failure];
}

- (void)launchWebApp:(NSString *)webAppId relaunchIfRunning:(BOOL)relaunchIfRunning success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure message:@"launchWebApp: Direct launch is not supported in the updated Cast SDK flow."];
}

- (void)launchWebApp:(NSString *)webAppId params:(NSDictionary *)params success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)launchWebApp:(NSString *)webAppId params:(NSDictionary *)params relaunchIfRunning:(BOOL)relaunchIfRunning success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)joinWebApp:(LaunchSession *)webAppLaunchSession success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure message:@"joinWebApp: Joining is handled automatically by session resumption."];
}

- (void) joinWebAppWithId:(NSString *)webAppId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure message:@"joinWebAppWithId: Joining is handled automatically by session resumption."];
}

- (void)closeWebApp:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    // Ensure we are closing the currently active session if the launchSession matches
    GCKCastSession *currentSession = _sessionManager.currentCastSession;
    if (currentSession && [currentSession.sessionID isEqualToString:launchSession.sessionId])
    {
        // endSessionAndStopCasting:YES will trigger the didEnd delegate method
        BOOL requested = [_sessionManager endSessionAndStopCasting:YES];
        if (requested) {
            // Success here means the request was sent.
            // Actual confirmation happens in the didEndCastSession listener.
            if (success) {
                success(nil);
            }
        } else {
            if (failure) {
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send end session request."]);
            }
        }
    } else if (!currentSession) {
        // No session is active, consider it already closed.
        if (success)
            success(nil);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"The requested session to close is not the currently active session."]);
    }
}

- (void) pinWebApp:(NSString *)webAppId success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

-(void)unPinWebApp:(NSString *)webAppId success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)isWebAppPinned:(NSString *)webAppId success:(WebAppPinStatusBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeIsWebAppPinned:(NSString*)webAppId success:(WebAppPinStatusBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
    return nil;
}

#pragma mark - Volume Control

- (id <VolumeControl>)volumeControl
{
    return self;
}

- (CapabilityPriorityLevel)volumeControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)volumeUpWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self getVolumeWithSuccess:^(float volume)
    {
        if (volume >= 1.0)
        {
            if (success)
                success(nil);
        } else
        {
            float newVolume = volume + 0.01;

            if (newVolume > 1.0)
                newVolume = 1.0;

            [self setVolume:newVolume success:success failure:failure];
        }
    } failure:failure];
}

- (void)volumeDownWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self getVolumeWithSuccess:^(float volume)
    {
        if (volume <= 0.0)
        {
            if (success)
                success(nil);
        } else
        {
            float newVolume = volume - 0.01;

            if (newVolume < 0.0)
                newVolume = 0.0;

            [self setVolume:newVolume success:success failure:failure];
        }
    } failure:failure];
}

- (void)setMute:(BOOL)mute success:(SuccessBlock)success failure:(FailureBlock)failure
{
    GCKCastSession *session = _sessionManager.currentCastSession;

    if (!session) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"No active Cast session to set mute."]);
        }
        return;
    }

    GCKRequest *request = [session setDeviceMuted:mute];

    if (!request)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send setMute command."]);
    } else
    {
        // Status update will be received via listener
        if (success)
            success(nil);
        // Optionally add delegate to request
    }
}

- (void)getMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure
{
    // Check if we have a valid session; mute status is only relevant during a session.
    if (_sessionManager.hasConnectedCastSession)
    {
        if (success)
            success(_currentMuteStatus);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"No active Cast session available to get mute status."]);
    }
}

- (ServiceSubscription *)subscribeMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure
{
    // Call success immediately only if session is active and we have a current status
    if (_sessionManager.hasConnectedCastSession)
    {
        if (success)
            success(_currentMuteStatus);
    } else {
        // Optionally call failure if no session? Or just wait for session start.
        DLog(@"subscribeMute: No active session, waiting for status update.");
    }

    ServiceSubscription *subscription = [ServiceSubscription subscriptionWithDelegate:self target:nil payload:kCastServiceMuteSubscriptionName callId:[self getNextId]];
    [subscription addSuccess:success];
    [subscription addFailure:failure];
    [subscription subscribe];

    // No need to request status here, listener handles updates
    return subscription;
}

- (void)setVolume:(float)volume success:(SuccessBlock)success failure:(FailureBlock)failure
{
    GCKCastSession *session = _sessionManager.currentCastSession;

    if (!session) {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"No active Cast session to set volume."]);
        }
        return;
    }

    GCKRequest *request = [session setDeviceVolume:volume];

    if (!request)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Failed to send setVolume command."]);
    } else
    {
        // Status update will be received via listener
        if (success)
            success(nil);
        // Optionally add delegate to request
    }
}

- (void)getVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure
{
    // Check if we have a valid session; volume status is only relevant during a session.
    if (_sessionManager.hasConnectedCastSession)
    {
        if (success)
            success(_currentVolumeLevel);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotConnected andDetails:@"No active Cast session available to get volume status."]);
    }
}

- (ServiceSubscription *)subscribeVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure
{
    // Call success immediately only if session is active
    if (_sessionManager.hasConnectedCastSession)
    {
        if (success)
            success(_currentVolumeLevel);
    } else {
        // Optionally call failure if no session? Or just wait for session start.
        DLog(@"subscribeVolume: No active session, waiting for status update.");
    }

    ServiceSubscription *subscription = [ServiceSubscription subscriptionWithDelegate:self target:nil payload:kCastServiceVolumeSubscriptionName callId:[self getNextId]];
    [subscription addSuccess:success];
    [subscription addFailure:failure];
    [subscription subscribe];

    // No need to request status here, listener handles updates
    return subscription;
}

#pragma mark - Private

- (GCKMediaTrack *)mediaTrackFromSubtitleInfo:(SubtitleInfo *)subtitleInfo {
    return [[GCKMediaTrack alloc]
        initWithIdentifier:kSubtitleTrackIdentifier
         contentIdentifier:subtitleInfo.url.absoluteString
               contentType:subtitleInfo.mimeType
                      type:GCKMediaTrackTypeText
               textSubtype:GCKMediaTextTrackSubtypeSubtitles
                      name:subtitleInfo.label
        // languageCode is required when the track is subtitles
              languageCode:subtitleInfo.language ?: kSubtitleTrackDefaultLanguage
                customData:nil];
}

- (NSDictionary *)metadataInfoFromMediaMetadata:(GCKMediaMetadata *)metaData {
    NSMutableDictionary *mediaMetaData = [NSMutableDictionary dictionary];

    [mediaMetaData setNullableObject:[metaData objectForKey:kGCKMetadataKeyTitle]
                              forKey:@"title"];
    [mediaMetaData setNullableObject:[metaData objectForKey:kGCKMetadataKeySubtitle]
                              forKey:@"subtitle"];

    NSString *const kMetadataKeyIconURL = @"iconURL";
    GCKImage *image = [metaData.images firstObject];
    [mediaMetaData setNullableObject:image.URL.absoluteString
                              forKey:kMetadataKeyIconURL];
    if (!mediaMetaData[kMetadataKeyIconURL]) {
        NSDictionary *imageDict = [[metaData objectForKey:@"images"] firstObject];
        [mediaMetaData setNullableObject:imageDict[@"url"]
                                  forKey:kMetadataKeyIconURL];
    }

    return mediaMetaData;
}

// Implementation for sendNotSupportedFailure
// Add implementation for sendNotSupportedFailure here
- (void)sendNotSupportedFailure:(FailureBlock)failure message:(NSString *)message {
    if (failure) {
        NSString *errorMessage = message ?: @"This capability is not supported on Cast.";
        NSError *error = [ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:errorMessage];
        dispatch_on_main(^{ failure(error); });
    }
}

@end

