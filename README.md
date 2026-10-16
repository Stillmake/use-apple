# use-apple

**One file drives your Apple device.** `use-apple.sh` turns an iPhone, an iPad or a simulator into a small HTTP API that an agent can see and operate. There's no Xcode project, no dependencies, and nothing to install beyond Xcode.

```sh
./use-apple.sh              # the USB-connected device
./use-apple.sh <sim-udid>   # a simulator
```

```sh
curl localhost:8100/ui                                              # what's on screen, as compact JSON
curl -d '{"bundleId":"com.apple.Preferences"}' localhost:8100/launch
curl -d '{"using":"id","value":"com.apple.settings.bluetooth"}' localhost:8100/tap
```

## How it works

The script contains everything it needs:

- an XCUITest server in Objective-C, compiled with `clang` into Xcode's own `XCTRunner.app`;
- signing that finds a provisioning profile covering the device and a matching certificate in your keychain;
- USB port forwarding through macOS's `usbmuxd`.

It then starts the runner with `xcodebuild test-without-building`. The server only listens on loopback: on a device you reach it through USB, and on a simulator from your Mac.

## API

| Route | Body | Returns |
|---|---|---|
| `GET /status` | | `{ready, app}` |
| `GET /ui` | | `{app, screen:[w,h], elements:[{type, label?, id?, value?, placeholder?, selected?, disabled?, rect:[x,y,w,h]}]}` |
| `GET /screenshot` | | `{png}` (base64) |
| `POST /launch` | `{bundleId, args?, env?}` | launches the app and attaches to it |
| `POST /app` | `{bundleId}` | activates an app and attaches to it |
| `POST /terminate` | `{bundleId}` | |
| `POST /tap` | `{x, y}` or `{using, value}` | `using` is `"id"` (identifier or label) or `"predicate"` (an NSPredicate) |
| `POST /longpress` | `{x, y, duration}` | |
| `POST /swipe` | `{x1, y1, x2, y2, duration?}` | |
| `POST /type` | `{text, using?, value?}` | |
| `POST /find` | `{using, value, timeout?}` | `{frame, label, identifier, value, enabled}` |
| `POST /home` | | |
| `POST /quit` | | ends the session |

Coordinates are in points. Responses are wrapped as `{"value": ...}`, or `{"error": ...}` on failure. Read the screen with `/ui` and keep `/screenshot` for screens with poor accessibility labels.

To stop a session from the device, open the **Use ** app and tap **Stop Automation**.

## Real devices

You need:

- an Apple Development certificate and a provisioning profile that includes the device. A free Apple ID works, but its profiles expire after 7 days.
- Developer Mode turned on, plus Settings → Developer → Enable UI Automation.

The script picks the profile and identity automatically. To choose them yourself, set `WDA_SIGN_IDENTITY`, `WDA_PROFILE` and `WDA_BUNDLE_ID` (default `com.example.useapple`).
