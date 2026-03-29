/*
 PhoneClaw HTTP API Server
 Lightweight socket-based HTTP server for programmatic device control.
 Uses GCD (Grand Central Dispatch) for async I/O.

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2.
*/

#import "PhoneClawAPI.h"
#import "STHIDEventGenerator.h"
#import "ClipboardManager.h"
#import "BulletinManager.h"
#import "DeviceSpoofer.h"

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#include <atomic>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreLocation/CoreLocation.h>

// SpringBoardServices launch API (available with com.apple.springboard.launchapplications entitlement)
extern "C" int SBSLaunchApplicationWithIdentifier(CFStringRef identifier, Boolean suspended);
extern "C" CFStringRef SBSApplicationLaunchingErrorString(int error);

// Screen buffer access - provided by trollvncserver via setScreenBuffer
static void *sScreenBuffer = NULL;
static int sScreenWidth = 0;
static int sScreenHeight = 0;

// VNC globals from trollvncserver — needed for coordinate transform
extern int gSrcWidth, gSrcHeight;   // capture source dimensions (portrait)
extern int gWidth, gHeight;          // VNC framebuffer dimensions (post-rotation, post-scale)
extern std::atomic<int> gRotationQuad;
extern BOOL gOrientationSyncEnabled;
extern BOOL gShouldApplyOrientationFix;

/**
 * Convert normalized (0-1) coordinates to device touch point.
 * Same transform as vncPointToDevicePoint in trollvncserver.mm.
 * This ensures HTTP API taps land at the exact same position as VNC Live taps.
 */
static CGPoint normalizedToDevicePoint(CGFloat nx, CGFloat ny) {
    // Convert normalized to VNC pixel coords
    int vx = (int)(nx * sScreenWidth);
    int vy = (int)(ny * sScreenHeight);

    // --- Same logic as vncPointToDevicePoint ---
    int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;

#if !TARGET_IPHONE_SIMULATOR
    int effRotQ = (rotQ + (gShouldApplyOrientationFix ? 3 : 0)) & 3;
#else
    int effRotQ = rotQ;
#endif

    int rotW = (effRotQ % 2 == 0) ? gSrcWidth : gSrcHeight;
    int rotH = (effRotQ % 2 == 0) ? gSrcHeight : gSrcWidth;

    double sx = (gWidth > 0) ? ((double)rotW / (double)gWidth) : 1.0;
    double sy = (gHeight > 0) ? ((double)rotH / (double)gHeight) : 1.0;
    double stX = sx * (double)vx;
    double stY = sy * (double)vy;

    if (stX < 0) stX = 0;
    if (stY < 0) stY = 0;
    if (stX > (double)(rotW - 1)) stX = (double)(rotW - 1);
    if (stY > (double)(rotH - 1)) stY = (double)(rotH - 1);

    double dx = 0.0, dy = 0.0;
    switch (effRotQ) {
        case 0: dx = stX; dy = stY; break;
        case 1: dx = stY; dy = (double)(gSrcHeight - 1) - stX; break;
        case 2: dx = (double)(gSrcWidth - 1) - stX; dy = (double)(gSrcHeight - 1) - stY; break;
        case 3: dx = (double)(gSrcWidth - 1) - stY; dy = stX; break;
    }

    if (dx < 0) dx = 0;
    if (dy < 0) dy = 0;
    if (dx > (double)(gSrcWidth - 1)) dx = (double)(gSrcWidth - 1);
    if (dy > (double)(gSrcHeight - 1)) dy = (double)(gSrcHeight - 1);

    return CGPointMake((CGFloat)dx, (CGFloat)dy);
}
static int sScreenBytesPerPixel = 4;

#pragma mark - Helpers

static NSData *jsonResponse(NSDictionary *dict) {
    return [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
}

static NSDictionary *_Nullable parseJSON(NSData *body) {
    if (!body || body.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
}

static NSData *screenshotJPEG(CGFloat quality) {
    if (!sScreenBuffer || sScreenWidth <= 0 || sScreenHeight <= 0) return nil;

    size_t w = (size_t)sScreenWidth;
    size_t h = (size_t)sScreenHeight;
    size_t bpr = w * (size_t)sScreenBytesPerPixel;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        sScreenBuffer, w, h, 8, bpr,
        cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little
    );
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!img) return nil;

    NSMutableData *jpegData = [NSMutableData data];
    CFStringRef jpegUTI = CFSTR("public.jpeg");
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)jpegData, jpegUTI, 1, NULL
    );
    if (dest) {
        NSDictionary *opts = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)};
        CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)opts);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(img);
    return jpegData;
}

#pragma mark - PhoneClawAPI

// --- Proxy UserDefaults keys (persisted in com.82flex.trollvnc domain) ---
static NSString *const kProxyIP       = @"ProxyIP";
static NSString *const kProxyPort     = @"ProxyPort";
static NSString *const kProxyUser     = @"ProxyUser";
static NSString *const kProxyPass     = @"ProxyPass";
static NSString *const kProxyEnabled  = @"ProxyEnabled";
static NSString *const kProxyMode     = @"ProxyMode"; // "us", "vn", "none"
static NSString *const kSpoofTimezone = @"SpoofTimezone";
static NSString *const kSpoofLocale   = @"SpoofLocale";
static NSString *const kSpoofLat      = @"SpoofLatitude";
static NSString *const kSpoofLon      = @"SpoofLongitude";

