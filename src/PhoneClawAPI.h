/*
 PhoneClaw HTTP API Server
 Lightweight HTTP REST API for programmatic device control.
 Runs alongside the VNC server on a configurable port (default 9090).

 Endpoints:
   GET  /api/status      — server info
   GET  /api/screenshot   — current screen as JPEG
   POST /api/tap          — {"x":0.5,"y":0.3}
   POST /api/swipe        — {"fromX":0.5,"fromY":0.8,"toX":0.5,"toY":0.2,"duration":0.3}
   POST /api/type         — {"text":"hello"}
   POST /api/key          — {"key":"home"}
   POST /api/launch       — {"bundleId":"com.app.id"}
   GET  /api/clipboard    — read clipboard
   POST /api/clipboard    — {"text":"..."}

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2.
*/

#ifndef PhoneClawAPI_h
#define PhoneClawAPI_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PhoneClawAPI : NSObject

+ (instancetype)sharedAPI;

/// Start the API server on the given port. Call from main thread.
- (void)startOnPort:(uint16_t)port;

/// Stop the API server.
- (void)stop;

/// Current screen dimensions (set by VNC server)
@property (nonatomic) int screenWidth;
@property (nonatomic) int screenHeight;

@end

NS_ASSUME_NONNULL_END

#endif /* PhoneClawAPI_h */
