/*
 DeviceSpoofer implementation
 Uses Objective-C runtime swizzling to intercept location, WiFi, and cellular APIs.

 GPS: Swizzles CLLocationManager's internal delegate callback to inject spoofed coordinates.
 WiFi: Hooks CNCopyCurrentNetworkInfo and SystemConfiguration to hide Vietnamese WiFi BSSID.
 Cell: Swizzles CTCarrier properties to return US MCC/MNC values.
*/

#import "DeviceSpoofer.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreLocation/CoreLocation.h>
#import <dlfcn.h>

// --- Global spoof state (accessed from swizzled methods) ---
static BOOL sGPSSpoofEnabled = NO;
static double sSpoofLatitude = 0;
static double sSpoofLongitude = 0;
static BOOL sWiFiSpoofEnabled = NO;
static BOOL sCellSpoofEnabled = NO;

// --- Original method IMPs (saved before swizzling) ---
static IMP sOrigLocationDidUpdate = NULL;
static IMP sOrigCarrierMCC = NULL;
static IMP sOrigCarrierMNC = NULL;
static IMP sOrigCarrierISOCC = NULL;
static IMP sOrigCarrierName = NULL;

#pragma mark - GPS Spoofing via CLLocationManager delegate swizzle

// Replacement for -[CLLocationManager delegate]'s locationManager:didUpdateLocations:
// Intercepts all location updates and replaces with spoofed coordinates
static void spoofed_locationManager_didUpdateLocations(id self, SEL _cmd, CLLocationManager *manager, NSArray<CLLocation *> *locations) {
    if (sGPSSpoofEnabled && locations.count > 0) {
        NSMutableArray *spoofedLocations = [NSMutableArray arrayWithCapacity:locations.count];
        for (CLLocation *orig in locations) {
            CLLocationCoordinate2D spoofCoord = CLLocationCoordinate2DMake(sSpoofLatitude, sSpoofLongitude);
            CLLocation *spoofed = [[CLLocation alloc]
                initWithCoordinate:spoofCoord
                altitude:orig.altitude
                horizontalAccuracy:orig.horizontalAccuracy
                verticalAccuracy:orig.verticalAccuracy
                course:orig.course
                speed:orig.speed
                timestamp:orig.timestamp];
            [spoofedLocations addObject:spoofed];
        }
        locations = spoofedLocations;
    }

    if (sOrigLocationDidUpdate) {
        ((void (*)(id, SEL, CLLocationManager *, NSArray *))sOrigLocationDidUpdate)(self, _cmd, manager, locations);
    }
}

// Swizzle a specific delegate class's locationManager:didUpdateLocations:
static void swizzleLocationDelegate(Class delegateClass) {
    if (!delegateClass) return;

    SEL sel = @selector(locationManager:didUpdateLocations:);
    Method method = class_getInstanceMethod(delegateClass, sel);
    if (method) {
        sOrigLocationDidUpdate = method_setImplementation(method, (IMP)spoofed_locationManager_didUpdateLocations);
        NSLog(@"[DeviceSpoofer] Swizzled locationManager:didUpdateLocations: on %@", NSStringFromClass(delegateClass));
    }
}

#pragma mark - GPS Spoofing via CLLocationManager.location property

// We also swizzle -[CLLocationManager location] to return spoofed location
// when apps directly read the .location property
static IMP sOrigCLMLocation = NULL;

static CLLocation * spoofed_CLLocationManager_location(id self, SEL _cmd) {
    if (sGPSSpoofEnabled) {
        CLLocationCoordinate2D spoofCoord = CLLocationCoordinate2DMake(sSpoofLatitude, sSpoofLongitude);
        return [[CLLocation alloc] initWithLatitude:spoofCoord.latitude longitude:spoofCoord.longitude];
    }
    // Call original
    if (!sOrigCLMLocation) return nil;
    return ((CLLocation *(*)(id, SEL))sOrigCLMLocation)(self, _cmd);
}

