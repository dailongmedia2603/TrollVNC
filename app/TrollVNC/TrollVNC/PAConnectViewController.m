//
//  PAConnectViewController.m
//  TrollVNC — Phone Agent
//
//  Luồng ghép: sinh khoá WireGuard trên máy → gửi publicKey + mã ghép lên
//  {server}/api/wireguard/enroll → nhận IP tunnel + khoá server → lưu vào cấu
//  hình VPN (NETunnelProviderManager, On Demand luôn bật) → PacketTunnel
//  extension giữ kết nối. Server tự tạo thiết bị trên dashboard.
//

#import "PAConnectViewController.h"

#import <NetworkExtension/NetworkExtension.h>
#import <Security/Security.h>

#include <sys/utsname.h>

#include "PAX25519.h"

static NSString *const kPADefaultsSuite = @"com.phoneagent.connect";
static NSString *const kPADefaultServer = @"https://phoneagent.io.vn";
static NSString *const kPATrollVNCSuite = @"com.82flex.trollvnc";

#pragma mark - Helpers

static NSUserDefaults *PADefaults(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      d = [[NSUserDefaults alloc] initWithSuiteName:kPADefaultsSuite];
    });
    return d;
}

static NSString *PAExtensionBundleId(void) {
    return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".PacketTunnel"];
}

static NSString *PAMachine(void) {
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

static NSDictionary *PATrollVNCPrefs(void) {
    return [[[NSUserDefaults alloc] initWithSuiteName:kPATrollVNCSuite] dictionaryRepresentation] ?: @{};
}

static int PAPrefInt(NSDictionary *prefs, NSString *key, int fallback) {
    id v = prefs[key];
    int n = [v respondsToSelector:@selector(intValue)] ? [v intValue] : 0;
    return n > 0 ? n : fallback;
}

// API của Phone Agent daemon (PhoneClawAPI) chạy trên cổng HttpPort+1 hoặc ApiPort
static int PAApiPort(void) {
    NSDictionary *prefs = PATrollVNCPrefs();
    int api = PAPrefInt(prefs, @"ApiPort", 0);
    return api > 0 ? api : PAPrefInt(prefs, @"HttpPort", 8080) + 1;
}

static NSString *PANormalizeServer(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length) s = kPADefaultServer;
    if (![s hasPrefix:@"http://"] && ![s hasPrefix:@"https://"]) s = [@"https://" stringByAppendingString:s];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

static NSString *PANormalizeCode(NSString *raw) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
            [out appendFormat:@"%C", c];
    }
    return out.uppercaseString;
}

static BOOL PAGenerateKeyPair(NSString **privB64, NSString **pubB64) {
    uint8_t priv[32], pub[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(priv), priv) != errSecSuccess) return NO;
    pa_x25519_keypair(pub, priv);
    *privB64 = [[NSData dataWithBytes:priv length:32] base64EncodedStringWithOptions:0];
    *pubB64 = [[NSData dataWithBytes:pub length:32] base64EncodedStringWithOptions:0];
    memset(priv, 0, sizeof(priv));
    return YES;
}

static void PAPostJSON(NSString *url, NSDictionary *body, NSTimeInterval timeout,
                       void (^completion)(NSDictionary *json, NSString *error)) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        completion(nil, @"Địa chỉ server không hợp lệ");
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = timeout;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
                  NSDictionary *json = nil;
                  if (data.length) {
                      id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                      if ([j isKindOfClass:NSDictionary.class]) json = j;
                  }
                  NSString *err = nil;
                  if (error) err = error.localizedDescription;
                  else if (!json) err = [NSString stringWithFormat:@"Server trả lời không hợp lệ (HTTP %ld)",
                                                                   (long)((NSHTTPURLResponse *)resp).statusCode];
                  dispatch_async(dispatch_get_main_queue(), ^{
                    completion(json, err);
                  });
                  [session finishTasksAndInvalidate];
                }] resume];
}

