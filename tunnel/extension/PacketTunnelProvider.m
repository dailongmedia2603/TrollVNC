// Phone Agent PacketTunnel: WireGuard (wireguard-go) tới VPS, thay cho Tailscale.
//
// Cấu hình nằm trong providerConfiguration do app ghi sau khi ghép mã:
//   address, peerAddress, privateKey, serverPublicKey, endpoint ("host:port"),
//   dns[], mtu, keepalive, subnet, fullTunnel
//
// fullTunnel = YES: toàn bộ traffic đi qua VPS (exit node + sing-box), IPv6 bị
// chặn trong tunnel để không rò IP thật. NO: chỉ mạng 10.88.0.0/16.
#import <NetworkExtension/NetworkExtension.h>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

#include "libwg.h"

#pragma mark - utun fd (same approach as WireGuardKit)

struct pa_ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};
struct pa_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};
#define PA_CTLIOCGINFO _IOWR('N', 3, struct pa_ctl_info)

static int pa_find_utun_fd(void) {
    struct pa_ctl_info info;
    memset(&info, 0, sizeof(info));
    for (int fd = 0; fd <= 1024; fd++) {
        struct pa_sockaddr_ctl addr;
        socklen_t len = sizeof(addr);
        memset(&addr, 0, sizeof(addr));
        if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sc_family != AF_SYSTEM) continue;
        if (info.ctl_id == 0) {
            strncpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name) - 1);
            if (ioctl(fd, PA_CTLIOCGINFO, &info) != 0) continue;
        }
        if (addr.sc_id == info.ctl_id) return fd;
    }
    return -1;
}

static NSString *pa_resolve_ipv4(NSString *host) {
    struct in_addr a;
    if (inet_pton(AF_INET, host.UTF8String, &a) == 1) return host;
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) return nil;
    char buf[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, buf, sizeof(buf));
    freeaddrinfo(res);
    return [NSString stringWithUTF8String:buf];
}

static NSError *pa_error(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"PhoneAgentTunnel" code:code userInfo:@{NSLocalizedDescriptionKey : msg}];
}

#pragma mark -

@interface PacketTunnelProvider : NEPacketTunnelProvider
@end

@implementation PacketTunnelProvider {
    int _handle;
    BOOL _observing;
    NSMutableString *_log;
    NSString *_endpointIP;
}

- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[PhoneAgentTunnel] %@", s);
    @synchronized(self) {
        if (!_log) _log = [NSMutableString string];
        [_log appendFormat:@"%@\n", s];
        if (_log.length > 16384) [_log deleteCharactersInRange:NSMakeRange(0, _log.length - 8192)];
    }
}