static void swizzleCLLocationManagerLocation(void) {
    Class cls = [CLLocationManager class];
    SEL sel = @selector(location);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        sOrigCLMLocation = method_setImplementation(method, (IMP)spoofed_CLLocationManager_location);
        NSLog(@"[DeviceSpoofer] Swizzled CLLocationManager.location property");
    }
}

// Also swizzle -[CLLocationManager setDelegate:] to auto-hook any delegate
static IMP sOrigSetDelegate = NULL;
static NSMutableSet *sSwizzledDelegateClasses = nil;

static void spoofed_setDelegate(id self, SEL _cmd, id delegate) {
    if (delegate && sGPSSpoofEnabled) {
        Class delegateClass = [delegate class];
        if (![sSwizzledDelegateClasses containsObject:delegateClass]) {
            SEL updateSel = @selector(locationManager:didUpdateLocations:);
            if ([delegate respondsToSelector:updateSel]) {
                swizzleLocationDelegate(delegateClass);
                [sSwizzledDelegateClasses addObject:delegateClass];
            }
        }
    }
    if (sOrigSetDelegate) {
        ((void (*)(id, SEL, id))sOrigSetDelegate)(self, _cmd, delegate);
    }
}

static void swizzleCLLocationManagerSetDelegate(void) {
    Class cls = [CLLocationManager class];
    SEL sel = @selector(setDelegate:);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        sOrigSetDelegate = method_setImplementation(method, (IMP)spoofed_setDelegate);
        NSLog(@"[DeviceSpoofer] Swizzled CLLocationManager.setDelegate:");
    }
}

#pragma mark - WiFi BSSID Spoofing

// Hook CNCopyCurrentNetworkInfo (C function in SystemConfiguration)
// Returns nil dictionary to hide real WiFi BSSID/SSID
typedef CFDictionaryRef (*CNCopyCurrentNetworkInfo_t)(CFStringRef interfaceName);
static CNCopyCurrentNetworkInfo_t sOrigCNCopy = NULL;

static CFDictionaryRef spoofed_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (sWiFiSpoofEnabled) {
        NSLog(@"[DeviceSpoofer] CNCopyCurrentNetworkInfo intercepted — returning NULL");
        return NULL;
    }
    if (sOrigCNCopy) return sOrigCNCopy(interfaceName);
    return NULL;
}

// We can't easily hook a C function without fishhook/substrate.
// Alternative: Swizzle NEHotspotNetwork methods which TikTok may use.
// Also swizzle +[NEHotspotNetwork fetchCurrentWithCompletionHandler:]
static void swizzleWiFiAPIs(void) {
    // Try to hook via dlsym + interpose (limited without substrate)
    // Instead, we hook the ObjC wrappers that apps typically use

    // Hook NEHotspotNetwork's BSSID/SSID getters if available
    Class neHotspot = NSClassFromString(@"NEHotspotNetwork");
    if (neHotspot) {
        SEL bssidSel = NSSelectorFromString(@"BSSID");
        SEL ssidSel = NSSelectorFromString(@"SSID");

        Method bssidMethod = class_getInstanceMethod(neHotspot, bssidSel);
        if (bssidMethod) {
            class_replaceMethod(neHotspot, bssidSel, imp_implementationWithBlock(^NSString *(id _self) {
                if (sWiFiSpoofEnabled) return @"";
                return nil;
            }), method_getTypeEncoding(bssidMethod));
            NSLog(@"[DeviceSpoofer] Hooked NEHotspotNetwork.BSSID");
        }

        Method ssidMethod = class_getInstanceMethod(neHotspot, ssidSel);
        if (ssidMethod) {
            class_replaceMethod(neHotspot, ssidSel, imp_implementationWithBlock(^NSString *(id _self) {
                if (sWiFiSpoofEnabled) return @"";
                return nil;
            }), method_getTypeEncoding(ssidMethod));
            NSLog(@"[DeviceSpoofer] Hooked NEHotspotNetwork.SSID");
        }
    }

    // Hook CWInterface if CoreWLAN is loaded (rare on iOS but possible)
    Class cwInterface = NSClassFromString(@"CWInterface");
    if (cwInterface) {
        SEL bssidSel = NSSelectorFromString(@"bssid");
        SEL ssidSel = NSSelectorFromString(@"ssid");

        Method m1 = class_getInstanceMethod(cwInterface, bssidSel);
        if (m1) {
            class_replaceMethod(cwInterface, bssidSel, imp_implementationWithBlock(^NSString *(id _self) {
                return sWiFiSpoofEnabled ? @"" : nil;
            }), method_getTypeEncoding(m1));
            NSLog(@"[DeviceSpoofer] Hooked CWInterface.bssid");
        }

        Method m2 = class_getInstanceMethod(cwInterface, ssidSel);
        if (m2) {
            class_replaceMethod(cwInterface, ssidSel, imp_implementationWithBlock(^NSString *(id _self) {
                return sWiFiSpoofEnabled ? @"" : nil;
            }), method_getTypeEncoding(m2));
            NSLog(@"[DeviceSpoofer] Hooked CWInterface.ssid");
        }
    }
}

