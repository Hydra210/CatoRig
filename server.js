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

// catalog.roblox.com rate-limits (429) more aggressively than you'd expect,
// especially from a shared-IP host like Render. One retry with a short
// backoff smooths over the occasional transient hit; it won't help if
// Roblox is rate-limiting the host IP itself for an extended stretch.
const MAX_RETRIES = 1;
const RETRY_DELAY_MS = 1200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchWithRetry(url) {
	let lastResult = null;
	for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
		const upstream = await fetch(url, { headers: UPSTREAM_HEADERS, signal: AbortSignal.timeout(10_000) });
		const body = await upstream.text();
		lastResult = { upstream, body };

		if (upstream.status !== 429) {
			return lastResult;
		}
		if (attempt < MAX_RETRIES) {
			console.warn(`[catorig-proxy] 429, retrying in ${RETRY_DELAY_MS}ms — ${url}`);
			await sleep(RETRY_DELAY_MS);
		}
	}
	return lastResult;
}

app.get("/catalog", async (req, res) => {
	const { AssetTypeId, ...rest } = req.query;

	try {
		if (AssetTypeId) {
			return await handleFilteredSearch(res, AssetTypeId, rest);
		}

		const query = new URLSearchParams(rest).toString();
		const url = `https://catalog.roblox.com/v1/search/items/details?${query}`;
		const { upstream, body } = await fetchWithRetry(url);

		if (!upstream.ok) {
			console.error(`[catorig-proxy] upstream ${upstream.status} for ${url}`);
			console.error(`[catorig-proxy] upstream body: ${body.slice(0, 500)}`);
			return res.status(upstream.status).type("application/json").send(body);
		}

		res.type("application/json").send(body);
	} catch (err) {
		console.error(`[catorig-proxy] request failed:`, err);
		res.status(502).json({ error: "proxy request failed", detail: String(err) });
	}
});

// Workaround for item types Roblox's Subcategory filter rejects outright
// (Hats, Hair, Faces, Shirts, Pants, T-Shirts — see the comment on
// CategoryDef.AssetTypeId in CatoRig.lua). Searches broadly by Category
// alone, then filters the results by each item's own assetType field.
// Since most results in a broad search won't match, this chains multiple
// upstream requests (following the cursor) until it collects enough
// matches or runs out of pages.
const FILTER_TARGET_COUNT = 24;
const FILTER_MAX_UPSTREAM_PAGES = 6;
const FILTER_PAGE_DELAY_MS = 350;

function extractAssetTypeId(item) {
	const t = item && item.assetType;
	if (t && typeof t === "object") {
		return t.id;
	}
	return t;
}

async function handleFilteredSearch(res, assetTypeId, baseParams) {
	let cursor = baseParams.Cursor;
	const searchParams = { ...baseParams };
	delete searchParams.Cursor;

	const collected = [];
	let nextCursor = null;
	let loggedSampleKeys = false;

	for (let page = 0; page < FILTER_MAX_UPSTREAM_PAGES; page++) {
		const params = new URLSearchParams(searchParams);
		if (cursor) {
			params.set("Cursor", cursor);
		}
		const url = `https://catalog.roblox.com/v1/search/items/details?${params.toString()}`;
		const { upstream, body } = await fetchWithRetry(url);

		if (!upstream.ok) {
			console.error(`[catorig-proxy] filtered search upstream ${upstream.status} for ${url}`);
			console.error(`[catorig-proxy] upstream body: ${body.slice(0, 500)}`);
			if (collected.length === 0) {
				return res.status(upstream.status).type("application/json").send(body);
			}
			break;
		}

		let parsed;
		try {
			parsed = JSON.parse(body);
		} catch (err) {
			console.error(`[catorig-proxy] bad JSON in filtered search — ${url}`);
			break;
		}

		const data = parsed.data || [];
		if (!loggedSampleKeys && data[0]) {
			// One-time debug line — if filtering keeps returning 0 matches,
			// check this against extractAssetTypeId() above: the field name
			// or shape may not be what's assumed here.
			console.log(`[catorig-proxy] sample item keys: ${Object.keys(data[0]).join(", ")}`);
			console.log(`[catorig-proxy] sample assetType value: ${JSON.stringify(data[0].assetType)}`);
			loggedSampleKeys = true;
		}

		for (const item of data) {
			if (String(extractAssetTypeId(item)) === String(assetTypeId)) {
				collected.push(item);
			}
		}

		nextCursor = parsed.nextPageCursor || null;
		cursor = nextCursor;

		if (!nextCursor || collected.length >= FILTER_TARGET_COUNT) {
			break;
		}
		await sleep(FILTER_PAGE_DELAY_MS);
	}

	console.log(`[catorig-proxy] filtered search: ${collected.length} matches for AssetTypeId=${assetTypeId}`);
	res.json({ data: collected, nextPageCursor: cursor || undefined });
}

app.get("/", (_req, res) => {
	res.send("CatoRig proxy is running. Point the plugin's CFG.ProxyBaseUrl here.");
});

app.listen(PORT, () => {
	console.log(`[catorig-proxy] listening on http://localhost:${PORT}`);
});