@implementation PhoneClawAPI {
    int _serverSocket;
    dispatch_source_t _acceptSource;
    BOOL _running;
    // Proxy tunnel
    pid_t _singboxPid;
    BOOL _proxyRunning;
    NSDate *_proxyStartTime;
}

+ (instancetype)sharedAPI {
    static PhoneClawAPI *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PhoneClawAPI alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    _serverSocket = -1;
    _running = NO;
    _singboxPid = 0;
    _proxyRunning = NO;
    _proxyStartTime = nil;
    return self;
}

- (void)setScreenBuffer:(void *)buffer width:(int)w height:(int)h bytesPerPixel:(int)bpp {
    sScreenBuffer = buffer;
    sScreenWidth = w;
    sScreenHeight = h;
    sScreenBytesPerPixel = bpp;
}

- (void)startOnPort:(uint16_t)port {
    if (_running) return;

    _serverSocket = socket(AF_INET6, SOCK_STREAM, 0);
    if (_serverSocket < 0) {
        NSLog(@"[PhoneClawAPI] Failed to create socket");
        return;
    }

    int yes = 1;
    setsockopt(_serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    // Allow IPv4 connections on IPv6 socket
    int no = 0;
    setsockopt(_serverSocket, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    struct sockaddr_in6 addr = {};
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(port);
    addr.sin6_addr = in6addr_any;

    if (bind(_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[PhoneClawAPI] Failed to bind port %d: %s", port, strerror(errno));
        close(_serverSocket);
        _serverSocket = -1;
        return;
    }

    listen(_serverSocket, 8);

    _acceptSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, _serverSocket, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
    );

    __weak PhoneClawAPI *weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        PhoneClawAPI *strongSelf = weakSelf;
        if (strongSelf) [strongSelf acceptConnection];
    });
    dispatch_resume(_acceptSource);
    _running = YES;

    NSLog(@"[PhoneClawAPI] HTTP API server started on port %d", port);
}

- (void)stop {
    if (!_running) return;
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    if (_serverSocket >= 0) {
        close(_serverSocket);
        _serverSocket = -1;
    }
    _running = NO;
    NSLog(@"[PhoneClawAPI] HTTP API server stopped");
}

#pragma mark - Connection Handling

- (void)acceptConnection {
    struct sockaddr_in6 clientAddr;
    socklen_t addrLen = sizeof(clientAddr);
    int clientSocket = accept(_serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
    if (clientSocket < 0) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self handleClient:clientSocket];
    });
}

- (void)handleClient:(int)sock {
    // Read request (max 64KB)
    char buf[65536];
    ssize_t n = recv(sock, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(sock); return; }
    buf[n] = '\0';

    NSString *request = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
    if (!request) { close(sock); return; }

    // Parse method and path
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) { close(sock); return; }

    NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
    if (parts.count < 2) { close(sock); return; }

    NSString *method = parts[0];
    NSString *path = parts[1];

    // Extract body (after \r\n\r\n)
    NSData *bodyData = nil;
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location != NSNotFound) {
        NSString *body = [request substringFromIndex:bodyRange.location + 4];
        bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    // CORS headers
    NSString *corsHeaders = @"Access-Control-Allow-Origin: *\r\n"
                            @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                            @"Access-Control-Allow-Headers: Content-Type\r\n";

    // Handle OPTIONS (CORS preflight)
    if ([method isEqualToString:@"OPTIONS"]) {
        NSString *resp = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n%@Content-Length: 0\r\n\r\n", corsHeaders];
        send(sock, resp.UTF8String, strlen(resp.UTF8String), 0);
        close(sock);
        return;
    }

    // Route request
    NSData *responseBody = nil;
    NSString *contentType = @"application/json";
    int statusCode = 200;

    if ([path isEqualToString:@"/api/status"] && [method isEqualToString:@"GET"]) {
        responseBody = [self handleStatus];
    }
    else if ([path isEqualToString:@"/api/screenshot"] && [method isEqualToString:@"GET"]) {
        responseBody = [self handleScreenshot];
        contentType = @"image/jpeg";
    }
    else if ([path isEqualToString:@"/api/tap"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleTap:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/swipe"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleSwipe:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/type"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleType:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/key"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleKey:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/doubletap"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleDoubleTap:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/launch"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleLaunch:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/clipboard"] && [method isEqualToString:@"GET"]) {
        responseBody = [self handleClipboardGet];
    }
    else if ([path isEqualToString:@"/api/clipboard"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleClipboardSet:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/save-to-photos"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleSaveToPhotos:parseJSON(bodyData)];
    }
    // --- Proxy Management ---
    else if ([path isEqualToString:@"/api/proxy/status"] && [method isEqualToString:@"GET"]) {
        responseBody = [self handleProxyStatus];
    }
    else if ([path isEqualToString:@"/api/proxy/config"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleProxyConfig:parseJSON(bodyData)];
    }
    else if ([path isEqualToString:@"/api/proxy/start"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleProxyStart];
    }
    else if ([path isEqualToString:@"/api/proxy/stop"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleProxyStop];
    }
    else if ([path isEqualToString:@"/api/proxy/spoof"] && [method isEqualToString:@"POST"]) {
        responseBody = [self handleProxySpoof:parseJSON(bodyData)];
    }
    else {
        statusCode = 404;
        responseBody = jsonResponse(@{@"error": @"Not found"});
    }

    if (!responseBody) {
        statusCode = 500;
        responseBody = jsonResponse(@{@"error": @"Internal error"});
    }

    // Send response
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n%@Content-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        statusCode, statusCode == 200 ? @"OK" : (statusCode == 404 ? @"Not Found" : @"Error"),
        corsHeaders, contentType, (unsigned long)responseBody.length
    ];

    send(sock, header.UTF8String, strlen(header.UTF8String), 0);
    send(sock, responseBody.bytes, responseBody.length, 0);
    close(sock);
}

