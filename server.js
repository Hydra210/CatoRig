// CatoRig proxy
//
// Roblox blocks HttpService from reaching *.roblox.com — from both games
// and plugins. This tiny server is the standard workaround: the plugin
// talks to this server instead, and this server (running outside Roblox's
// sandbox) makes the real call to catalog.roblox.com on its behalf.
//
// Run locally while you're building:
//   npm install
//   node server.js
// Then point CFG.ProxyBaseUrl in CatoRig.lua at "http://localhost:3000".
//
// Deploy it somewhere (Render, Railway, Fly.io, a $5 VPS — anything that
// can run Node) once you want CatoRig to work without you personally
// running this server, and point CFG.ProxyBaseUrl at that URL instead.

const express = require("express");

const app = express();
const PORT = process.env.PORT || 3000;

// Roblox occasionally blocks requests with no User-Agent / a Node default
// one, so we set something browser-like.
const UPSTREAM_HEADERS = {
	"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
	"Accept": "application/json",
};

app.get("/catalog", async (req, res) => {
	const query = new URLSearchParams(req.query).toString();
	const url = `https://catalog.roblox.com/v1/search/items/details?${query}`;

	try {
		const upstream = await fetch(url, { headers: UPSTREAM_HEADERS, signal: AbortSignal.timeout(10_000) });
		const body = await upstream.text();

		if (!upstream.ok) {
			console.error(`[catorig-proxy] upstream ${upstream.status} for ${url}`);
			return res.status(upstream.status).type("application/json").send(body);
		}

		res.type("application/json").send(body);
	} catch (err) {
		console.error(`[catorig-proxy] request failed for ${url}:`, err);
		res.status(502).json({ error: "proxy request failed", detail: String(err) });
	}
});

app.get("/", (_req, res) => {
	res.send("CatoRig proxy is running. Point the plugin's CFG.ProxyBaseUrl here.");
});

app.listen(PORT, () => {
	console.log(`[catorig-proxy] listening on http://localhost:${PORT}`);
});
