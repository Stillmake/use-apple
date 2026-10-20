#!/bin/bash
# use-apple — a single file that lets agents drive Apple devices. It builds the embedded XCUITest server (Objective-C
# below) into a runner without an Xcode project and runs it on a simulator or the USB-connected device.
# Needs only Xcode: devices are listed and forwarded through macOS's own usbmuxd.
#
#   ./use-apple.sh [udid] [port]   udid defaults to the only USB device
#
# The runner is only a fixed core; every route is JavaScript in the ROUTES block below, which is pushed to the running
# server on start and again whenever this file is saved with that block changed. Routes change without a rebuild.
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
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
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
// WDALite — a single-file XCUITest automation server whose routes are JavaScript, loaded at runtime.
// HTTP/JSON on loopback port $WDA_PORT (default 8100): the host's localhost on a simulator, USB-only via iproxy on a device.
//
// Native routes:
//   GET  /status                 -> {ready, routes}
//   POST /routes  <js source>    -> replace all routes: runs the source in a fresh context and serves its global `routes`,
//                                   {"METHOD /path": function(body) -> value}; a source that throws leaves the old ones
//   POST /eval    <js source>    -> the value of the source, evaluated in the routes' context
//   POST /quit                   -> stop the server and end the session
// Any other route calls routes[route] with the JSON body and answers {value}, or {error} with the thrown status
// (an Error's `status`, else 500).
//
// JavaScript globals:
//   send(target, selector, ...args)  sends an Objective-C message. target is an object or a class name; objects and
//                                    selectors are passed as strings, numbers and BOOLs as numbers, structs as flat arrays
//                                    of doubles (CGPoint, CGVector, CGRect…), pointers only as null. Foundation results
//                                    arrive as JS values; other objects as opaque handles to send to again.
//   jpeg(image, quality) -> base64   crop(image, [x, y, w, h]) -> image in points   log(...)
//
// Opening the WDALite-Runner app on the device shows a "Stop Automation" button that does the same as /quit.

#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <netinet/in.h>
#import <sys/socket.h>

@interface WDALite : XCTestCase
@end

static JSContext *gJS;
static volatile BOOL gQuit;

static id Unbox(JSValue *v)
{
  return v.isNull || v.isUndefined ? nil : v.toObject;
}

static const char *Unqualified(const char *type)
{
  while (*type && strchr("rnNoORVA", *type)) type++;
  return type;
}