#pragma mark - API Handlers

- (NSData *)handleStatus {
    UIDevice *dev = [UIDevice currentDevice];
    [dev setBatteryMonitoringEnabled:YES];

    // Check if sing-box process is still alive
    BOOL proxyAlive = [self isSingboxProcessAlive];
    if (_proxyRunning && !proxyAlive) {
        _proxyRunning = NO;
        _singboxPid = 0;
        _proxyStartTime = nil;
    }

    return jsonResponse(@{
        @"status": @"running",
        @"version": @PACKAGE_VERSION,
        @"device": dev.name ?: @"iPhone",
        @"model": dev.model ?: @"iPhone",
        @"systemVersion": dev.systemVersion ?: @"Unknown",
        @"battery": @((int)(dev.batteryLevel * 100)),
        @"screenWidth": @(self.screenWidth),
        @"screenHeight": @(self.screenHeight),
        @"proxyStatus": _proxyRunning ? @"running" : @"stopped",
    });
}

- (NSData *)handleScreenshot {
    return screenshotJPEG(0.7);
}

- (NSData *)handleTap:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    CGFloat x = [params[@"x"] doubleValue];
    CGFloat y = [params[@"y"] doubleValue];

    // Use VNC coordinate transform (same as Live VNC viewer)
    CGPoint point = normalizedToDevicePoint(x, y);

    // Reuse sendTaps (same as doubletap which works reliably)
    dispatch_async(dispatch_get_main_queue(), ^{
        [[STHIDEventGenerator sharedGenerator] sendTaps:1
                                               location:point
                                        numberOfTouches:1
                                       delayBetweenTaps:0.05];
    });
    // Small delay to let main queue pick up the block
    [NSThread sleepForTimeInterval:0.1];
    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleDoubleTap:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    CGFloat x = [params[@"x"] doubleValue];
    CGFloat y = [params[@"y"] doubleValue];
    CGFloat delay = [params[@"delay"] doubleValue];
    if (delay <= 0) delay = 0.05;

    // Use VNC coordinate transform (same as Live VNC viewer)
    CGPoint point = normalizedToDevicePoint(x, y);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Use sendTaps for precise control: 2 taps, 1 finger, custom delay
        [[STHIDEventGenerator sharedGenerator] sendTaps:2
                                               location:point
                                        numberOfTouches:1
                                       delayBetweenTaps:delay];
    });
    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleSwipe:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    CGFloat fromX = [params[@"fromX"] doubleValue];
    CGFloat fromY = [params[@"fromY"] doubleValue];
    CGFloat toX = [params[@"toX"] doubleValue];
    CGFloat toY = [params[@"toY"] doubleValue];
    CGFloat duration = [params[@"duration"] doubleValue];
    if (duration <= 0) duration = 0.3;

    // Use VNC coordinate transform (same as Live VNC viewer)
    CGPoint start = normalizedToDevicePoint(fromX, fromY);
    CGPoint end = normalizedToDevicePoint(toX, toY);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[STHIDEventGenerator sharedGenerator] dragLinearWithStartPoint:start endPoint:end duration:duration];
    });
    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleType:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    NSString *text = params[@"text"];
    if (!text) return jsonResponse(@{@"error": @"Missing text"});

    // Check if text is pure ASCII (fast path: keyPress works for ASCII)
    BOOL isASCII = YES;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (ch > 127) { isASCII = NO; break; }
    }

    if (isASCII) {
        // ASCII: type character by character like a real person
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            for (NSUInteger i = 0; i < text.length; i++) {
                NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [[STHIDEventGenerator sharedGenerator] keyPress:ch];
                });
                // Human-like typing: 150-300ms per character
                double delay = 0.15 + ((double)(arc4random_uniform(150)) / 1000.0);
                [NSThread sleepForTimeInterval:delay];
            }
        });
    } else {
        // Unicode (Vietnamese, emoji, etc): paste word by word
        // Split by spaces, paste each word then type space between
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *savedClipboard = [UIPasteboard generalPasteboard].string;
            NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];

            for (NSUInteger w = 0; w < words.count; w++) {
                NSString *word = words[w];
                if (word.length == 0) continue;

                // Paste the whole word via clipboard
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [UIPasteboard generalPasteboard].string = word;
                    [NSThread sleepForTimeInterval:0.05];
                    [[STHIDEventGenerator sharedGenerator] keyDown:@"command"];
                    [[STHIDEventGenerator sharedGenerator] keyPress:@"v"];
                    [[STHIDEventGenerator sharedGenerator] keyUp:@"command"];
                });

                // Pause after word (like thinking between words)
                double wordDelay = 0.3 + ((double)(arc4random_uniform(300)) / 1000.0);
                [NSThread sleepForTimeInterval:wordDelay];

                // Type space between words (not after last word)
                if (w < words.count - 1) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [[STHIDEventGenerator sharedGenerator] keyPress:@" "];
                    });
                    [NSThread sleepForTimeInterval:0.1];
                }
            }

            // Restore clipboard after done
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (savedClipboard) {
                    [UIPasteboard generalPasteboard].string = savedClipboard;
                }
            });
        });
    }

    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleKey:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    NSString *key = params[@"key"];
    if (!key) return jsonResponse(@{@"error": @"Missing key"});

    dispatch_async(dispatch_get_main_queue(), ^{
        STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
        if ([key isEqualToString:@"home"]) {
            [gen menuPress];
        } else if ([key isEqualToString:@"power"]) {
            [gen powerPress];
        } else if ([key isEqualToString:@"volumeUp"]) {
            [gen volumeIncrementPress];
        } else if ([key isEqualToString:@"volumeDown"]) {
            [gen volumeDecrementPress];
        } else if ([key isEqualToString:@"mute"]) {
            [gen mutePress];
        } else if ([key isEqualToString:@"screenshot"]) {
            [gen snapshotPress];
        } else if ([key isEqualToString:@"spotlight"]) {
            [gen toggleSpotlight];
        }
    });
    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleLaunch:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    NSString *bundleId = params[@"bundleId"];
    if (!bundleId) return jsonResponse(@{@"error": @"Missing bundleId"});

    __block int result = -1;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = SBSLaunchApplicationWithIdentifier((__bridge CFStringRef)bundleId, false);
    });

    if (result == 0) {
        return jsonResponse(@{@"ok": @YES, @"bundleId": bundleId});
    } else {
        CFStringRef errStr = SBSApplicationLaunchingErrorString(result);
        NSString *errMsg = errStr ? (__bridge NSString *)errStr : [NSString stringWithFormat:@"Launch failed (code: %d)", result];
        return jsonResponse(@{@"error": errMsg, @"code": @(result)});
    }
}

