#!/bin/bash
# use-apple — a single file that lets agents drive Apple devices. It builds the embedded XCUITest server (Objective-C
# below) into a runner without an Xcode project and runs it on a simulator or the USB-connected device.
# Needs only Xcode: devices are listed and forwarded through macOS's own usbmuxd.
#
#   ./use-apple.sh [udid] [port]   udid defaults to the only USB device
#
# Device signing is discovered from the installed provisioning profiles (wildcard or matching WDA_BUNDLE_ID) that list
# the device and whose certificate is in the keychain. Override with WDA_SIGN_IDENTITY and WDA_PROFILE.
set -euo pipefail

PY=$(cat <<'EOF'
import datetime, glob, hashlib, os, plistlib, socket, struct, subprocess, sys, threading

def mux(msg):
    s = socket.socket(socket.AF_UNIX)
    s.connect('/var/run/usbmuxd')
    body = plistlib.dumps(dict(msg, ClientVersionString='wdalite', ProgName='wdalite'))
    s.sendall(struct.pack('<4I', 16 + len(body), 1, 8, 1) + body)
    data = b''
    while len(data) < 16 or len(data) < struct.unpack('<I', data[:4])[0]:
        chunk = s.recv(65536)
        assert chunk, 'usbmuxd closed the connection'
        data += chunk
    return s, plistlib.loads(data[16:])

def devices():
    s, r = mux({'MessageType': 'ListDevices'})
    s.close()
    return [d['Properties'] for d in r['DeviceList'] if d['Properties'].get('ConnectionType') == 'USB']

def udid(p):
    n = p['SerialNumber']
    return n[:8] + '-' + n[8:] if len(n) == 24 and '-' not in n else n

cmd = sys.argv[1]
if cmd == 'list':
    print('\n'.join(sorted({udid(p) for p in devices()})))
elif cmd == 'sign':
    target, bundle = sys.argv[2], sys.argv[3]
    ids = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout
    for f in glob.glob(os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision')) + \
             glob.glob(os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision')):
        p = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', f], capture_output=True).stdout)
        if target not in p.get('ProvisionedDevices', []) or p['ExpirationDate'] < datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) or \
           p['Entitlements']['application-identifier'].split('.', 1)[1] not in ('*', bundle):
            continue
        for c in p['DeveloperCertificates']:
            h = hashlib.sha1(c).hexdigest().upper()
            if h in ids:
                print(h)
                print(f)
                sys.exit()
    sys.exit('No valid provisioning profile covers %s with a keychain certificate' % target)
elif cmd == 'forward':
    target, port = sys.argv[2], int(sys.argv[3])
    device = next(p['DeviceID'] for p in devices() if udid(p) == target)
    server = socket.create_server(('127.0.0.1', port))

    def pipe(a, b):
        try:
            while data := a.recv(65536):
                b.sendall(data)
        except OSError:
            pass
        for x in (a, b):
            try:
                x.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def handle(c):
        s, r = mux({'MessageType': 'Connect', 'DeviceID': device, 'PortNumber': socket.htons(port)})
        if r.get('Number'):
            return c.close(), s.close()
        threading.Thread(target=pipe, args=(c, s), daemon=True).start()
        pipe(s, c)

    while True:
        threading.Thread(target=handle, args=(server.accept()[0],), daemon=True).start()
EOF
)