// One message through NSInvocation, marshalling by the method's type encodings.
static id Send(id target, NSString *name, NSArray<JSValue *> *args)
{
  SEL sel = NSSelectorFromString(name);
  NSMethodSignature *sig = [target methodSignatureForSelector:sel];
  if (!sig) {
    @throw [NSException exceptionWithName:@"400" reason:[NSString stringWithFormat:@"%@ does not respond to %@", target, name]
                                 userInfo:nil];
  }
  if (sig.numberOfArguments - 2 != args.count) {
    @throw [NSException exceptionWithName:@"400" reason:[NSString stringWithFormat:@"%@ takes %lu arguments", name,
                                                         (unsigned long)sig.numberOfArguments - 2] userInfo:nil];
  }
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  [inv retainArguments];
  inv.target = target;
  inv.selector = sel;
  for (NSUInteger i = 0; i < args.count; i++) {
    const char *type = Unqualified([sig getArgumentTypeAtIndex:i + 2]);
    NSUInteger size;
    NSGetSizeAndAlignment(type, &size, NULL);
    double buf[8] = {0};
    NSCAssert(size <= sizeof buf, @"argument %lu of %@ is too large", (unsigned long)i, name);
    JSValue *a = args[i];
    switch (*type) {
      case '@': case '#': { __unsafe_unretained id o = Unbox(a); memcpy(buf, &o, sizeof o); break; }
      case ':': { SEL s = NSSelectorFromString(a.toString); memcpy(buf, &s, sizeof s); break; }
      case '^': case '*': NSCAssert(a.isNull || a.isUndefined, @"pointer arguments of %@ must be null", name); break;
      case 'f': *(float *)buf = (float)a.toDouble; break;
      case 'd': *buf = a.toDouble; break;
      case '{': {
        NSArray<NSNumber *> *n = a.toArray;
        NSCAssert(n.count * sizeof(double) == size, @"argument %lu of %@ needs %lu numbers", (unsigned long)i, name,
                 (unsigned long)(size / sizeof(double)));
        for (NSUInteger j = 0; j < n.count; j++) buf[j] = n[j].doubleValue;
        break;
      }
      default: { long long v = a.toNumber.longLongValue; memcpy(buf, &v, size); break; }  // integers, BOOL; little-endian
    }
    [inv setArgument:buf atIndex:i + 2];
  }
  // Cocoa method families: init consumes its receiver, and alloc/new/copy/mutableCopy/init return +1.
  NSString *family = [name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
  NSRange word = [family rangeOfCharacterFromSet:NSCharacterSet.lowercaseLetterCharacterSet.invertedSet];
  family = word.location == NSNotFound ? family : [family substringToIndex:word.location];
  BOOL owned = [@[@"alloc", @"new", @"copy", @"init"] containsObject:family]
    || ([family isEqual:@"mutable"] && [[name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]]
                                        hasPrefix:@"mutableCopy"]);
  if ([family isEqual:@"init"]) CFBridgingRetain(target);
  [inv invoke];

  const char *type = Unqualified(sig.methodReturnType);
  if (*type == 'v') return nil;
  double buf[8] = {0};
  NSCAssert(sig.methodReturnLength <= sizeof buf, @"the result of %@ is too large", name);
  [inv getReturnValue:buf];
  switch (*type) {
    case '@': case '#': {
      void *o;
      memcpy(&o, buf, sizeof o);
      return owned ? (__bridge_transfer id)o : (__bridge id)o;
    }
    case ':': return NSStringFromSelector(*(SEL *)buf);
    case '*': return *(char **)buf ? @(*(char **)buf) : nil;
    case '^': return @((uintptr_t)*(void **)buf);
    case 'B': return @(*(bool *)buf);
    case 'c': return @(*(char *)buf);
    case 'C': return @(*(unsigned char *)buf);
    case 's': return @(*(short *)buf);
    case 'S': return @(*(unsigned short *)buf);
    case 'i': return @(*(int *)buf);
    case 'I': return @(*(unsigned *)buf);
    case 'l': case 'q': return @(*(long long *)buf);
    case 'L': case 'Q': return @(*(unsigned long long *)buf);
    case 'f': return @(*(float *)buf);
    case 'd': return @(*buf);
    case '{': {
      NSMutableArray<NSNumber *> *n = [NSMutableArray array];
      for (NSUInteger j = 0; j < sig.methodReturnLength / sizeof(double); j++) [n addObject:@(buf[j])];
      return n;
    }
  }
  @throw [NSException exceptionWithName:@"400" reason:[NSString stringWithFormat:@"%@ returns unsupported %s", name, type]
                               userInfo:nil];
}

// Native errors become JS exceptions carrying the HTTP status, so routes can catch them or let them answer.
static void Raise(NSInteger status, NSString *message)
{
  JSContext *ctx = JSContext.currentContext;
  JSValue *error = [JSValue valueWithNewErrorFromMessage:message inContext:ctx];
  error[@"status"] = @(status);
  ctx.exception = error;
}