- (NSData *)handleClipboardGet {
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        text = [[ClipboardManager sharedManager] currentString];
    });
    return jsonResponse(@{@"text": text ?: @""});
}

- (NSData *)handleClipboardSet:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    NSString *text = params[@"text"];
    if (!text) return jsonResponse(@{@"error": @"Missing text"});

    dispatch_sync(dispatch_get_main_queue(), ^{
        [[ClipboardManager sharedManager] setString:text];
    });
    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleSaveToPhotos:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    NSString *urlString = params[@"url"];
    if (!urlString) return jsonResponse(@{@"error": @"Missing url"});

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return jsonResponse(@{@"error": @"Invalid url"});

    // Show silent persistent status on device (no sound, updates in place)
    [[BulletinManager sharedManager] updateSingleBannerWithContent:@"📥 Đang tải video..." badgeCount:1 userInfo:nil];

    // Start download + save in background (don't block HTTP server)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[PhoneClawAPI] Downloading video from: %@", urlString);

        // Step 1: Request Photos authorization
        dispatch_semaphore_t authSem = dispatch_semaphore_create(0);
        __block PHAuthorizationStatus authStatus = PHAuthorizationStatusNotDetermined;

        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            authStatus = status;
            dispatch_semaphore_signal(authSem);
        }];
        dispatch_semaphore_wait(authSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        if (authStatus != PHAuthorizationStatusAuthorized) {
            NSLog(@"[PhoneClawAPI] Photos authorization denied: %ld", (long)authStatus);
            [[BulletinManager sharedManager] updateSingleBannerWithContent:
                [NSString stringWithFormat:@"❌ Quyền Photos bị từ chối (status=%ld)", (long)authStatus]
                badgeCount:0 userInfo:nil];
            return;
        }

        // Step 2: Download video
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSURL *tempFileURL = nil;
        __block NSError *downloadError = nil;

        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
            downloadTaskWithURL:url
            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                if (error) {
                    downloadError = error;
                    NSLog(@"[PhoneClawAPI] Download error: %@", error.localizedDescription);
                } else if (location) {
                    NSString *ext = [[url pathExtension] length] > 0 ? [url pathExtension] : @"mp4";
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"phoneclaw_%@.%@",
                            [[NSUUID UUID] UUIDString], ext]];
                    tempFileURL = [NSURL fileURLWithPath:tempPath];
                    NSError *moveErr = nil;
                    [[NSFileManager defaultManager] moveItemAtURL:location toURL:tempFileURL error:&moveErr];
                    if (moveErr) {
                        NSLog(@"[PhoneClawAPI] Move error: %@", moveErr.localizedDescription);
                        tempFileURL = nil;
                    } else {
                        NSLog(@"[PhoneClawAPI] Downloaded to: %@", tempPath);
                    }
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_SEC)); // 20 min for large videos

        if (!tempFileURL) {
            NSString *errMsg = downloadError ? downloadError.localizedDescription : @"Download timeout";
            NSLog(@"[PhoneClawAPI] Download failed: %@", errMsg);
            [[BulletinManager sharedManager] updateSingleBannerWithContent:
                [NSString stringWithFormat:@"❌ Tải video thất bại: %@", errMsg]
                badgeCount:0 userInfo:nil];
            return;
        }

        [[BulletinManager sharedManager] updateSingleBannerWithContent:@"💾 Đã tải xong, đang lưu vào Photos..." badgeCount:1 userInfo:nil];

        // Step 3: Save to Photos library
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetCreationRequest creationRequestForAssetFromVideoAtFileURL:tempFileURL];
        } completionHandler:^(BOOL success, NSError *error) {
            [[NSFileManager defaultManager] removeItemAtURL:tempFileURL error:nil];
            if (success) {
                NSLog(@"[PhoneClawAPI] Video saved to Photos successfully");
                [[BulletinManager sharedManager] updateSingleBannerWithContent:@"✅ Video đã lưu vào Photos!" badgeCount:0 userInfo:nil];
            } else {
                NSLog(@"[PhoneClawAPI] Save to Photos failed: %@", error.localizedDescription);
                [[BulletinManager sharedManager] updateSingleBannerWithContent:
                    [NSString stringWithFormat:@"❌ Lưu Photos thất bại: %@", error.localizedDescription]
                    badgeCount:0 userInfo:nil];
            }
        }];
    });

    // Return immediately — download happens in background
    return jsonResponse(@{@"ok": @YES, @"message": @"Download started, saving to Photos..."});
}