// Báo cho daemon Phone Agent địa chỉ heartbeat (đi trong tunnel). Thử lại vài
// lần vì daemon/tunnel có thể chưa sẵn sàng ngay.
static void PAPushHeartbeatURL(NSString *heartbeatUrl, int attemptsLeft) {
    if (!heartbeatUrl.length) return;
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%d/api/heartbeat/config", PAApiPort()];
    PAPostJSON(url, @{@"url" : heartbeatUrl}, 5, ^(NSDictionary *json, NSString *error) {
      if ((!json || json[@"error"]) && attemptsLeft > 1) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            PAPushHeartbeatURL(heartbeatUrl, attemptsLeft - 1);
          });
      }
    });
}

static void PALoadManager(void (^completion)(NETunnelProviderManager *manager, NSError *error)) {
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray *managers, NSError *error) {
      NETunnelProviderManager *found = nil;
      for (NETunnelProviderManager *m in managers) {
          NETunnelProviderProtocol *p = (NETunnelProviderProtocol *)m.protocolConfiguration;
          if ([p isKindOfClass:NETunnelProviderProtocol.class] &&
              [p.providerBundleIdentifier isEqualToString:PAExtensionBundleId()]) {
              found = m;
              break;
          }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(found, error);
      });
    }];
}

static NSString *PAStatusText(NEVPNStatus st) {
    switch (st) {
    case NEVPNStatusConnected: return @"Đã kết nối";
    case NEVPNStatusConnecting: return @"Đang kết nối...";
    case NEVPNStatusReasserting: return @"Đang kết nối lại...";
    case NEVPNStatusDisconnecting: return @"Đang ngắt...";
    case NEVPNStatusDisconnected: return @"Đã ngắt";
    case NEVPNStatusInvalid: return @"Chưa cấu hình";
    }
    return @"?";
}

static NSString *PAFormatBytes(long long b) {
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleBinary];
}

#pragma mark - View controller

@implementation PAConnectViewController {
    UILabel *_statusLabel;
    UILabel *_detailLabel;
    UITextField *_serverField;
    UITextField *_codeField;
    UIButton *_connectButton;
    UIActivityIndicatorView *_spinner;
    UIStackView *_pairedActions;
    UIButton *_toggleButton;
    UITextView *_logView;
    NETunnelProviderManager *_manager;
    NSTimer *_timer;
    BOOL _busy;
}

+ (void)fetchStatusSummary:(void (^)(NSString *, BOOL))completion {
    PALoadManager(^(NETunnelProviderManager *m, NSError *error) {
      NSString *address = [PADefaults() stringForKey:@"address"];
      if (!m || !address) {
          completion(@"Chưa kết nối server — bấm để ghép mã", NO);
          return;
      }
      NEVPNStatus st = m.connection.status;
      completion([NSString stringWithFormat:@"%@ · %@", PAStatusText(st), address], st == NEVPNStatusConnected);
    });
}

