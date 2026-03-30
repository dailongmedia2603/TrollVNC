/*
 PacketTunnel Network Extension — Phone Agent
 Minimal NEPacketTunnelProvider that routes HTTP/HTTPS through local sing-box proxy.
 No Libbox/gomobile needed — just proxy settings + DNS + route exclusions.
*/

#import <NetworkExtension/NetworkExtension.h>
#import <Foundation/Foundation.h>

static const int kSingBoxPort = 19080;

@interface PacketTunnelProvider : NEPacketTunnelProvider
@end

@implementation PacketTunnelProvider

- (void)startTunnelWithOptions:(NSDictionary<NSString *,NSObject *> *)options
             completionHandler:(void (^)(NSError * _Nullable))completionHandler {

    NSLog(@"[PacketTunnel] Starting tunnel...");

    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"192.0.2.1"];

    // === IPv4: Claim all traffic, exclude Tailscale + LAN ===
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc]
        initWithAddresses:@[@"192.0.2.2"]
              subnetMasks:@[@"255.255.255.0"]];
    ipv4.includedRoutes = @[[NEIPv4Route defaultRoute]];
    ipv4.excludedRoutes = @[
        [[NEIPv4Route alloc] initWithDestinationAddress:@"100.64.0.0"  subnetMask:@"255.192.0.0"],   // Tailscale CGNAT
        [[NEIPv4Route alloc] initWithDestinationAddress:@"10.0.0.0"    subnetMask:@"255.0.0.0"],     // Private class A
        [[NEIPv4Route alloc] initWithDestinationAddress:@"172.16.0.0"  subnetMask:@"255.240.0.0"],   // Private class B
        [[NEIPv4Route alloc] initWithDestinationAddress:@"192.168.0.0" subnetMask:@"255.255.0.0"],   // Private class C
        [[NEIPv4Route alloc] initWithDestinationAddress:@"127.0.0.0"   subnetMask:@"255.0.0.0"],     // Loopback
        [[NEIPv4Route alloc] initWithDestinationAddress:@"169.254.0.0" subnetMask:@"255.255.0.0"],   // Link-local
    ];
    settings.IPv4Settings = ipv4;

    // === Proxy: Route HTTP/HTTPS through sing-box ===
    NEProxySettings *proxy = [[NEProxySettings alloc] init];
    proxy.HTTPEnabled = YES;
    proxy.HTTPServer = [[NEProxyServer alloc] initWithAddress:@"127.0.0.1" port:kSingBoxPort];
    proxy.HTTPSEnabled = YES;
    proxy.HTTPSServer = [[NEProxyServer alloc] initWithAddress:@"127.0.0.1" port:kSingBoxPort];
    proxy.matchDomains = @[@""];  // Match ALL domains
    proxy.excludeSimpleHostnames = YES;
    proxy.exceptionList = @[
        @"*.local",
        @"100.64.0.0/10",    // Tailscale
        @"10.0.0.0/8",
        @"172.16.0.0/12",
        @"192.168.0.0/16",
        @"127.0.0.1",
        @"localhost",
    ];
    settings.proxySettings = proxy;

    // === DNS: Prevent leak — use Cloudflare/Google DNS ===
    NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:@[@"1.1.1.1", @"8.8.8.8"]];
    dns.matchDomains = @[@""];  // Capture ALL DNS queries
    settings.DNSSettings = dns;

    // === MTU ===
    settings.MTU = @1500;

    // Apply settings
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"[PacketTunnel] Failed to set tunnel settings: %@", error);
            completionHandler(error);
            return;
        }

        NSLog(@"[PacketTunnel] Tunnel settings applied — proxy 127.0.0.1:%d", kSingBoxPort);

        // Read packets to keep extension alive (discard non-HTTP traffic)
        [self drainPackets];

        completionHandler(nil);
    }];
}

- (void)drainPackets {
    [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets,
                                                        NSArray<NSNumber *> *protocols) {
        // Non-HTTP packets arrive here — discard them.
        // HTTP/HTTPS is handled by NEProxySettings (never hits packetFlow).
        // Continue reading to prevent iOS from suspending the extension.
        [self drainPackets];
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    NSLog(@"[PacketTunnel] Stopping tunnel (reason=%ld)", (long)reason);
    completionHandler();
}

- (void)handleAppMessage:(NSData *)messageData
       completionHandler:(void (^)(NSData * _Nullable))completionHandler {
    NSString *command = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
    NSLog(@"[PacketTunnel] App message: %@", command);

    if ([command isEqualToString:@"status"]) {
        completionHandler([@"running" dataUsingEncoding:NSUTF8StringEncoding]);
    } else {
        completionHandler(nil);
    }
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler {
    NSLog(@"[PacketTunnel] Sleep");
    completionHandler();
}

- (void)wake {
    NSLog(@"[PacketTunnel] Wake — resuming packet drain");
    [self drainPackets];
}

@end