static JSContext *NewContext(void)
{
  JSContext *ctx = [JSContext new];
  ctx[@"send"] = ^id {
    NSArray<JSValue *> *a = JSContext.currentArguments;
    @try {
      if (a.count < 2) @throw [NSException exceptionWithName:@"400" reason:@"send(target, selector, ...args)" userInfo:nil];
      id target = a[0].isString ? NSClassFromString(a[0].toString) : Unbox(a[0]);
      if (!target) {
        @throw [NSException exceptionWithName:@"400" reason:[NSString stringWithFormat:@"No target for %@", a[1].toString]
                                     userInfo:nil];
      }
      return Send(target, a[1].toString, [a subarrayWithRange:NSMakeRange(2, a.count - 2)]);
    } @catch (NSException *e) {
      Raise(e.name.integerValue ?: 500, e.reason ?: e.name);
      return nil;
    }
  };
  ctx[@"jpeg"] = ^NSString *(UIImage *image, double quality) {
    return [UIImageJPEGRepresentation(image, quality) base64EncodedStringWithOptions:0];
  };
  ctx[@"crop"] = ^UIImage *(UIImage *image, NSArray<NSNumber *> *r) {
    CGFloat s = image.scale * image.size.width / UIScreen.mainScreen.bounds.size.width;
    CGImageRef crop = r.count == 4 ? CGImageCreateWithImageInRect(image.CGImage, CGRectMake(r[0].doubleValue * s,
      r[1].doubleValue * s, r[2].doubleValue * s, r[3].doubleValue * s)) : NULL;
    if (!crop) return Raise(400, @"rect is outside the screen"), nil;
    UIImage *cropped = [UIImage imageWithCGImage:crop];
    CGImageRelease(crop);
    return cropped;
  };
  ctx[@"log"] = ^{
    NSLog(@"WDALite: %@", [JSContext.currentArguments componentsJoinedByString:@" "]);
  };
  return ctx;
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
  NSString *route = [NSString stringWithFormat:@"%@ %@", request[0], [request[1] componentsSeparatedByString:@"?"][0]];

  __block NSInteger status = 200;
  __block id result;
  dispatch_sync(dispatch_get_main_queue(), ^{
    if ([route isEqual:@"GET /status"]) {
      result = @{@"value": @{@"ready": @YES, @"routes": [gJS evaluateScript:@"Object.keys(globalThis.routes ?? {})"].toArray}};
      return;
    }
    if ([route isEqual:@"POST /quit"]) {
      result = @{@"value": @{}};
      return;
    }
    NSString *source = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] ?: @"";
    JSContext *ctx = gJS;
    JSValue *value;
    if ([route isEqual:@"POST /routes"]) {
      ctx = NewContext();
      [ctx evaluateScript:source];
      value = ctx.exception ? nil : [ctx evaluateScript:@"Object.keys(routes)"];
      if (!ctx.exception) gJS = ctx;
    } else if ([route isEqual:@"POST /eval"]) {
      value = [ctx evaluateScript:source];
    } else {
      JSValue *fn = ctx[@"routes"][route];
      if (!fn.isObject) {
        status = 404;
        result = @{@"error": [@"Unknown route " stringByAppendingString:route]};
        return;
      }
      id body = raw.length ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
      value = [fn callWithArguments:@[[body isKindOfClass:NSDictionary.class] ? body : @{}]];
    }
    if (ctx.exception) {
      JSValue *e = ctx.exception;
      ctx.exception = nil;
      status = e[@"status"].isNumber ? e[@"status"].toInt32 : 500;
      result = @{@"error": (e[@"message"].isString ? e[@"message"] : e).toString};
      return;
    }
    id v = Unbox(value) ?: @{};
    result = @{@"value": [NSJSONSerialization isValidJSONObject:@[v]] ? v : [v description]};
  });
  Respond(fd, status, result);
  if ([route isEqual:@"POST /quit"]) gQuit = YES;
}

@implementation WDALite