+ (void)ensureConnectedOnLaunch {
    NSString *address = [PADefaults() stringForKey:@"address"];
    if (!address) return;
    PALoadManager(^(NETunnelProviderManager *m, NSError *error) {
      if (!m) return;
      NEVPNStatus st = m.connection.status;
      if (m.onDemandEnabled && (st == NEVPNStatusDisconnected || st == NEVPNStatusInvalid)) {
          [m.connection startVPNTunnelAndReturnError:nil];
      }
      if (m.onDemandEnabled) PAPushHeartbeatURL([PADefaults() stringForKey:@"heartbeatUrl"], 5);
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Kết nối Server";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIColor *tint = self.primaryColor ?: UIColor.systemBlueColor;
    self.view.tintColor = tint;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:g.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    // --- status card ---
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:13];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 0;
    [stack addArrangedSubview:[self cardWithViews:@[ _statusLabel, _detailLabel ]]];

    // --- pairing card ---
    UILabel *pairTitle = [self sectionLabel:@"GHÉP VỚI DASHBOARD"];
    _serverField = [self fieldWithPlaceholder:kPADefaultServer];
    _serverField.text = [PADefaults() stringForKey:@"server"] ?: kPADefaultServer;
    _serverField.keyboardType = UIKeyboardTypeURL;
    _codeField = [self fieldWithPlaceholder:@"Mã ghép (VD: K7M 2QX)"];
    _codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _codeField.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightSemibold];
    _codeField.textAlignment = NSTextAlignmentCenter;

    _connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_connectButton setTitle:@"Kết nối" forState:UIControlStateNormal];
    _connectButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _connectButton.backgroundColor = tint;
    [_connectButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _connectButton.layer.cornerRadius = 10;
    [_connectButton.heightAnchor constraintEqualToConstant:48].active = YES;
    [_connectButton addTarget:self action:@selector(connectTapped) forControlEvents:UIControlEventTouchUpInside];

    _spinner = [[UIActivityIndicatorView alloc] init];
    _spinner.activityIndicatorViewStyle = UIActivityIndicatorViewStyleMedium;
    _spinner.hidesWhenStopped = YES;

    UILabel *hint = [[UILabel alloc] init];
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"Trên dashboard: Quản lý Thiết bị → Thêm thiết bị → Tạo mã ghép, rồi nhập mã ở đây. "
                @"Lần đầu iOS sẽ hỏi “Thêm cấu hình VPN” → bấm Cho phép.";

    [stack addArrangedSubview:pairTitle];
    [stack addArrangedSubview:[self cardWithViews:@[ _serverField, _codeField, _connectButton, _spinner, hint ]]];

    // --- actions when paired ---
    _toggleButton = [self plainButton:@"Tạm ngắt" action:@selector(toggleTapped)];
    UIButton *unpair = [self plainButton:@"Huỷ ghép" action:@selector(unpairTapped)];
    [unpair setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    UIButton *logs = [self plainButton:@"Log tunnel" action:@selector(logsTapped)];
    _pairedActions = [[UIStackView alloc] initWithArrangedSubviews:@[ _toggleButton, logs, unpair ]];
    _pairedActions.axis = UILayoutConstraintAxisHorizontal;
    _pairedActions.distribution = UIStackViewDistributionFillEqually;
    _pairedActions.spacing = 8;
    [stack addArrangedSubview:_pairedActions];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.hidden = YES;
    _logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _logView.layer.cornerRadius = 10;
    [_logView.heightAnchor constraintEqualToConstant:260].active = YES;
    [stack addArrangedSubview:_logView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view
                                                                          action:@selector(endEditing:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh)
                                                 name:NEVPNStatusDidChangeNotification
                                               object:nil];
    [self reloadManager];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _timer = [NSTimer scheduledTimerWithTimeInterval:2
                                              target:self
                                            selector:@selector(refresh)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark UI builders

- (UIView *)cardWithViews:(NSArray<UIView *> *)views {
    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:views];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 10;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 12;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = UIColor.secondaryLabelColor;
    return l;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    [f.heightAnchor constraintEqualToConstant:44].active = YES;
    return f;
}

- (UIButton *)plainButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    b.layer.cornerRadius = 10;
    [b.heightAnchor constraintEqualToConstant:42].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    _connectButton.enabled = !busy;
    _connectButton.alpha = busy ? 0.5 : 1;
    busy ? [_spinner startAnimating] : [_spinner stopAnimating];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark State

- (void)reloadManager {
    PALoadManager(^(NETunnelProviderManager *m, NSError *error) {
      self->_manager = m;
      [self refresh];
    });
}

- (void)refresh {
    NSUserDefaults *d = PADefaults();
    NSString *address = [d stringForKey:@"address"];
    BOOL paired = _manager && address;
    _pairedActions.hidden = !paired;
    [_connectButton setTitle:paired ? @"Ghép lại bằng mã mới" : @"Kết nối" forState:UIControlStateNormal];

    if (!paired) {
        _statusLabel.text = @"⚪️ Chưa kết nối";
        _statusLabel.textColor = UIColor.labelColor;
        _detailLabel.text = @"Nhập mã ghép từ dashboard Phone Agent để kết nối máy này (không cần Tailscale).";
        return;
    }

    NEVPNStatus st = _manager.connection.status;
    BOOL on = st == NEVPNStatusConnected;
    _statusLabel.text = [NSString stringWithFormat:@"%@ %@", on ? @"🟢" : (st == NEVPNStatusConnecting || st == NEVPNStatusReasserting ? @"🟡" : @"🔴"), PAStatusText(st)];
    [_toggleButton setTitle:_manager.onDemandEnabled ? @"Tạm ngắt" : @"Bật lại" forState:UIControlStateNormal];

    NSMutableString *detail = [NSMutableString string];
    [detail appendFormat:@"Thiết bị: %@\nIP tunnel: %@\nServer: %@", [d stringForKey:@"deviceName"] ?: @"?", address,
                         [d stringForKey:@"server"] ?: kPADefaultServer];
    if (!_manager.onDemandEnabled) [detail appendString:@"\nĐang tạm ngắt — bấm “Bật lại” để kết nối."];
    _detailLabel.text = detail;

    if (on) {
        NETunnelProviderSession *session = (NETunnelProviderSession *)_manager.connection;
        [session sendProviderMessage:[@"status" dataUsingEncoding:NSUTF8StringEncoding]
                         returnError:nil
                     responseHandler:^(NSData *resp) {
                       NSDictionary *j = resp ? [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil] : nil;
                       dispatch_async(dispatch_get_main_queue(), ^{
                         [self showExtensionStatus:j base:detail];
                       });
                     }];
    }
}

- (void)showExtensionStatus:(NSDictionary *)j base:(NSString *)base {
    if (![j isKindOfClass:NSDictionary.class]) return;
    NSDictionary *stats = j[@"stats"];
    long long hs = [stats[@"handshake"] longLongValue];
    NSMutableString *detail = [base mutableCopy];
    if (hs > 0) {
        long long ago = (long long)[[NSDate date] timeIntervalSince1970] - hs;
        [detail appendFormat:@"\nHandshake: %llds trước · ↓ %@ ↑ %@", ago, PAFormatBytes([stats[@"rx"] longLongValue]),
                             PAFormatBytes([stats[@"tx"] longLongValue])];
        if (ago > 180) [detail appendString:@"\n⚠️ Lâu không có handshake — kiểm tra mạng / server"];
    } else {
        [detail appendString:@"\nĐang chờ handshake với server..."];
    }
    _detailLabel.text = detail;
    if (!_logView.hidden) {
        _logView.text = j[@"log"] ?: @"";
        if (_logView.text.length) [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length - 1, 1)];
    }
}

#pragma mark Actions

- (void)connectTapped {
    if (_busy) return;
    [self.view endEditing:YES];
    NSString *server = PANormalizeServer(_serverField.text);
    NSString *code = PANormalizeCode(_codeField.text ?: @"");
    if (code.length < 4) {
        [self alert:@"Thiếu mã ghép" message:@"Tạo mã trên dashboard: Quản lý Thiết bị → Thêm thiết bị."];
        return;
    }
    NSString *priv = nil, *pub = nil;
    if (!PAGenerateKeyPair(&priv, &pub)) {
        [self alert:@"Lỗi" message:@"Không tạo được khoá WireGuard"];
        return;
    }

    NSDictionary *prefs = PATrollVNCPrefs();
    NSMutableDictionary *body = [@{
        @"code" : code,
        @"publicKey" : pub,
        @"name" : UIDevice.currentDevice.name ?: @"iPhone",
        @"model" : PAMachine(),
        @"iosVersion" : UIDevice.currentDevice.systemVersion ?: @"",
        @"vncPort" : @(PAPrefInt(prefs, @"Port", 5901)),
        @"httpPort" : @(PAPrefInt(prefs, @"HttpPort", 8080)),
    } mutableCopy];
    if ([prefs[@"FullPassword"] isKindOfClass:NSString.class]) body[@"vncPassword"] = prefs[@"FullPassword"];

    [self setBusy:YES];
    PAPostJSON([server stringByAppendingString:@"/api/wireguard/enroll"], body, 20, ^(NSDictionary *json, NSString *error) {
      NSDictionary *data = json[@"data"];
      if (![json[@"success"] boolValue] || ![data isKindOfClass:NSDictionary.class]) {
          [self setBusy:NO];
          [self alert:@"Ghép thất bại" message:json[@"error"] ?: error ?: @"Không rõ lỗi"];
          return;
      }
      NSMutableDictionary *cfg = [data mutableCopy];
      cfg[@"privateKey"] = priv;
      cfg[@"server"] = server;
      [self installConfiguration:cfg server:server];
    });
}

- (void)installConfiguration:(NSDictionary *)cfg server:(NSString *)server {
    PALoadManager(^(NETunnelProviderManager *existing, NSError *loadError) {
      NETunnelProviderManager *m = existing ?: [[NETunnelProviderManager alloc] init];
      NETunnelProviderProtocol *p = [[NETunnelProviderProtocol alloc] init];
      p.providerBundleIdentifier = PAExtensionBundleId();
      p.serverAddress = [NSURL URLWithString:server].host ?: server;
      p.providerConfiguration = cfg;
      m.protocolConfiguration = p;
      m.localizedDescription = @"Phone Agent";
      m.enabled = YES;
      NEOnDemandRuleConnect *always = [[NEOnDemandRuleConnect alloc] init];
      always.interfaceTypeMatch = NEOnDemandRuleInterfaceTypeAny;
      m.onDemandRules = @[ always ];
      m.onDemandEnabled = YES;

      [m saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (saveError) {
              [self setBusy:NO];
              [self alert:@"Chưa lưu được cấu hình VPN"
                  message:[NSString stringWithFormat:@"%@\n\nHãy bấm Kết nối lại và chọn “Cho phép” khi iOS hỏi.",
                                                     saveError.localizedDescription]];
              return;
          }
          [m loadFromPreferencesWithCompletionHandler:^(NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [m.connection stopVPNTunnel]; // áp dụng cấu hình mới nếu đang chạy cấu hình cũ
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [m.connection startVPNTunnelAndReturnError:nil];
                NSUserDefaults *d = PADefaults();
                [d setObject:server forKey:@"server"];
                [d setObject:cfg[@"address"] forKey:@"address"];
                [d setObject:cfg[@"name"] ?: @"" forKey:@"deviceName"];
                [d setObject:cfg[@"deviceId"] ?: @"" forKey:@"deviceId"];
                [d setObject:cfg[@"heartbeatUrl"] ?: @"" forKey:@"heartbeatUrl"];
                self->_manager = m;
                self->_codeField.text = @"";
                [self setBusy:NO];
                [self refresh];
                PAPushHeartbeatURL(cfg[@"heartbeatUrl"], 10);
                [self alert:@"Đã ghép thành công"
                    message:[NSString stringWithFormat:@"Máy đã được thêm vào dashboard với tên “%@” (IP %@). "
                                                       @"Kết nối sẽ tự bật lại khi đổi mạng hoặc khởi động lại máy.",
                                                       cfg[@"name"] ?: @"", cfg[@"address"]]];
              });
            });
          }];
        });
      }];
    });
}

