//
//  PAConnectViewController.h
//  TrollVNC — Phone Agent
//
//  "Kết nối Server": ghép máy với dashboard Phone Agent bằng mã ghép, rồi giữ
//  kết nối WireGuard (PacketTunnel extension) luôn bật — thay cho Tailscale.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PAConnectViewController : UIViewController
@property(nonatomic, strong, nullable) UIColor *primaryColor;

// Mô tả ngắn trạng thái hiện tại (cho nút ở màn hình chính)
+ (void)fetchStatusSummary:(void (^)(NSString *summary, BOOL connected))completion;

// Gọi khi app mở: nếu đã ghép, đảm bảo VPN bật và daemon biết heartbeat URL
+ (void)ensureConnectedOnLaunch;
@end

NS_ASSUME_NONNULL_END
