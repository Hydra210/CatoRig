# CatoRig

A Roblox Studio plugin (`plugin/CatoRig.lua`) for browsing the avatar catalog,
customizing a body, and inserting a finished R6/R15 rig — plus the tiny proxy
server (`server.js`) it needs, since Roblox blocks `HttpService` from reaching
`*.roblox.com` directly, from both games and plugins.

## Deploy the proxy on Render

1. Push this repo to GitHub.
2. In Render: **New → Blueprint**, point it at this repo. `render.yaml` sets
   everything up (Node web service, `npm install`, `node server.js`).
   - No blueprint? **New → Web Service** instead, same repo, and Render will
     auto-detect the Node app from `package.json`.
3. Once it's deployed, copy the `.onrender.com` URL Render gives the service.

## Point the plugin at it

Open `plugin/CatoRig.lua`, find this near the top of `CFG`:

```lua
ProxyBaseUrl = "http://localhost:3000",
```

Replace it with your Render URL (no trailing slash):

```lua
ProxyBaseUrl = "https://catorig-proxy-xxxx.onrender.com",
```

Then in Studio: paste the file into a Script and **Save as Local Plugin**
(right-click the script in the Explorer → Plugins → Save as Local Plugin).

## Running the proxy locally instead

```
npm install
node server.js
```

Listens on `localhost:3000` — useful while you're iterating, since local
Studio plugins reach `localhost` fine without deploying anything.

## Notes

- Render's free tier spins down after inactivity — the first catalog request
  after a while idle will be slow (cold start) while it wakes back up.
- If a category tab in Studio comes back empty, the plugin's status line
  will say why (bad response from the proxy, bad response from Roblox,
  etc.) — check the Render service logs too.
- `CFG.Categories` in `CatoRig.lua` is the single place to fix things if
  Roblox ever reshuffles catalog category/subcategory numbers again — it's
  happened before.