if [[ -z ${1:-} ]]; then
  DEVICES=($(python3 -I -c "$PY" list))
  (( ${#DEVICES[@]} == 1 )) || { echo "usage: use-apple.sh [udid] [port]; USB devices: ${DEVICES[*]:-none}" >&2; exit 1; }
fi
UDID=${1:-${DEVICES[0]:-}}
PORT=${2:-8100}
BUNDLE_ID=${WDA_BUNDLE_ID:-com.example.useapple}
OUT=${TMPDIR:-/tmp}/wdalite-$UDID

if xcrun simctl list devices | grep -q "$UDID"; then
  SDK=iphonesimulator TARGET=$(uname -m)-apple-ios17.0-simulator
  xcrun simctl boot "$UDID" 2>/dev/null || true
else
  SDK=iphoneos TARGET=arm64-apple-ios17.0
  if [[ -z ${WDA_SIGN_IDENTITY:-} || -z ${WDA_PROFILE:-} ]]; then
    SIGNING=$(python3 -I -c "$PY" sign "$UDID" "$BUNDLE_ID")
    WDA_SIGN_IDENTITY=$(sed -n 1p <<<"$SIGNING") WDA_PROFILE=$(sed -n 2p <<<"$SIGNING")
  fi
fi
PLAT=$(xcrun --sdk $SDK --show-sdk-platform-path)/Developer
APP=$OUT/WDALite-Runner.app
XCT=$APP/PlugIns/WDALite.xctest

rm -rf "$OUT" && mkdir -p "$OUT"
cat > "$OUT/WDALite.m" <<'OBJC'
// WDALite — a single-file XCUITest automation server.
// HTTP/JSON on loopback port $WDA_PORT (default 8100): the host's localhost on a simulator, USB-only via iproxy on a device.
//
//   GET  /status                                  -> {ready, app}
//   GET  /ui                                      -> {app, screen:[w,h], elements:[{type, label?, id?, value?, placeholder?,
//                                                    selected?, disabled?, rect:[x,y,w,h]}]}  on-screen elements, in points
//   GET  /screenshot                              -> {jpeg}              base64
//   POST /screenshot {using, value} | {rect}      -> {jpeg} one element, or rect:[x,y,w,h] in points cropped from the screen;
//                                                    quality? 0–1, default 0.8
//   POST /app        {bundleId}                   -> attach to (activate) an app; "com.apple.springboard" for home
//   POST /launch     {bundleId, args?, env?}      -> launch fresh and attach
//   POST /terminate  {bundleId}
//   POST /tap        {x, y} | {using, value}      -> using: "id" (identifier or label) | "predicate" (NSPredicate format)
//   POST /longpress  {x, y, duration}
//   POST /swipe      {x1, y1, x2, y2, duration?}
//   POST /type       {text, using?, value?}       -> types into the focused element, or into a found one
//   POST /find       {using, value, timeout?}     -> {frame, label, identifier, value, enabled}
//   POST /home
//   POST /quit                                    -> stop the server and end the session
//
// Opening the WDALite-Runner app on the device shows a "Stop Automation" button that does the same as /quit.

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <netinet/in.h>
#import <sys/socket.h>

@interface WDALite : XCTestCase
@end

static XCUIApplication *gApp;
static volatile BOOL gQuit;

static XCUICoordinate *Coord(NSDictionary *b, NSString *kx, NSString *ky)
{
  return [[gApp coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
          coordinateWithOffset:CGVectorMake([b[kx] doubleValue], [b[ky] doubleValue])];
}

static XCUIElement *Find(NSDictionary *b)
{
  NSString *value = b[@"value"];
  NSPredicate *p = [b[@"using"] isEqual:@"predicate"]
    ? [NSPredicate predicateWithFormat:value]
    : [NSPredicate predicateWithFormat:@"identifier == %@ OR label == %@", value, value];
  XCUIElement *e = [[gApp descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:p].firstMatch;
  if (![e waitForExistenceWithTimeout:[b[@"timeout"] ?: @5 doubleValue]]) {
    @throw [NSException exceptionWithName:@"404" reason:[NSString stringWithFormat:@"No element for %@", value] userInfo:nil];
  }
  return e;
}

// Flattens the snapshot to on-screen controls and text. Containers are walked but not listed, a labelled control
// stands for its subtree (its row text and chevrons add nothing), and unlabelled images (SF Symbol names) are dropped.
static void Collect(id<XCUIElementSnapshot> s, CGRect screen, NSMutableArray *out)
{
  static NSArray<NSString *> *names;
  static NSSet<NSNumber *> *controls, *containers;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = @[@"Any", @"Other", @"Application", @"Group", @"Window", @"Sheet", @"Drawer", @"Alert", @"Dialog", @"Button",
              @"RadioButton", @"RadioGroup", @"CheckBox", @"DisclosureTriangle", @"PopUpButton", @"ComboBox",
              @"MenuButton", @"ToolbarButton", @"Popover", @"Keyboard", @"Key", @"NavigationBar", @"TabBar",
              @"TabGroup", @"Toolbar", @"StatusBar", @"Table", @"TableRow", @"TableColumn", @"Outline", @"OutlineRow",
              @"Browser", @"CollectionView", @"Slider", @"PageIndicator", @"ProgressIndicator", @"ActivityIndicator",
              @"SegmentedControl", @"Picker", @"PickerWheel", @"Switch", @"Toggle", @"Link", @"Image", @"Icon",
              @"SearchField", @"ScrollView", @"ScrollBar", @"StaticText", @"TextField", @"SecureTextField",
              @"DatePicker", @"TextView", @"Menu", @"MenuItem", @"MenuBar", @"MenuBarItem", @"Map", @"WebView",
              @"IncrementArrow", @"DecrementArrow", @"Timeline", @"RatingIndicator", @"ValueIndicator", @"SplitGroup",
              @"Splitter", @"RelevanceIndicator", @"ColorWell", @"HelpTag", @"Matte", @"DockItem", @"Ruler",
              @"RulerMarker", @"Grid", @"LevelIndicator", @"Cell", @"LayoutArea", @"LayoutItem", @"Handle", @"Stepper",
              @"Tab", @"TouchBar", @"StatusItem"];
    controls = [NSSet setWithArray:@[@(XCUIElementTypeButton), @(XCUIElementTypeSwitch), @(XCUIElementTypeToggle),
                                     @(XCUIElementTypeTextField), @(XCUIElementTypeSecureTextField),
                                     @(XCUIElementTypeSearchField), @(XCUIElementTypeTextView), @(XCUIElementTypeSlider),
                                     @(XCUIElementTypeLink), @(XCUIElementTypeKey), @(XCUIElementTypeIcon),
                                     @(XCUIElementTypeCell), @(XCUIElementTypeSegmentedControl)]];
    containers = [NSSet setWithArray:@[@(XCUIElementTypeApplication), @(XCUIElementTypeWindow), @(XCUIElementTypeGroup),
                                       @(XCUIElementTypeTable), @(XCUIElementTypeCollectionView),
                                       @(XCUIElementTypeScrollView), @(XCUIElementTypeToolbar),
                                       @(XCUIElementTypeNavigationBar), @(XCUIElementTypeTabBar),
                                       @(XCUIElementTypeKeyboard)]];
  });

  CGRect f = CGRectIntersection(s.frame, screen);
  NSString *value = [s.value description];
  if ([value isEqualToString:s.label]) value = nil;
  BOOL text = s.label.length || value.length || (s.identifier.length && s.elementType != XCUIElementTypeImage);
  BOOL control = [controls containsObject:@(s.elementType)];
  BOOL listed = !CGRectIsEmpty(f) && ![containers containsObject:@(s.elementType)]
    && (control ? (text || s.children.count == 0) : text && (s.elementType != XCUIElementTypeOther || !s.children.count));
  if (listed) {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[@"type"] = (NSUInteger)s.elementType < names.count ? names[s.elementType] : @(s.elementType);
    if (s.label.length) e[@"label"] = s.label;
    if (s.identifier.length && ![s.identifier isEqualToString:s.label]) e[@"id"] = s.identifier;
    if (value.length) e[@"value"] = value;
    if (!value.length && s.placeholderValue.length) e[@"placeholder"] = s.placeholderValue;
    if (s.selected) e[@"selected"] = @YES;
    if (!s.enabled) e[@"disabled"] = @YES;
    e[@"rect"] = @[@(lround(f.origin.x)), @(lround(f.origin.y)), @(lround(f.size.width)), @(lround(f.size.height))];
    [out addObject:e];
  }
  if (listed && control && s.label.length) return;
  for (id<XCUIElementSnapshot> child in s.children) Collect(child, screen, out);
}

static id Dispatch(NSString *route, NSDictionary *b)
{
  if ([route isEqual:@"GET /status"]) return @{@"ready": @YES, @"app": gApp.identifier ?: @""};
  if ([route isEqual:@"GET /ui"]) {
    if (gApp.state != XCUIApplicationStateRunningForeground) {
      gApp = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
    }
    NSError *error;
    id<XCUIElementSnapshot> root = [gApp snapshotWithError:&error];
    if (!root) @throw [NSException exceptionWithName:@"500" reason:error.localizedDescription userInfo:nil];
    NSMutableArray *elements = [NSMutableArray array];
    Collect(root, root.frame, elements);
    return @{@"app": gApp.identifier ?: @"",
             @"screen": @[@(lround(root.frame.size.width)), @(lround(root.frame.size.height))],
             @"elements": [NSOrderedSet orderedSetWithArray:elements].array};
  }
  if ([route hasSuffix:@" /screenshot"]) {
    UIImage *image;
    if ([route hasPrefix:@"GET"]) {
      image = XCUIScreen.mainScreen.screenshot.image;
    } else if (b[@"using"]) {
      image = Find(b).screenshot.image;
    } else {
      NSArray<NSNumber *> *r = b[@"rect"];
      if (r.count != 4) @throw [NSException exceptionWithName:@"400" reason:@"Pass {using, value} or {rect:[x,y,w,h]}" userInfo:nil];
      CGImageRef full = XCUIScreen.mainScreen.screenshot.image.CGImage;
      CGFloat s = CGImageGetWidth(full) / UIScreen.mainScreen.bounds.size.width;
      CGImageRef crop = CGImageCreateWithImageInRect(full, CGRectMake(r[0].doubleValue * s, r[1].doubleValue * s,
                                                                      r[2].doubleValue * s, r[3].doubleValue * s));
      if (!crop) @throw [NSException exceptionWithName:@"400" reason:@"rect is outside the screen" userInfo:nil];
      image = [UIImage imageWithCGImage:crop];
      CGImageRelease(crop);
    }
    NSData *jpeg = UIImageJPEGRepresentation(image, [b[@"quality"] ?: @0.8 doubleValue]);
    return @{@"jpeg": [jpeg base64EncodedStringWithOptions:0]};
  }
  if ([route isEqual:@"POST /app"]) {
    gApp = [[XCUIApplication alloc] initWithBundleIdentifier:b[@"bundleId"]];
    [gApp activate];
    return @{};
  }
  if ([route isEqual:@"POST /launch"]) {
    gApp = [[XCUIApplication alloc] initWithBundleIdentifier:b[@"bundleId"]];
    gApp.launchArguments = b[@"args"] ?: @[];
    gApp.launchEnvironment = b[@"env"] ?: @{};
    [gApp launch];
    return @{};
  }
  if ([route isEqual:@"POST /terminate"]) {
    [[[XCUIApplication alloc] initWithBundleIdentifier:b[@"bundleId"]] terminate];
    return @{};
  }
  if ([route isEqual:@"POST /tap"]) {
    b[@"using"] ? [Find(b) tap] : [Coord(b, @"x", @"y") tap];
    return @{};
  }
  if ([route isEqual:@"POST /longpress"]) {
    [Coord(b, @"x", @"y") pressForDuration:[b[@"duration"] ?: @1 doubleValue]];
    return @{};
  }
  if ([route isEqual:@"POST /swipe"]) {
    [Coord(b, @"x1", @"y1") pressForDuration:[b[@"duration"] ?: @0.05 doubleValue]
                        thenDragToCoordinate:Coord(b, @"x2", @"y2")];
    return @{};
  }
  if ([route isEqual:@"POST /type"]) {
    b[@"using"] ? [Find(b) typeText:b[@"text"]] : [gApp typeText:b[@"text"]];
    return @{};
  }
  if ([route isEqual:@"POST /find"]) {
    XCUIElement *e = Find(b);
    CGRect f = e.frame;
    return @{@"frame": @{@"x": @(f.origin.x), @"y": @(f.origin.y), @"width": @(f.size.width), @"height": @(f.size.height)},
             @"label": e.label, @"identifier": e.identifier,
             @"value": [e.value description] ?: NSNull.null, @"enabled": @(e.enabled)};
  }
  if ([route isEqual:@"POST /quit"]) return @{};
  if ([route isEqual:@"POST /home"]) {
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    gApp = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
    return @{};
  }
  @throw [NSException exceptionWithName:@"404" reason:[@"Unknown route " stringByAppendingString:route] userInfo:nil];
}

static void Respond(int fd, NSInteger status, id obj)
{
  NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  NSMutableData *out = [[NSString stringWithFormat:
    @"HTTP/1.1 %ld X\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
    (long)status, (unsigned long)body.length] dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
  [out appendData:body];
  for (size_t sent = 0; sent < out.length;) {
    ssize_t n = send(fd, (const char *)out.bytes + sent, out.length - sent, 0);
    if (n <= 0) break;
    sent += (size_t)n;
  }
}

static void Serve(int fd)
{
  NSMutableData *buf = [NSMutableData data];
  NSRange end = NSMakeRange(NSNotFound, 0);
  NSUInteger need = NSUIntegerMax;
  char tmp[65536];
  for (ssize_t n; buf.length < need && (n = recv(fd, tmp, sizeof tmp, 0)) > 0;) {
    [buf appendBytes:tmp length:(NSUInteger)n];
    if (end.location != NSNotFound) continue;
    end = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, buf.length)];
    if (end.location == NSNotFound) continue;
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    NSRange cl = [head rangeOfString:@"content-length:\\s*\\d+" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    need = NSMaxRange(end) + (cl.location == NSNotFound ? 0
      : (NSUInteger)[[head substringWithRange:cl] componentsSeparatedByString:@":"][1].integerValue);
  }
  if (end.location == NSNotFound) return;

  NSArray<NSString *> *lines = [[[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)]
                                                      encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\r\n"];
  NSArray<NSString *> *request = [lines.firstObject componentsSeparatedByString:@" "];
  if (request.count < 2) return Respond(fd, 400, @{@"error": @"bad request"});
  NSData *raw = [buf subdataWithRange:NSMakeRange(NSMaxRange(end), buf.length - NSMaxRange(end))];
  NSDictionary *body = raw.length ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : @{};
  NSString *route = [NSString stringWithFormat:@"%@ %@", request[0], [request[1] componentsSeparatedByString:@"?"][0]];

  __block NSInteger status = 200;
  __block id result;
  dispatch_sync(dispatch_get_main_queue(), ^{
    @try {
      result = @{@"value": Dispatch(route, [body isKindOfClass:NSDictionary.class] ? body : @{})};
    } @catch (NSException *e) {
      status = [e.name isEqual:@"404"] ? 404 : [e.name isEqual:@"400"] ? 400 : 500;
      result = @{@"error": e.reason ?: e.name};
    }
  });
  Respond(fd, status, result);
  if ([route isEqual:@"POST /quit"]) gQuit = YES;
}

@implementation WDALite

- (void)testServe
{
  self.continueAfterFailure = YES;
  uint16_t port = (uint16_t)[NSProcessInfo.processInfo.environment[@"WDA_PORT"] ?: @"8100" intValue];
  gApp = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];

  int s = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  NSAssert(bind(s, (struct sockaddr *)&addr, sizeof addr) == 0 && listen(s, 16) == 0, @"Cannot listen on %d", port);
  NSLog(@"WDALite listening on port %d", port);

  [NSThread detachNewThreadWithBlock:^{
    signal(SIGPIPE, SIG_IGN);
    for (int c; (c = accept(s, NULL, NULL)) >= 0; close(c)) Serve(c);
  }];
  // The test bundle lives in the runner's process, so its scene can host a stop button for whoever opens the app.
  __block UIWindow *stopWindow;
  void (^installStop)(UIScene *) = ^(UIScene *scene) {
    if (stopWindow || ![scene isKindOfClass:UIWindowScene.class]) return;
    UIButtonConfiguration *config = UIButtonConfiguration.filledButtonConfiguration;
    config.baseBackgroundColor = UIColor.systemRedColor;
    config.buttonSize = UIButtonConfigurationSizeLarge;
    config.title = @"Stop Automation";
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
      gQuit = YES;
    }]];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    [root.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[[button.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor],
                                              [button.centerYAnchor constraintEqualToAnchor:root.view.centerYAnchor]]];
    stopWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    stopWindow.rootViewController = root;
    stopWindow.windowLevel = UIWindowLevelAlert;
    [stopWindow makeKeyAndVisible];
  };
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) installStop(scene);
  [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillEnterForegroundNotification object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *n) { installStop(n.object); }];
  [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *n) { installStop(n.object); }];

  while (!gQuit) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:1]];
  stopWindow.hidden = YES;
  close(s);
}