- (void)startTunnelWithOptions:(NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *))completionHandler {
    _handle = -1;
    NSDictionary *cfg = ((NETunnelProviderProtocol *)self.protocolConfiguration).providerConfiguration ?: @{};
    NSString *address = cfg[@"address"];
    NSString *endpoint = cfg[@"endpoint"];
    if (!address.length || !endpoint.length || ![cfg[@"privateKey"] length] || ![cfg[@"serverPublicKey"] length]) {
        completionHandler(pa_error(1, @"Chưa ghép mã với server"));
        return;
    }

    NSRange colon = [endpoint rangeOfString:@":" options:NSBackwardsSearch];
    NSString *host = colon.location == NSNotFound ? endpoint : [endpoint substringToIndex:colon.location];
    NSString *port = colon.location == NSNotFound ? @"51830" : [endpoint substringFromIndex:colon.location + 1];
    NSString *endpointIP = pa_resolve_ipv4(host);
    if (!endpointIP) {
        [self log:@"không phân giải được %@", host];
        completionHandler(pa_error(2, [NSString stringWithFormat:@"Không phân giải được %@", host]));
        return;
    }
    _endpointIP = endpointIP;

    BOOL full = cfg[@"fullTunnel"] ? [cfg[@"fullTunnel"] boolValue] : YES;
    NSArray *dns = [cfg[@"dns"] isKindOfClass:NSArray.class] ? cfg[@"dns"] : @[ @"1.1.1.1", @"8.8.8.8" ];

    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:endpointIP];
    NEIPv4Settings *v4 = [[NEIPv4Settings alloc] initWithAddresses:@[ address ] subnetMasks:@[ @"255.255.255.255" ]];
    if (full) {
        v4.includedRoutes = @[ [NEIPv4Route defaultRoute] ];
        NEIPv6Settings *v6 = [[NEIPv6Settings alloc] initWithAddresses:@[ @"fd88::2" ] networkPrefixLengths:@[ @128 ]];
        v6.includedRoutes = @[ [NEIPv6Route defaultRoute] ];
        settings.IPv6Settings = v6;
        NEDNSSettings *d = [[NEDNSSettings alloc] initWithServers:dns];
        d.matchDomains = @[ @"" ];
        settings.DNSSettings = d;
    } else {
        v4.includedRoutes = @[ [[NEIPv4Route alloc] initWithDestinationAddress:@"10.88.0.0" subnetMask:@"255.255.0.0"] ];
    }
    settings.IPv4Settings = v4;
    settings.MTU = @([cfg[@"mtu"] intValue] ?: 1280);

    NSDictionary *wg = @{
        @"privateKey" : cfg[@"privateKey"],
        @"peerPublicKey" : cfg[@"serverPublicKey"],
        @"endpoint" : [NSString stringWithFormat:@"%@:%@", endpointIP, port],
        @"allowedIPs" : full ? @[ @"0.0.0.0/0", @"::/0" ] : @[ @"10.88.0.0/16" ],
        @"keepalive" : @([cfg[@"keepalive"] intValue] ?: 25),
    };
    NSString *wgJSON = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:wg options:0 error:nil]
                                             encoding:NSUTF8StringEncoding];

    [self log:@"start %@ → %@:%@ (%@)", address, endpointIP, port, full ? @"full tunnel" : @"split"];
    __weak typeof(self) weakSelf = self;
    [self setTunnelNetworkSettings:settings
                 completionHandler:^(NSError *error) {
                   typeof(self) s = weakSelf;
                   if (!s) return;
                   if (error) {
                       [s log:@"setTunnelNetworkSettings: %@", error];
                       completionHandler(error);
                       return;
                   }
                   int fd = pa_find_utun_fd();
                   if (fd < 0) {
                       completionHandler(pa_error(3, @"Không tìm thấy utun"));
                       return;
                   }
                   s->_handle = wgTurnOn((char *)wgJSON.UTF8String, fd, 0);
                   if (s->_handle < 0) {
                       [s log:@"wgTurnOn=%d", s->_handle];
                       completionHandler(pa_error(4, [NSString stringWithFormat:@"wgTurnOn=%d", s->_handle]));
                       return;
                   }
                   [s addObserver:s forKeyPath:@"defaultPath" options:NSKeyValueObservingOptionNew context:NULL];
                   s->_observing = YES;
                   completionHandler(nil);
                 }];
}

// Đổi mạng (Wi-Fi ↔ 4G): mở lại socket UDP để tunnel không bị treo
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"defaultPath"]) return;
    NWPath *path = self.defaultPath;
    if (_handle >= 0 && path.status == NWPathStatusSatisfied) {
        [self log:@"network path changed → rebind"];
        wgBumpSockets(_handle);
    }
}

- (void)wake {
    if (_handle >= 0) wgBumpSockets(_handle);
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    [self log:@"stop reason=%ld", (long)reason];
    if (_observing) {
        [self removeObserver:self forKeyPath:@"defaultPath"];
        _observing = NO;
    }
    if (_handle >= 0) {
        wgTurnOff(_handle);
        _handle = -1;
    }
    completionHandler();
}

// App hỏi trạng thái: trả về {stats:{handshake,rx,tx}, log}
- (void)handleAppMessage:(NSData *)messageData completionHandler:(void (^)(NSData *))completionHandler {
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    if (_handle >= 0) {
        char *st = wgGetStats(_handle);
        if (st) {
            id stats = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:st length:strlen(st)]
                                                       options:0
                                                         error:nil];
            if (stats) reply[@"stats"] = stats;
            free(st);
        }
    }
    char *wl = wgDrainLog();
    NSMutableString *log = [NSMutableString string];
    @synchronized(self) {
        if (_log) [log appendString:_log];
    }
    if (wl) {
        for (NSString *line in [[NSString stringWithUTF8String:wl] componentsSeparatedByString:@"\n"]) {
            if (line.length && ![line containsString:@"keepalive"]) [log appendFormat:@"%@\n", line];
        }
        free(wl);
    }
    @synchronized(self) {
        _log = [log mutableCopy];
        if (_log.length > 16384) [_log deleteCharactersInRange:NSMakeRange(0, _log.length - 8192)];
    }
    reply[@"log"] = log;
    if (_endpointIP) reply[@"endpointIP"] = _endpointIP;
    if (completionHandler) completionHandler([NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]);
}

@end