- (void)toggleTapped {
    if (!_manager) return;
    BOOL turnOn = !_manager.onDemandEnabled;
    _manager.onDemandEnabled = turnOn;
    _manager.enabled = YES;
    NETunnelProviderManager *m = _manager;
    [m saveToPreferencesWithCompletionHandler:^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (turnOn) {
            [m.connection startVPNTunnelAndReturnError:nil];
            PAPushHeartbeatURL([PADefaults() stringForKey:@"heartbeatUrl"], 10);
        } else {
            [m.connection stopVPNTunnel];
        }
        [self refresh];
      });
    }];
}

- (void)unpairTapped {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Huỷ ghép?"
                         message:@"Máy sẽ ngắt kết nối khỏi server và xoá cấu hình VPN. Hãy xoá thiết bị trên dashboard nếu không dùng nữa."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Không" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ ghép"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *action) {
                                          [self->_manager.connection stopVPNTunnel];
                                          [self->_manager removeFromPreferencesWithCompletionHandler:^(NSError *e) {
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                              for (NSString *k in @[ @"address", @"deviceName", @"deviceId", @"heartbeatUrl" ])
                                                  [PADefaults() removeObjectForKey:k];
                                              self->_manager = nil;
                                              [self refresh];
                                            });
                                          }];
                                        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)logsTapped {
    _logView.hidden = !_logView.hidden;
    [self refresh];
}

@end