@end
OBJC
cp -R "$PLAT/Library/Xcode/Agents/XCTRunner.app" "$APP"
mkdir -p "$XCT"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleExecutable XCTRunner" \
  -c "Set :CFBundleName WDALite-Runner" -c "Add :CFBundleDisplayName string Use $(printf '\xef\xa3\xbf')" "$APP/Info.plist"
# The template is fat (arm64 + arm64e); an arm64e host process cannot load the arm64 test bundle.
lipo "$APP/XCTRunner" -thin "${TARGET%%-*}" -output "$APP/XCTRunner"

xcrun --sdk $SDK clang -fobjc-arc -fmodules -bundle -target "$TARGET" \
  -F"$PLAT/Library/Frameworks" -F"$PLAT/Library/PrivateFrameworks" -framework XCTest -framework XCUIAutomation \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/../../Frameworks \
  -o "$XCT/WDALite" "$OUT/WDALite.m"
cat > "$XCT/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.xctest</string>
  <key>CFBundleExecutable</key><string>WDALite</string>
  <key>CFBundleName</key><string>WDALite</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$([[ $SDK == iphoneos ]] && echo iPhoneOS || echo iPhoneSimulator)</string></array>
  <key>DTPlatformName</key><string>$SDK</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>XCTContainsUITests</key><true/>