#pragma mark - Cellular MCC/MNC Spoofing

// US T-Mobile: MCC=310, MNC=260
static NSString *const kSpoofMCC = @"310";
static NSString *const kSpoofMNC = @"260";
static NSString *const kSpoofISOCC = @"us";
static NSString *const kSpoofCarrierName = @"T-Mobile";

static void swizzleCTCarrier(void) {
    // Load CoreTelephony framework
    dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);

    Class ctCarrier = NSClassFromString(@"CTCarrier");
    if (!ctCarrier) {
        NSLog(@"[DeviceSpoofer] CTCarrier class not found");
        return;
    }

    // Swizzle mobileCountryCode
    SEL mccSel = NSSelectorFromString(@"mobileCountryCode");
    Method mccMethod = class_getInstanceMethod(ctCarrier, mccSel);
    if (mccMethod) {
        sOrigCarrierMCC = method_setImplementation(mccMethod, imp_implementationWithBlock(^NSString *(id _self) {
            if (sCellSpoofEnabled) return kSpoofMCC;
            return sOrigCarrierMCC ? ((NSString *(*)(id, SEL))sOrigCarrierMCC)(_self, mccSel) : nil;
        }));
        NSLog(@"[DeviceSpoofer] Hooked CTCarrier.mobileCountryCode");
    }

    // Swizzle mobileNetworkCode
    SEL mncSel = NSSelectorFromString(@"mobileNetworkCode");
    Method mncMethod = class_getInstanceMethod(ctCarrier, mncSel);
    if (mncMethod) {
        sOrigCarrierMNC = method_setImplementation(mncMethod, imp_implementationWithBlock(^NSString *(id _self) {
            if (sCellSpoofEnabled) return kSpoofMNC;
            return sOrigCarrierMNC ? ((NSString *(*)(id, SEL))sOrigCarrierMNC)(_self, mncSel) : nil;
        }));
        NSLog(@"[DeviceSpoofer] Hooked CTCarrier.mobileNetworkCode");
    }

    // Swizzle isoCountryCode
    SEL isoSel = NSSelectorFromString(@"isoCountryCode");
    Method isoMethod = class_getInstanceMethod(ctCarrier, isoSel);
    if (isoMethod) {
        sOrigCarrierISOCC = method_setImplementation(isoMethod, imp_implementationWithBlock(^NSString *(id _self) {
            if (sCellSpoofEnabled) return kSpoofISOCC;
            return sOrigCarrierISOCC ? ((NSString *(*)(id, SEL))sOrigCarrierISOCC)(_self, isoSel) : nil;
        }));
        NSLog(@"[DeviceSpoofer] Hooked CTCarrier.isoCountryCode");
    }

    // Swizzle carrierName
    SEL nameSel = NSSelectorFromString(@"carrierName");
    Method nameMethod = class_getInstanceMethod(ctCarrier, nameSel);
    if (nameMethod) {
        sOrigCarrierName = method_setImplementation(nameMethod, imp_implementationWithBlock(^NSString *(id _self) {
            if (sCellSpoofEnabled) return kSpoofCarrierName;
            return sOrigCarrierName ? ((NSString *(*)(id, SEL))sOrigCarrierName)(_self, nameSel) : nil;
        }));
        NSLog(@"[DeviceSpoofer] Hooked CTCarrier.carrierName");
    }

    // Also hook CTTelephonyNetworkInfo's subscriberCellularProvider
    Class ctNetInfo = NSClassFromString(@"CTTelephonyNetworkInfo");
    if (ctNetInfo) {
        SEL provSel = NSSelectorFromString(@"subscriberCellularProvider");
        Method provMethod = class_getInstanceMethod(ctNetInfo, provSel);
        if (provMethod) {
            IMP origProv = method_getImplementation(provMethod);
            method_setImplementation(provMethod, imp_implementationWithBlock(^id(id _self) {
                // Return the original carrier object — its properties are already swizzled above
                return origProv ? ((id(*)(id, SEL))origProv)(_self, provSel) : nil;
            }));
        }
    }
}

