# use-apple

One file drives your Apple device. It gives agents an HTTP API for operating an iPhone, an iPad or a simulator, and needs nothing but Xcode.

```sh
./use-apple.sh              # the USB-connected device
./use-apple.sh <sim-udid>   # a simulator

curl localhost:8100/ui      # what's on screen, as JSON
curl -d '{"bundleId":"com.apple.Preferences"}' localhost:8100/launch
curl -d '{"using":"id","value":"com.apple.settings.bluetooth"}' localhost:8100/tap
```

**API:**

- `GET /status`, `/ui`, `/screenshot`
- `POST /launch`, `/app`, `/terminate`, `/tap`, `/longpress`, `/swipe`, `/type`, `/find`, `/screenshot`, `/home`, `/quit`

Each route is documented at the top of the embedded server code.

**Devices** need a development profile that includes the device, plus Developer Mode and UI Automation turned on. The script finds the profile and certificate on its own. To stop a session from the device, open **Use ** and tap **Stop Automation**.