</dict></plist>
EOF

if [[ $SDK == iphoneos ]]; then
  cp "$WDA_PROFILE" "$APP/embedded.mobileprovision"
  security cms -D -i "$WDA_PROFILE" > "$OUT/profile.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$OUT/profile.plist" > "$OUT/ent.plist"
  TEAM=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$OUT/ent.plist")
  /usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE_ID" -c 'Delete :keychain-access-groups' \
    -c 'Add :keychain-access-groups array' -c "Add :keychain-access-groups:0 string $TEAM.$BUNDLE_ID" "$OUT/ent.plist"
  SIGN=(codesign -f -s "$WDA_SIGN_IDENTITY")
else
  SIGN=(codesign -f -s -)
fi
chmod -R u+rwX,go+rX "$APP"
"${SIGN[@]}" "$XCT"
[[ $SDK == iphoneos ]] && SIGN+=(--entitlements "$OUT/ent.plist")
"${SIGN[@]}" "$APP"

cat > "$OUT/WDALite.xctestrun" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>WDALite</key><dict>
    <key>TestHostPath</key><string>__TESTROOT__/WDALite-Runner.app</string>
    <key>TestHostBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>TestBundlePath</key><string>__TESTHOST__/PlugIns/WDALite.xctest</string>
    <key>IsUITestBundle</key><true/>
    <key>IsXCTRunnerHostedTestBundle</key><true/>
    <key>UseUITargetAppProvidedByTests</key><true/>
    <key>TestingEnvironmentVariables</key><dict>
      <key>WDA_PORT</key><string>$PORT</string>
    </dict>
  </dict>
</dict></plist>
EOF

if [[ $SDK == iphoneos ]]; then
  python3 -I -c "$PY" forward "$UDID" "$PORT" &
  trap 'kill $!' EXIT
fi
echo "WDALite on $UDID -> try: curl localhost:$PORT/status"
xcodebuild test-without-building -xctestrun "$OUT/WDALite.xctestrun" -destination "id=$UDID"