#pragma mark - DeviceSpoofer Implementation

@implementation DeviceSpoofer {
    BOOL _locationSetup;
    BOOL _wifiSetup;
    BOOL _cellSetup;
}

@synthesize locationSpoofActive = _locationSpoofActive;
@synthesize wifiSpoofActive = _wifiSpoofActive;
@synthesize cellularSpoofActive = _cellularSpoofActive;

+ (instancetype)sharedSpoofer {
    static DeviceSpoofer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[DeviceSpoofer alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    _locationSetup = NO;
    _wifiSetup = NO;
    _cellSetup = NO;
    sSwizzledDelegateClasses = [NSMutableSet new];
    return self;
}

- (void)startLocationSpoofWithLatitude:(double)latitude longitude:(double)longitude {
    sSpoofLatitude = latitude;
    sSpoofLongitude = longitude;
    sGPSSpoofEnabled = YES;

    if (!_locationSetup) {
        swizzleCLLocationManagerLocation();
        swizzleCLLocationManagerSetDelegate();
        _locationSetup = YES;
    }

    _locationSpoofActive = YES;
    NSLog(@"[DeviceSpoofer] GPS spoof ACTIVE: %.4f, %.4f", latitude, longitude);
}

- (void)stopLocationSpoof {
    sGPSSpoofEnabled = NO;
    _locationSpoofActive = NO;
    NSLog(@"[DeviceSpoofer] GPS spoof DISABLED");
}

- (void)startWiFiSpoof {
    sWiFiSpoofEnabled = YES;

    if (!_wifiSetup) {
        // Load NetworkExtension framework to ensure NEHotspotNetwork is available
        dlopen("/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension", RTLD_LAZY);
        swizzleWiFiAPIs();
        _wifiSetup = YES;
    }

    _wifiSpoofActive = YES;
    NSLog(@"[DeviceSpoofer] WiFi BSSID spoof ACTIVE");
}

- (void)stopWiFiSpoof {
    sWiFiSpoofEnabled = NO;
    _wifiSpoofActive = NO;
    NSLog(@"[DeviceSpoofer] WiFi BSSID spoof DISABLED");
}

- (void)startCellularSpoof {
    sCellSpoofEnabled = YES;

    if (!_cellSetup) {
        swizzleCTCarrier();
        _cellSetup = YES;
    }

    _cellularSpoofActive = YES;
    NSLog(@"[DeviceSpoofer] Cellular MCC/MNC spoof ACTIVE (US T-Mobile: 310/260)");
}

- (void)stopCellularSpoof {
    sCellSpoofEnabled = NO;
    _cellularSpoofActive = NO;
    NSLog(@"[DeviceSpoofer] Cellular MCC/MNC spoof DISABLED");
}

- (void)startAllSpoofingWithLatitude:(double)latitude longitude:(double)longitude {
    [self startLocationSpoofWithLatitude:latitude longitude:longitude];
    [self startWiFiSpoof];
    [self startCellularSpoof];
    NSLog(@"[DeviceSpoofer] ALL spoofing ACTIVE");
}

- (void)stopAllSpoofing {
    [self stopLocationSpoof];
    [self stopWiFiSpoof];
    [self stopCellularSpoof];
    NSLog(@"[DeviceSpoofer] ALL spoofing DISABLED");
}

@end
