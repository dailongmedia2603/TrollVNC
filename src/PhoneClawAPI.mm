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

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

// SpringBoardServices launch API (available with com.apple.springboard.launchapplications entitlement)
extern "C" int SBSLaunchApplicationWithIdentifier(CFStringRef identifier, Boolean suspended);
extern "C" CFStringRef SBSApplicationLaunchingErrorString(int error);

// Screen buffer access - provided by trollvncserver via setScreenBuffer
static void *sScreenBuffer = NULL;
static int sScreenWidth = 0;
static int sScreenHeight = 0;
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

@implementation PhoneClawAPI {
    int _serverSocket;
    dispatch_source_t _acceptSource;
    BOOL _running;
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
    return jsonResponse(@{
        @"status": @"running",
        @"version": @PACKAGE_VERSION,
        @"device": dev.name ?: @"iPhone",
        @"model": dev.model ?: @"iPhone",
        @"systemVersion": dev.systemVersion ?: @"Unknown",
        @"battery": @((int)(dev.batteryLevel * 100)),
        @"screenWidth": @(self.screenWidth),
        @"screenHeight": @(self.screenHeight),
    });
}

- (NSData *)handleScreenshot {
    return screenshotJPEG(0.7);
}

- (NSData *)handleTap:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    CGFloat x = [params[@"x"] doubleValue];
    CGFloat y = [params[@"y"] doubleValue];

    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGPoint point = CGPointMake(x * screen.width, y * screen.height);

    // Use sendTaps on main queue - must complete before response
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[STHIDEventGenerator sharedGenerator] sendTaps:1
                                               location:point
                                        numberOfTouches:1
                                       delayBetweenTaps:0.0];
        done = YES;
    });
    // Wait up to 2s for tap to complete
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (!done && [[NSDate date] compare:timeout] == NSOrderedAscending) {
        [NSThread sleepForTimeInterval:0.01];
    }
    return jsonResponse(@{@"ok": @(done)});
}

- (NSData *)handleDoubleTap:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    CGFloat x = [params[@"x"] doubleValue];
    CGFloat y = [params[@"y"] doubleValue];
    CGFloat delay = [params[@"delay"] doubleValue];
    if (delay <= 0) delay = 0.05;

    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGPoint point = CGPointMake(x * screen.width, y * screen.height);

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

    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGPoint start = CGPointMake(fromX * screen.width, fromY * screen.height);
    CGPoint end = CGPointMake(toX * screen.width, toY * screen.height);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[STHIDEventGenerator sharedGenerator] dragLinearWithStartPoint:start endPoint:end duration:duration];
    });
    return jsonResponse(@{@"ok": @YES});
}

- (NSData *)handleType:(NSDictionary *)params {
    if (!params) return jsonResponse(@{@"error": @"Missing body"});
    NSString *text = params[@"text"];
    if (!text) return jsonResponse(@{@"error": @"Missing text"});

    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSUInteger i = 0; i < text.length; i++) {
            NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
            [[STHIDEventGenerator sharedGenerator] keyPress:ch];
        }
    });
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

@end
