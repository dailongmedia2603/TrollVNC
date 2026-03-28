/*
 DeviceSpoofer - Anti-detection for location, WiFi, and cellular
 Hooks CLLocationManager, CWInterface/CNCopyCurrentNetworkInfo, CTCarrier
 to return spoofed US values.

 Uses Objective-C runtime swizzling to intercept system APIs globally.
 Requires platform-application entitlement (available via TrollStore).
*/

#ifndef DeviceSpoofer_h
#define DeviceSpoofer_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DeviceSpoofer : NSObject

+ (instancetype)sharedSpoofer;

/// Enable GPS location spoofing with given coordinates
- (void)startLocationSpoofWithLatitude:(double)latitude longitude:(double)longitude;

/// Disable GPS location spoofing
- (void)stopLocationSpoof;

/// Enable WiFi BSSID/SSID spoofing (hides real Vietnamese WiFi info)
- (void)startWiFiSpoof;

/// Disable WiFi spoofing
- (void)stopWiFiSpoof;

/// Enable Cell Tower MCC/MNC spoofing (reports US carrier info)
- (void)startCellularSpoof;

/// Disable Cell Tower spoofing
- (void)stopCellularSpoof;

/// Enable all spoofing at once
- (void)startAllSpoofingWithLatitude:(double)latitude longitude:(double)longitude;

/// Disable all spoofing
- (void)stopAllSpoofing;

/// Current spoof state
@property (nonatomic, readonly) BOOL locationSpoofActive;
@property (nonatomic, readonly) BOOL wifiSpoofActive;
@property (nonatomic, readonly) BOOL cellularSpoofActive;

@end

NS_ASSUME_NONNULL_END

#endif /* DeviceSpoofer_h */