#pragma mark - Proxy Management

- (NSString *)singboxBinaryPath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"sing-box"];
}

- (NSString *)singboxConfigPath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"singbox-config.json"];
}

- (BOOL)isSingboxProcessAlive {
    if (_singboxPid <= 0) return NO;
    return (kill(_singboxPid, 0) == 0);
}

// Local sing-box proxy port — apps connect to this, sing-box forwards to remote proxy
static const int kLocalProxyPort = 19080;

- (void)writeSingboxConfig {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *ip   = [defaults stringForKey:kProxyIP] ?: @"";
    int port       = (int)[defaults integerForKey:kProxyPort];
    NSString *user = [defaults stringForKey:kProxyUser] ?: @"";
    NSString *pass = [defaults stringForKey:kProxyPass] ?: @"";

    // Use "mixed" inbound (HTTP+SOCKS5 local proxy) instead of TUN.
    // TUN requires root/jailbreak which TrollStore doesn't provide.
    // After sing-box starts, we set iOS WiFi proxy to 127.0.0.1:kLocalProxyPort.
    NSDictionary *config = @{
        @"log": @{@"level": @"info", @"timestamp": @YES},
        @"inbounds": @[@{
            @"type": @"mixed",
            @"tag": @"mixed-in",
            @"listen": @"127.0.0.1",
            @"listen_port": @(kLocalProxyPort),
        }],
        @"outbounds": @[
            @{
                @"type": @"http",
                @"tag": @"us-proxy",
                @"server": ip,
                @"server_port": @(port),
                @"username": user,
                @"password": pass,
            },
            @{@"type": @"direct", @"tag": @"direct"},
        ],
        @"route": @{
            @"rules": @[
                @{@"ip_cidr": @[@"100.64.0.0/10", @"10.0.0.0/8", @"192.168.0.0/16", @"172.16.0.0/12"], @"outbound": @"direct"},
            ],
            @"final": @"us-proxy",
        },
    };

    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self singboxConfigPath] atomically:YES];
    NSLog(@"[PhoneClawAPI] sing-box config written to %@", [self singboxConfigPath]);
}

// Set iOS WiFi proxy to route traffic through local sing-box
- (void)enableSystemProxy {
    NSDictionary *proxySettings = @{
        (NSString *)kCFNetworkProxiesHTTPEnable: @YES,
        (NSString *)kCFNetworkProxiesHTTPProxy: @"127.0.0.1",
        (NSString *)kCFNetworkProxiesHTTPPort: @(kLocalProxyPort),
        (NSString *)kCFNetworkProxiesHTTPSEnable: @YES,
        (NSString *)kCFNetworkProxiesHTTPSProxy: @"127.0.0.1",
        (NSString *)kCFNetworkProxiesHTTPSPort: @(kLocalProxyPort),
    };

    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("PhoneAgent"), NULL, NULL);
    if (store) {
        // Set global proxy for the current network
        SCDynamicStoreSetValue(store, CFSTR("State:/Network/Global/Proxies"), (__bridge CFDictionaryRef)proxySettings);
        CFRelease(store);
        NSLog(@"[PhoneClawAPI] System proxy set to 127.0.0.1:%d", kLocalProxyPort);
    } else {
        NSLog(@"[PhoneClawAPI] Failed to create SCDynamicStore for proxy settings");
    }
}

