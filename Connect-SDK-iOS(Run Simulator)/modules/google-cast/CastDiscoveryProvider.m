//
//  CastDiscoveryProvider.m
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

#import "CastDiscoveryProvider.h"
#import <GoogleCast/GoogleCast.h>
#import "ServiceDescription.h"
#import "CastService.h"

@interface CastDiscoveryProvider () <GCKDiscoveryManagerListener>
{
    // GCKDeviceScanner is replaced by GCKDiscoveryManager from GCKCastContext
    NSMutableDictionary *_devices;
    NSMutableDictionary *_deviceDescriptions;
}

@end

@implementation CastDiscoveryProvider

- (instancetype) init
{
    self = [super init];
    
    if (self)
    {
        _devices = [NSMutableDictionary new];
        _deviceDescriptions = [NSMutableDictionary new];
    }
    
    return self;
}

- (void)startDiscovery
{
    self.isRunning = YES;

    GCKDiscoveryManager *discoveryManager = [GCKCastContext sharedInstance].discoveryManager;
    [discoveryManager addListener:self];
    // Discovery usually starts automatically based on context/UI
    // No explicit startScan needed in most V4 setups.
}

- (void)stopDiscovery
{
    self.isRunning = NO;

    GCKDiscoveryManager *discoveryManager = [GCKCastContext sharedInstance].discoveryManager;
    [discoveryManager removeListener:self];

    _devices = [NSMutableDictionary new];
    _deviceDescriptions = [NSMutableDictionary new];
}

- (BOOL) isEmpty
{
    // Since we are only searching for one type of device & parameters are unnecessary
    return NO;
}

#pragma mark - GCKDiscoveryManagerListener

// This method is called when the list of discovered devices changes.
- (void)didUpdateDeviceList {
    GCKDiscoveryManager *discoveryManager = [GCKCastContext sharedInstance].discoveryManager;
    DLog(@"Device list updated. Count: %lu", (unsigned long)discoveryManager.deviceCount);

    NSMutableDictionary *updatedDevices = [NSMutableDictionary new];
    NSMutableDictionary *updatedDeviceDescriptions = [NSMutableDictionary new];

    // Iterate through the current list of devices found by the manager
    for (NSUInteger i = 0; i < discoveryManager.deviceCount; ++i) {
        GCKDevice *device = [discoveryManager deviceAtIndex:i];

        // --- Extract Device Info (Adjust property names as needed for v4) ---
        // NOTE: deviceID is now recommended over UUID for unique identification.
        NSString *deviceID = device.deviceID;
        if (!deviceID) continue; // Skip if no deviceID

        NSString *ipAddress = device.ipAddress;
        NSString *friendlyName = device.friendlyName;
        NSInteger port = device.servicePort;
        NSString *modelName = device.modelName;
        // ------------------------------------------------------------------

        [updatedDevices setObject:device forKey:deviceID];

        ServiceDescription *serviceDescription = [_deviceDescriptions objectForKey:deviceID];
        BOOL isNew = NO;

        if (!serviceDescription) {
            // Device is new or was previously lost
            isNew = YES;
            // Create new ServiceDescription
            // Note: Use deviceID for UUID field in ServiceDescription if appropriate
            serviceDescription = [ServiceDescription descriptionWithAddress:ipAddress UUID:deviceID];
            serviceDescription.serviceId = kConnectSDKCastServiceId;
        }

        // Update properties (might have changed, e.g., name, ip)
        serviceDescription.friendlyName = friendlyName;
        serviceDescription.address = ipAddress;
        serviceDescription.port = port;
        serviceDescription.modelName = modelName;

        [updatedDeviceDescriptions setObject:serviceDescription forKey:deviceID];

        if (isNew) {
            DLog(@"Found new device: %@ (%@)", friendlyName, deviceID);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate discoveryProvider:self didFindService:serviceDescription];
            });
        }
    }

    // Find lost devices (devices in _devices but not in updatedDevices)
    NSMutableDictionary *lostDeviceDescriptions = [NSMutableDictionary new];
    [_devices enumerateKeysAndObjectsUsingBlock:^(NSString *deviceID, id obj, BOOL *stop) {
        if (!updatedDevices[deviceID]) {
            ServiceDescription *lostService = [_deviceDescriptions objectForKey:deviceID];
            if (lostService) {
                [lostDeviceDescriptions setObject:lostService forKey:deviceID];
            }
        }
    }];

    [lostDeviceDescriptions enumerateKeysAndObjectsUsingBlock:^(NSString *deviceID, ServiceDescription *lostService, BOOL *stop) {
        DLog(@"Lost device: %@ (%@)", lostService.friendlyName, deviceID);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate discoveryProvider:self didLoseService:lostService];
        });
    }];

    // Update internal dictionaries
    _devices = updatedDevices;
    _deviceDescriptions = updatedDeviceDescriptions;
}

// Add other GCKDiscoveryManagerListener methods if needed (e.g., didStartDiscovery, didStopDiscovery)

@end