- (void)testServe
{
  self.continueAfterFailure = YES;
  uint16_t port = (uint16_t)[NSProcessInfo.processInfo.environment[@"WDA_PORT"] ?: @"8100" intValue];
  gJS = NewContext();

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

# The routes, never run by bash: the watcher below reads this block from the file itself, so saving it live-reloads them.
: <<'ROUTES'
// Each "METHOD /path" maps a JSON body to the response's value; the native globals send, jpeg, crop and log are
// documented at the top of the server code above. All geometry is in points.
//
// An element is located by exactly one of {id} (accessibility identifier), {label} or {predicate} (NSPredicate format),
// and described everywhere as {type, label?, id?, value?, placeholder?, selected?, disabled?, rect:[x,y,w,h]}.
// A target is a located element or a point {x, y}. Locating waits up to `timeout` seconds (default 5).
//
//   GET  /ui                                    -> {app, screen:[w,h], elements:[element]}  on-screen elements
//   GET  /screenshot                            -> {jpeg}  base64
//   POST /screenshot {element | rect, quality?} -> {jpeg}  one element, or rect:[x,y,w,h] of the screen; quality 0–1
//   POST /app        {bundleId}                 -> {app}   attach to and activate an app; it stays attached across reloads
//   POST /launch     {bundleId, args?, env?}    -> {app}   launch fresh and attach
//   POST /terminate  {bundleId}
//   POST /find       {element}                  -> element & {hittable}
//   POST /wait       {element, gone?}           -> element & {hittable} once it exists, or null once it is gone;
//                                                  408 at the timeout
//   POST /tap        {target, double?}
//   POST /longpress  {target, duration?}        seconds, default 1
//   POST /swipe      {from, to, velocity?}      from/to are targets; a flick at velocity points/s, default 1500
//   POST /scroll     {direction, in?, until?, max?}
//                                               -> element & {hittable} | null   direction "up" | "down" | "left" |
//                                                  "right" moves the view toward that edge of the content, swiping
//                                                  inside the element `in` (default the app); with the element `until`,
//                                                  swipes up to max times (default 10) until it is hittable
//   POST /type       {text, element?}           types into the focused element, or into element after tapping it
//   POST /home
//   POST /lock                                  press the side button (sleep/wake)

const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
const App = id => send(send('XCUIApplication', 'alloc'), 'initWithBundleIdentifier:', id);
const device = () => send('XCUIDevice', 'sharedDevice');
const screen = () => send(send(send('XCUIScreen', 'mainScreen'), 'screenshot'), 'image');
const defaults = send('NSUserDefaults', 'standardUserDefaults');
const HOME = 'com.apple.springboard';

// The attached app is kept in the runner's defaults, so pushing new routes does not detach it.
let app = App(send(defaults, 'stringForKey:', 'use-apple.app') ?? HOME);
function attach(bundleId) {
  app = App(bundleId);
  send(defaults, 'setObject:forKey:', bundleId, 'use-apple.app');
  return app;
}

const LOCATORS = ['id', 'label', 'predicate'];

function query(b) {
  const keys = LOCATORS.filter(k => b[k] != null);
  if (keys.length !== 1) fail(400, `Locate an element with one of {${LOCATORS.join(', ')}}`);
  const predicate = keys[0] === 'predicate'
    ? send('NSPredicate', 'predicateWithFormat:argumentArray:', b.predicate, [])
    : send('NSPredicate', 'predicateWithFormat:argumentArray:', keys[0] === 'id' ? 'identifier == %@' : 'label == %@',
           [b[keys[0]]]);
  return send(send(send(app, 'descendantsMatchingType:', 0), 'matchingPredicate:', predicate), 'firstMatch');
}

function find(b) {
  const e = query(b);
  if (!send(e, 'waitForExistenceWithTimeout:', b.timeout ?? 5)) fail(404, `No element ${JSON.stringify(b)}`);
  return e;
}

// A point or an element's center, as an XCUICoordinate.
function at(t) {
  if (t?.x != null) return send(send(app, 'coordinateWithNormalizedOffset:', [0, 0]), 'coordinateWithOffset:', [t.x, t.y]);
  return send(find(t ?? {}), 'coordinateWithNormalizedOffset:', [0.5, 0.5]);
}

// XCUIElementType, in enum order.
const TYPES = ['Any', 'Other', 'Application', 'Group', 'Window', 'Sheet', 'Drawer', 'Alert', 'Dialog', 'Button',
  'RadioButton', 'RadioGroup', 'CheckBox', 'DisclosureTriangle', 'PopUpButton', 'ComboBox', 'MenuButton', 'ToolbarButton',
  'Popover', 'Keyboard', 'Key', 'NavigationBar', 'TabBar', 'TabGroup', 'Toolbar', 'StatusBar', 'Table', 'TableRow',
  'TableColumn', 'Outline', 'OutlineRow', 'Browser', 'CollectionView', 'Slider', 'PageIndicator', 'ProgressIndicator',
  'ActivityIndicator', 'SegmentedControl', 'Picker', 'PickerWheel', 'Switch', 'Toggle', 'Link', 'Image', 'Icon',
  'SearchField', 'ScrollView', 'ScrollBar', 'StaticText', 'TextField', 'SecureTextField', 'DatePicker', 'TextView', 'Menu',
  'MenuItem', 'MenuBar', 'MenuBarItem', 'Map', 'WebView', 'IncrementArrow', 'DecrementArrow', 'Timeline',
  'RatingIndicator', 'ValueIndicator', 'SplitGroup', 'Splitter', 'RelevanceIndicator', 'ColorWell', 'HelpTag', 'Matte',
  'DockItem', 'Ruler', 'RulerMarker', 'Grid', 'LevelIndicator', 'Cell', 'LayoutArea', 'LayoutItem', 'Handle', 'Stepper',
  'Tab', 'TouchBar', 'StatusItem'];
const CONTROLS = new Set(['Button', 'Switch', 'Toggle', 'TextField', 'SecureTextField', 'SearchField', 'TextView',
  'Slider', 'Link', 'Key', 'Icon', 'Cell', 'SegmentedControl']);
const CONTAINERS = new Set(['Application', 'Window', 'Group', 'Table', 'CollectionView', 'ScrollView', 'Toolbar',
  'NavigationBar', 'TabBar', 'Keyboard']);

// Flattens the snapshot to on-screen controls and text. Containers are walked but not listed, a labelled control
// stands for its subtree (its row text and chevrons add nothing), and unlabelled images (SF Symbol names) are dropped.
// An element or snapshot as an element description, its rect clipped to [X, Y, W, H]; null when clipped away.
function describe(s, [X, Y, W, H]) {
  const raw = send(s, 'elementType'), type = TYPES[raw] ?? raw;
  const label = send(s, 'label') ?? '', id = send(s, 'identifier') ?? '';
  let value = send(s, 'value');
  value = value == null || String(value) === label ? '' : String(value);
  const [x, y, w, h] = send(s, 'frame');
  const l = Math.max(x, X), t = Math.max(y, Y), r = Math.min(x + w, X + W), b = Math.min(y + h, Y + H);
  if (r <= l || b <= t) return null;
  const e = { type };
  if (label) e.label = label;
  if (id && id !== label) e.id = id;
  if (value) e.value = value;
  else if (send(s, 'placeholderValue')) e.placeholder = send(s, 'placeholderValue');
  if (send(s, 'isSelected')) e.selected = true;
  if (!send(s, 'isEnabled')) e.disabled = true;
  e.rect = [l, t, r - l, b - t].map(Math.round);
  return e;
}

// A live element's description with whether a tap would reach it; off-screen elements keep their unclipped rect.
function located(e) {
  return { ...(describe(e, send(app, 'frame')) ??describe(e, [-Infinity, -Infinity, Infinity, Infinity])),
           hittable: !!send(e, 'isHittable') };
}

function collect(s, screen, out) {
  const e = describe(s, screen), children = send(s, 'children') ?? [];
  const text = e && (e.label || e.value || (e.id && e.type !== 'Image'));
  const control = CONTROLS.has(e?.type);
  const listed = e && !CONTAINERS.has(e.type)
    && (control ? text || !children.length : text && (e.type !== 'Other' || !children.length));
  if (listed) out.push(e);
  if (listed && control && e.label) return;
  for (const child of children) collect(child, screen, out);
}

// XCUIElement swipes, by the direction the view moves through its content.
const SWIPES = { down: 'swipeUp', up: 'swipeDown', right: 'swipeLeft', left: 'swipeRight' };

var routes = {
  'GET /ui'() {
    // An app sent to the background stays attached; meanwhile the screen is read from the home screen.
    const shown = send(app, 'state') === 4 ? app : App(HOME);  // 4: XCUIApplicationStateRunningForeground
    const root = send(shown, 'snapshotWithError:', null) ?? fail(500, 'Cannot snapshot ' + send(shown, 'bundleID'));
    const frame = send(root, 'frame'), elements = [], seen = new Set();
    collect(root, frame, elements);
    return {
      app: send(shown, 'bundleID'),
      screen: [Math.round(frame[2]), Math.round(frame[3])],
      elements: elements.filter(e => !seen.has(JSON.stringify(e)) && seen.add(JSON.stringify(e))),
    };
  },
  'GET /screenshot'() {
    return { jpeg: jpeg(screen(), 0.8) };
  },
  'POST /screenshot'(b) {
    if (b.rect) {
      if (b.rect.length !== 4) fail(400, 'rect is [x, y, w, h]');
      return { jpeg: jpeg(crop(screen(), b.rect), b.quality ?? 0.8) };
    }
    return { jpeg: jpeg(send(send(find(b), 'screenshot'), 'image'), b.quality ?? 0.8) };
  },
  'POST /app'(b) {
    send(attach(b.bundleId), 'activate');
    return { app: b.bundleId };
  },
  'POST /launch'(b) {
    attach(b.bundleId);
    send(app, 'setLaunchArguments:', b.args ?? []);
    send(app, 'setLaunchEnvironment:', b.env ?? {});
    send(app, 'launch');
    return { app: b.bundleId };
  },
  'POST /terminate'(b) {
    send(App(b.bundleId), 'terminate');
  },
  'POST /find'(b) {
    return located(find(b));
  },
  'POST /wait'(b) {
    const e = query(b);
    if (b.gone) {
      if (!send(e, 'waitForNonExistenceWithTimeout:', b.timeout ?? 5)) fail(408, `Still there: ${JSON.stringify(b)}`);
      return null;
    }
    if (!send(e, 'waitForExistenceWithTimeout:', b.timeout ?? 5)) fail(408, `Never appeared: ${JSON.stringify(b)}`);
    return located(e);
  },
  'POST /tap'(b) {
    send(at(b), b.double ? 'doubleTap' : 'tap');
  },
  'POST /longpress'(b) {
    send(at(b), 'pressForDuration:', b.duration ?? 1);
  },
  'POST /swipe'(b) {
    send(at(b.from), 'pressForDuration:thenDragToCoordinate:withVelocity:thenHoldForDuration:', 0, at(b.to),
         b.velocity ?? 1500, 0);
  },
  'POST /scroll'(b) {
    const swipe = SWIPES[b.direction] ?? fail(400, `direction is one of ${Object.keys(SWIPES).join(', ')}`);
    const view = b.in ? find(b.in) : app;
    if (!b.until) return send(view, swipe), null;
    const goal = query(b.until);
    for (let i = 0; i < (b.max ?? 10); i++) {
      if (send(goal, 'exists') && send(goal, 'isHittable')) return located(goal);
      send(view, swipe);
    }
    if (send(goal, 'exists') && send(goal, 'isHittable')) return located(goal);
    fail(404, `Not reached by scrolling ${b.direction}: ${JSON.stringify(b.until)}`);
  },
  'POST /type'(b) {
    send(LOCATORS.some(k => b[k] != null) ? find(b) : app, 'typeText:', b.text);
  },
  'POST /home'() {
    send(device(), 'pressButton:', 1);  // 1: XCUIDeviceButtonHome
    attach(HOME);
  },
  'POST /lock'() {
    send(device(), 'pressLockButton');
    attach(HOME);
  },
};
ROUTES

cp -R "$PLAT/Library/Xcode/Agents/XCTRunner.app" "$APP"
mkdir -p "$XCT"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleExecutable XCTRunner" \
  -c "Set :CFBundleName WDALite-Runner" -c "Add :CFBundleDisplayName string Use $(printf '\xef\xa3\xbf')" "$APP/Info.plist"
# The template is fat (arm64 + arm64e); an arm64e host process cannot load the arm64 test bundle.
lipo "$APP/XCTRunner" -thin "${TARGET%%-*}" -output "$APP/XCTRunner"

xcrun --sdk $SDK clang -fobjc-arc -fmodules -bundle -target "$TARGET" \
  -F"$PLAT/Library/Frameworks" -F"$PLAT/Library/PrivateFrameworks" -framework XCTest -framework XCUIAutomation \
  -framework JavaScriptCore \
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

# xcodebuild cannot parse 5-digit runtime builds such as 24A94232 (invalidDigitCount) and then never injects the test
# frameworks, so the runner dies in dyld. Point dyld at the platform's test runtime, as xcodebuild would.
SIMENV=
[[ $SDK == iphonesimulator ]] && SIMENV="
    <key>EnvironmentVariables</key><dict>
      <key>DYLD_FRAMEWORK_PATH</key><string>$PLAT/Library/Frameworks:$PLAT/Library/PrivateFrameworks</string>
      <key>DYLD_LIBRARY_PATH</key><string>$PLAT/usr/lib</string>
    </dict>"
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
    </dict>$SIMENV
  </dict>
</dict></plist>
EOF

# Braced so bash parses the rest before running it: bash reads a script as it goes, and this file is edited live.
{
  [[ $SDK == iphoneos ]] && python3 -I -c "$PY" forward "$UDID" "$PORT" &
  # Push the routes once the server answers, then again whenever a save changes them (a push resets their state).
  (
    until curl -s -m 1 "localhost:$PORT/status" >/dev/null; do sleep 1; done
    LOADED=
    while sleep 1; do
      SRC=$(awk '/^ROUTES$/ { f = 0 } f; /^: <<.ROUTES.$/ { f = 1 }' "$SELF" 2>/dev/null) || continue
      [[ -z $SRC || $SRC == "$LOADED" ]] && continue  # atomic saves briefly empty the file
      echo "routes -> $(curl -s --data-binary "$SRC" "localhost:$PORT/routes")"
      LOADED=$SRC
    done
  ) &
  trap 'kill $(jobs -p) 2>/dev/null' EXIT
  echo "WDALite on $UDID -> try: curl localhost:$PORT/status"
  xcodebuild test-without-building -xctestrun "$OUT/WDALite.xctestrun" -destination "id=$UDID"
  exit
}