// Remove iOS WiFi proxy — restore direct connection
- (void)disableSystemProxy {
    NSDictionary *proxySettings = @{
        (NSString *)kCFNetworkProxiesHTTPEnable: @NO,
        (NSString *)kCFNetworkProxiesHTTPSEnable: @NO,
    };

    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("PhoneAgent"), NULL, NULL);
    if (store) {
        SCDynamicStoreSetValue(store, CFSTR("State:/Network/Global/Proxies"), (__bridge CFDictionaryRef)proxySettings);
        CFRelease(store);
        NSLog(@"[PhoneClawAPI] System proxy disabled");
    }
}

- (NSData *)handleProxyStatus {
    BOOL alive = [self isSingboxProcessAlive];
    if (_proxyRunning && !alive) {
        _proxyRunning = NO;
        _singboxPid = 0;
        _proxyStartTime = nil;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *mode = [defaults stringForKey:kProxyMode] ?: @"none";
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"proxyStatus": _proxyRunning ? @"running" : @"stopped",
        @"pid": @(_singboxPid),
        @"mode": mode,
    }];

    if (_proxyRunning && _proxyStartTime) {
        result[@"uptime"] = @((int)[[NSDate date] timeIntervalSinceDate:_proxyStartTime]);
    }

    // Include current config (without password)
    NSString *ip = [defaults stringForKey:kProxyIP];
    if (ip.length > 0) {
        result[@"config"] = @{
            @"ip": ip ?: @"",
            @"port": @([defaults integerForKey:kProxyPort]),
            @"username": [defaults stringForKey:kProxyUser] ?: @"",
            @"hasPassword": @([[defaults stringForKey:kProxyPass] length] > 0),
        };
    }

    // Include spoof settings
    NSString *tz = [defaults stringForKey:kSpoofTimezone];
    NSString *locale = [defaults stringForKey:kSpoofLocale];
    double lat = [defaults doubleForKey:kSpoofLat];
    double lon = [defaults doubleForKey:kSpoofLon];

    DeviceSpoofer *spoofer = [DeviceSpoofer sharedSpoofer];
    NSMutableDictionary *spoof = [NSMutableDictionary dictionary];
    if (tz) spoof[@"timezone"] = tz;
    if (locale) spoof[@"locale"] = locale;
    if (lat != 0 || lon != 0) {
        spoof[@"latitude"] = @(lat);
        spoof[@"longitude"] = @(lon);
    }
    spoof[@"gpsActive"] = @(spoofer.locationSpoofActive);
    spoof[@"wifiActive"] = @(spoofer.wifiSpoofActive);
    spoof[@"cellularActive"] = @(spoofer.cellularSpoofActive);
    result[@"spoof"] = spoof;

    return jsonResponse(result);
}

- (NSData *)handleProxyConfig:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});

    NSString *ip   = params[@"ip"];
    NSNumber *port = params[@"port"];
    NSString *user = params[@"username"];
    NSString *pass = params[@"password"];
    NSString *mode = params[@"mode"]; // "us", "vn", "none"

    if (!ip || !port) return jsonResponse(@{@"error": @"Missing ip or port"});

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:ip forKey:kProxyIP];
    [defaults setInteger:[port integerValue] forKey:kProxyPort];
    if (user) [defaults setObject:user forKey:kProxyUser];
    if (pass) [defaults setObject:pass forKey:kProxyPass];
    if (mode) [defaults setObject:mode forKey:kProxyMode];
    [defaults synchronize];

    [self writeSingboxConfig];

    NSLog(@"[PhoneClawAPI] Proxy config saved: %@:%@ mode=%@", ip, port, mode ?: @"none");

    [[BulletinManager sharedManager] updateSingleBannerWithContent:
        [NSString stringWithFormat:@"⚙️ Proxy config: %@:%@ (%@)", ip, port, mode ?: @"none"]
        badgeCount:0 userInfo:nil];

    return jsonResponse(@{@"ok": @YES, @"message": @"Proxy config saved", @"mode": mode ?: @"none"});
}

