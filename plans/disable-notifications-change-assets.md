# Plan: Tắt Notification + Thay App Icon + Thay HavocMarketing

**Ngay:** 2026-03-28
**Muc tieu:** 3 thay doi an toan, khong lam hong bat ky tinh nang nao

---

## Phan tich ket qua nghien cuu

### 1. He thong Notification hien tai

**Luong hoat dong:**
- Client connect -> `newClientHook()` (line 4056) -> `tvPublishClientConnectedNotif()` (line 3926)
- Client disconnect -> `clientGoneHook()` (line 3982) -> `tvPublishClientDisconnectedNotif()` (line 3953)
- Active client count -> `tvPublishUserSingleNotifs()` (line 3897)

**Co che kiem soat da ton tai:**
- `gUserClientNotifsEnabled` (line 134, default: YES) - kiem soat thong bao connect/disconnect
- `gUserSingleNotifsEnabled` (line 135, default: YES) - kiem soat thong bao so luong client
- Load tu preferences: `ClientNotifsEnabled` va `SingleNotifEnabled` (lines 664-669)
- Da co UI toggle trong Settings (Root.plist, lines 176-208)

**Nhan xet:** He thong da co san co che bat/tat. Chi can thay doi **gia tri mac dinh** tu YES -> NO la du.

### 2. App Icon

**Vi tri hien tai:** `app/TrollVNC/TrollVNC/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024x1024)
**File moi:** `Artworks/app-icon-new.png` (1024x1024, 270KB)
**Cau hinh:** `Contents.json` tro den `AppIcon.png` (idiom: universal, platform: ios)
**Build settings:** `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` (project.pbxproj)

**Nhan xet:** Chi can copy file moi ghi de len file cu, giu nguyen ten `AppIcon.png`. Khong can thay doi Contents.json hay project settings.

### 3. HavocMarketing

**Vi tri:** `Artworks/HavocMarketing.png` (23KB)
**File moi:** `Artworks/HavocMarketing-new.png` (28KB, 240x240)
**Tham chieu trong code:** KHONG CO. File nay chi ton tai trong thu muc Artworks, khong duoc reference boi bat ky file code, plist, storyboard nao.

**Nhan xet:** Day la marketing image dung ben ngoai (Havoc store listing). Chi can ghi de file.

---

## Ke hoach trien khai

### Buoc 1: Tat notification mac dinh (THAY DOI NHO, AN TOAN)

**File:** `src/trollvncserver.mm`

**Thay doi 1a:** Line 134
```diff
- static BOOL gUserClientNotifsEnabled = YES;
+ static BOOL gUserClientNotifsEnabled = NO;
```

**Thay doi 1b:** Line 135
```diff
- static BOOL gUserSingleNotifsEnabled = YES;
+ static BOOL gUserSingleNotifsEnabled = NO;
```

**Thay doi 1c:** `prefs/TrollVNCPrefs/Resources/Root.plist` - lines 194-196 va 206-207
```diff
  <!-- SingleNotifEnabled default -->
- <true/>
+ <false/>

  <!-- ClientNotifsEnabled default -->
- <true/>
+ <false/>
```

**Tai sao an toan:**
- Co che bat/tat da co san va da duoc kiem chung
- Chi thay doi GIA TRI MAC DINH, khong thay doi LOGIC
- Nguoi dung van co the bat lai notification trong Settings bat ky luc nao
- Khong anh huong den: connection handling, screen capture, clipboard, input, VNC protocol
- Khong xoa code, khong thay doi flow

### Buoc 2: Thay App Icon (THAY DOI FILE, AN TOAN)

**Lenh:**
```bash
cp Artworks/app-icon-new.png app/TrollVNC/TrollVNC/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

**Tai sao an toan:**
- Chi thay the noi dung file hinh anh, giu nguyen ten file
- Contents.json khong can thay doi (van tro den `AppIcon.png`)
- Build settings khong can thay doi
- Kich thuoc 1024x1024 dung yeu cau cua Apple

### Buoc 3: Thay HavocMarketing (THAY DOI FILE, AN TOAN)

**Lenh:**
```bash
cp Artworks/HavocMarketing-new.png Artworks/HavocMarketing.png
```

**Tai sao an toan:**
- File nay KHONG duoc reference trong bat ky file code nao
- Chi la marketing asset luu tru trong thu muc Artworks
- Khong anh huong den build, runtime, hay bat ky tinh nang nao

---

## Danh gia rui ro

| Thay doi | Rui ro | Giai phap |
|----------|--------|-----------|
| Tat notification default | Cuc thap - chi thay doi gia tri mac dinh | Nguoi dung co the bat lai trong Settings |
| Thay app icon | Cuc thap - chi thay the file hinh anh | Backup file cu truoc khi ghi de |
| Thay HavocMarketing | Khong co rui ro | File khong duoc reference trong code |

## Cac tinh nang KHONG bi anh huong

- VNC server/connection handling
- Screen capture & streaming
- Input handling (touch, keyboard, mouse)
- Clipboard sync
- SSL/TLS
- HTTP/WebSocket web client
- PhoneClaw REST API
- Bonjour discovery
- Reverse connection/repeater
- Keep-alive
- Orientation sync
- Settings UI (van hoat dong, chi thay doi default)

---

## Tong ket

- **3 thay doi**: 2 dong code + 2 dong plist + 2 file copy
- **Thoi gian:** ~2 phut
- **Rui ro:** Cuc thap
- **Rollback:** Doi lai YES/true hoac restore file tu git
