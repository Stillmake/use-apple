# use-apple

One file drives your Apple device. It gives agents an HTTP API for operating an iPhone, an iPad or a simulator, and needs nothing but Xcode.

Just download the one file. You don't need to clone the repo:

```sh
curl -O https://raw.githubusercontent.com/Stillmake/use-apple/main/use-apple.sh
chmod +x use-apple.sh
```

Then:

```sh
./use-apple.sh              # the USB-connected device
./use-apple.sh <sim-udid>   # a simulator

curl localhost:8100/ui      # what's on screen, as JSON
curl -d '{"bundleId":"com.apple.Preferences"}' localhost:8100/launch
curl -d '{"id":"com.apple.settings.bluetooth"}' localhost:8100/tap
curl -d '{"direction":"down","until":{"label":"Fonts"}}' localhost:8100/scroll
```

**API:**

- `GET /ui`, `/screenshot`
- `POST /launch`, `/app`, `/terminate`, `/find`, `/wait`, `/tap`, `/longpress`, `/swipe`, `/scroll`, `/type`, `/screenshot`, `/home`, `/lock`

Elements are located by one of `{id}`, `{label}` or `{predicate}`, and every route describes them in the same shape as `/ui`. Gestures take an element or a point `{x, y}`.

These routes live in the `ROUTES` block of `use-apple.sh`, documented at its top. The script pushes that block to the running server on start and whenever a save changes it, so a route is added, changed or deleted by editing the script while it runs, with no rebuild. Routes are JavaScript and reach any Objective-C API through `send(target, selector, ...args)`:

```js
'POST /orientation'(b) { send(send('XCUIDevice', 'sharedDevice'), 'setOrientation:', b.value); },
```

The runner itself keeps only `GET /status`, `POST /routes` (replace all routes with a JS source), `POST /eval` (run JS in the routes' context, for one-offs) and `POST /quit`, documented at the top of the embedded server code.

**Devices** need a development profile that includes the device, plus Developer Mode and UI Automation turned on. The script finds the profile and certificate on its own. To stop a session from the device, open **Use ** and tap **Stop Automation**.