- (NSData *)handleProxyStart {
    if (_proxyRunning && [self isSingboxProcessAlive]) {
        [[BulletinManager sharedManager] updateSingleBannerWithContent:
            [NSString stringWithFormat:@"🛡️ Proxy đang chạy (PID %d)", _singboxPid]
            badgeCount:0 userInfo:nil];
        return jsonResponse(@{@"ok": @YES, @"message": @"Proxy already running", @"pid": @(_singboxPid)});
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *ip = [defaults stringForKey:kProxyIP];
    if (!ip || ip.length == 0) {
        [[BulletinManager sharedManager] popBannerWithContent:@"❌ Chưa có proxy config" userInfo:nil];
        return jsonResponse(@{@"error": @"No proxy config. Call /api/proxy/config first"});
    }

    // Write fresh config
    [self writeSingboxConfig];

    NSString *binaryPath = [self singboxBinaryPath];
    NSString *configPath = [self singboxConfigPath];

    // Check binary exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
        NSLog(@"[PhoneClawAPI] sing-box binary not found at %@", binaryPath);
        [[BulletinManager sharedManager] popBannerWithContent:@"❌ sing-box binary không tìm thấy" userInfo:nil];
        return jsonResponse(@{@"error": @"sing-box binary not found in app bundle"});
    }

    [[BulletinManager sharedManager] updateSingleBannerWithContent:@"⏳ Đang khởi động proxy..." badgeCount:1 userInfo:nil];

    // Spawn sing-box process
    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        const char *args[] = {
            [binaryPath UTF8String],
            "run",
            "-c", [configPath UTF8String],
            NULL
        };
        execv(args[0], (char *const *)args);
        _exit(1); // exec failed
    } else if (pid > 0) {
        _singboxPid = pid;
        _proxyRunning = YES;
        _proxyStartTime = [NSDate date];
        [defaults setBool:YES forKey:kProxyEnabled];
        [defaults synchronize];

        NSLog(@"[PhoneClawAPI] sing-box started with PID %d, verifying...", pid);

        // Monitor process in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            int status;
            waitpid(pid, &status, 0);
            NSLog(@"[PhoneClawAPI] sing-box process %d exited with status %d", pid, status);
            if (self->_singboxPid == pid) {
                self->_proxyRunning = NO;
                self->_singboxPid = 0;
                self->_proxyStartTime = nil;
                // Notify user that proxy died unexpectedly
                [[BulletinManager sharedManager] popBannerWithContent:
                    [NSString stringWithFormat:@"❌ Proxy đã dừng đột ngột (exit code %d)", WEXITSTATUS(status)]
                    userInfo:nil];
            }
        });

        // Wait briefly to verify sing-box didn't crash immediately
        usleep(1500000); // 1.5 seconds

        if (![self isSingboxProcessAlive]) {
            _proxyRunning = NO;
            _singboxPid = 0;
            _proxyStartTime = nil;
            [defaults setBool:NO forKey:kProxyEnabled];
            [defaults synchronize];
            NSLog(@"[PhoneClawAPI] sing-box crashed immediately after start");
            [[BulletinManager sharedManager] popBannerWithContent:
                @"❌ Proxy không thể khởi động (sing-box crashed)" userInfo:nil];
            return jsonResponse(@{@"ok": @NO, @"error": @"sing-box crashed immediately after start — check config or permissions"});
        }

        // Enable system proxy to route traffic through local sing-box
        [self enableSystemProxy];

        NSString *proxyInfo = [NSString stringWithFormat:@"🛡️ Proxy đã bật — %@:%ld (PID %d)",
            ip, (long)[defaults integerForKey:kProxyPort], pid];
        [[BulletinManager sharedManager] popBannerWithContent:proxyInfo userInfo:nil];

        return jsonResponse(@{@"ok": @YES, @"pid": @(pid), @"message": @"Proxy started and system proxy enabled"});
    } else {
        NSLog(@"[PhoneClawAPI] Failed to fork sing-box process");
        [[BulletinManager sharedManager] popBannerWithContent:@"❌ Không thể khởi động proxy (fork failed)" userInfo:nil];
        return jsonResponse(@{@"error": @"Failed to start sing-box (fork failed)"});
    }
}

- (NSData *)handleProxyStop {
    if (!_proxyRunning || _singboxPid <= 0) {
        _proxyRunning = NO;
        _singboxPid = 0;
        _proxyStartTime = nil;
        [[BulletinManager sharedManager] updateSingleBannerWithContent:@"🛑 Proxy đã tắt" badgeCount:0 userInfo:nil];
        return jsonResponse(@{@"ok": @YES, @"message": @"Proxy not running"});
    }

    // Send SIGTERM first, then SIGKILL if needed
    kill(_singboxPid, SIGTERM);
    NSLog(@"[PhoneClawAPI] Sent SIGTERM to sing-box PID %d", _singboxPid);

    // Wait briefly for graceful shutdown
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self->_singboxPid > 0 && kill(self->_singboxPid, 0) == 0) {
            kill(self->_singboxPid, SIGKILL);
            NSLog(@"[PhoneClawAPI] Sent SIGKILL to sing-box PID %d", self->_singboxPid);
        }
    });

    pid_t stoppedPid = _singboxPid;
    _proxyRunning = NO;
    _singboxPid = 0;
    _proxyStartTime = nil;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:NO forKey:kProxyEnabled];
    [defaults synchronize];

    // Disable system proxy
    [self disableSystemProxy];

    // Disable ALL spoofing when proxy stops — restore natural device state
    [[DeviceSpoofer sharedSpoofer] stopAllSpoofing];
    NSLog(@"[PhoneClawAPI] All spoofing disabled (proxy stopped)");

    [[BulletinManager sharedManager] popBannerWithContent:@"🛑 Proxy đã tắt, spoof đã reset" userInfo:nil];

    return jsonResponse(@{@"ok": @YES, @"message": @"Proxy stopped, spoofing disabled", @"pid": @(stoppedPid)});
}

- (NSData *)handleProxySpoof:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *mode = params[@"mode"] ?: [defaults stringForKey:kProxyMode] ?: @"none";
    NSMutableArray *applied = [NSMutableArray array];

    // Mode "none" or "vn" → disable all spoofing, restore natural state
    if ([mode isEqualToString:@"none"] || [mode isEqualToString:@"vn"]) {
        [[DeviceSpoofer sharedSpoofer] stopAllSpoofing];
        [applied addObject:[NSString stringWithFormat:@"mode=%@ (all spoofing disabled)", mode]];
        NSLog(@"[PhoneClawAPI] Mode=%@ — all spoofing disabled (natural device state)", mode);
        [[BulletinManager sharedManager] updateSingleBannerWithContent:
            [NSString stringWithFormat:@"🔓 Spoof tắt (mode=%@)", mode] badgeCount:0 userInfo:nil];
        return jsonResponse(@{@"ok": @YES, @"applied": applied, @"mode": mode});
    }

    // Mode "us" → enable full US spoofing
    // Timezone
    NSString *timezone = params[@"timezone"];
    if (timezone.length > 0) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:timezone];
        if (tz) {
            [NSTimeZone setDefaultTimeZone:tz];
            [defaults setObject:timezone forKey:kSpoofTimezone];
            [applied addObject:[NSString stringWithFormat:@"timezone=%@", timezone]];
            NSLog(@"[PhoneClawAPI] Timezone spoofed to %@", timezone);
        }
    }

    // Locale
    NSString *locale = params[@"locale"];
    if (locale.length > 0) {
        NSString *prefsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"];
        NSMutableDictionary *globalPrefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath];
        if (!globalPrefs) globalPrefs = [NSMutableDictionary dictionary];
        globalPrefs[@"AppleLocale"] = locale;
        NSString *lang = [locale componentsSeparatedByString:@"_"].firstObject;
        if (lang) {
            globalPrefs[@"AppleLanguages"] = @[locale, lang];
        }
        [globalPrefs writeToFile:prefsPath atomically:YES];
        [defaults setObject:locale forKey:kSpoofLocale];
        [applied addObject:[NSString stringWithFormat:@"locale=%@", locale]];

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("kCFLocaleCurrentLocaleDidChangeNotification"),
            NULL, NULL, true
        );
    }

    // GPS
    NSNumber *lat = params[@"latitude"];
    NSNumber *lon = params[@"longitude"];
    if (lat && lon) {
        double latitude = [lat doubleValue];
        double longitude = [lon doubleValue];
        [defaults setDouble:latitude forKey:kSpoofLat];
        [defaults setDouble:longitude forKey:kSpoofLon];

        [[DeviceSpoofer sharedSpoofer] startLocationSpoofWithLatitude:latitude longitude:longitude];
        [applied addObject:[NSString stringWithFormat:@"gps=%.4f,%.4f", latitude, longitude]];
    }

    // WiFi BSSID — only hide when mode=us (VN WiFi would reveal location)
    [[DeviceSpoofer sharedSpoofer] startWiFiSpoof];
    [applied addObject:@"wifi_bssid=hidden"];

    // Cell Tower MCC/MNC — US values only when mode=us
    [[DeviceSpoofer sharedSpoofer] startCellularSpoof];
    [applied addObject:@"cellular=US(310/260)"];

    [defaults synchronize];

    [[BulletinManager sharedManager] popBannerWithContent:
        [NSString stringWithFormat:@"🇺🇸 US Spoof: %@ | GPS | WiFi ẩn | Cell US",
            params[@"timezone"] ?: @"auto"] userInfo:nil];

    return jsonResponse(@{@"ok": @YES, @"applied": applied, @"mode": @"us"});
}

- (void)autoStartProxy {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:kProxyEnabled]) return;

    NSString *ip = [defaults stringForKey:kProxyIP];
    if (!ip || ip.length == 0) return;

    NSString *mode = [defaults stringForKey:kProxyMode] ?: @"none";
    if ([mode isEqualToString:@"none"]) return; // No proxy mode → do nothing

    NSLog(@"[PhoneClawAPI] Auto-starting proxy (mode=%@)", mode);
    [self handleProxyStart];

    // Re-apply spoof settings based on mode
    NSMutableDictionary *spoofParams = [NSMutableDictionary dictionary];
    spoofParams[@"mode"] = mode;

    if ([mode isEqualToString:@"us"]) {
        NSString *tz = [defaults stringForKey:kSpoofTimezone];
        NSString *locale = [defaults stringForKey:kSpoofLocale];
        double lat = [defaults doubleForKey:kSpoofLat];
        double lon = [defaults doubleForKey:kSpoofLon];

        if (tz) spoofParams[@"timezone"] = tz;
        if (locale) spoofParams[@"locale"] = locale;
        if (lat != 0 || lon != 0) {
            spoofParams[@"latitude"] = @(lat);
            spoofParams[@"longitude"] = @(lon);
        }
    }
    // For "vn" mode, spoofParams only has mode="vn" → handleProxySpoof will disable all spoofing
    [self handleProxySpoof:spoofParams];
}

@end
