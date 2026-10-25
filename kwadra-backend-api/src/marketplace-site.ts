import type { Express, Response } from "express";
import express from "express";
import type pg from "pg";
import { randomBytes } from "node:crypto";
import path from "node:path";
import { z } from "zod";
import { root } from "./config.js";
import { transaction } from "./db.js";
import {
  publicSearch,
  publicListing,
  publicJoins,
  eligible,
} from "./marketplace.js";
import { ApiError } from "./errors.js";

const esc = (v: unknown) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
const pesos = (v: number) =>
  new Intl.NumberFormat("en-PH", { style: "currency", currency: "PHP" }).format(
    v / 100,
  );
const origin = () => process.env.PUBLIC_ORIGIN ?? "http://localhost:3000";
function page(
  res: Response,
  title: string,
  content: string,
  options: {
    description?: string;
    path?: string;
    noindex?: boolean;
    structured?: unknown;
  } = {},
) {
  const nonce = randomBytes(16).toString("base64"),
    description =
      options.description ??
      "Find an available rental and contact its publisher through Kwadra.";
  res.setHeader(
    "Content-Security-Policy",
    `default-src 'self'; script-src 'self' 'nonce-${nonce}'; style-src 'self'; img-src 'self' data:; font-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`,
  );
  res.setHeader("Cache-Control", "no-store");
  if (options.noindex) res.setHeader("X-Robots-Tag", "noindex, nofollow");
  res
    .type("html")
    .send(
      `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)} · Kwadra</title><meta name="description" content="${esc(description)}"><link rel="canonical" href="${esc(origin() + (options.path ?? "/marketplace"))}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(description)}"><meta property="og:type" content="website">${options.noindex ? '<meta name="robots" content="noindex,nofollow">' : ""}<link rel="icon" href="/marketplace/assets/kwadra-logo.png"><link rel="stylesheet" href="/marketplace/assets/style.css">${options.structured ? `<script nonce="${nonce}" type="application/ld+json">${JSON.stringify(options.structured).replaceAll("<", "\\u003c")}</script>` : ""}<script type="module" src="/marketplace/assets/marketplace.js"></script></head><body><header><nav class="nav"><a class="brand" href="/marketplace"><img src="/marketplace/assets/kwadra-logo.png" alt="">kwadra.</a><div class="nav-links"><a href="/marketplace">Find a rental</a><a href="/marketplace/saved">Saved</a><a class="extra quiet" href="/">Manage rentals</a></div></nav></header>${content}<footer><div class="container"><span>A place for your next chapter.</span><span>Kwadra · Philippine rentals</span></div></footer></body></html>`,
    );
}
const photo = (l: any) =>
  l.photos.length
    ? "/api/v1/public/photos/" + l.photos[0]
    : "/marketplace/assets/" + l.image + ".jpg";
const card = (l: any) =>
  `<a class="card" href="/marketplace/listings/${l.id}"><img class="cover" src="${photo(l)}" alt="${esc(l.title)}" loading="lazy" width="640" height="450"><div class="card-body"><span class="tag">Available rental</span><h3>${esc(l.title)}</h3><div class="location">${esc(l.locationLabel)}</div><div class="price">${pesos(l.rent)} <span>/ month</span></div><div class="facts">${esc(l.type)} &nbsp; · &nbsp; Up to ${l.capacity} residents</div></div></a>`;
function price(value: unknown) {
  if (value === undefined || value === "") return undefined;
  const v = String(value);
  if (!/^\d{1,10}(\.\d{1,2})?$/.test(v))
    throw new ApiError(422, "Enter a valid price in pesos.");
  const [a, b = ""] = v.split(".");
  return Number(a) * 100 + Number(b.padEnd(2, "0"));
}
export function marketplaceSite(app: Express, pool: pg.Pool) {
  app.use(
    "/marketplace/assets",
    express.static(path.join(root, "../apps/marketplace/public")),
  );
  app.use(
    "/marketplace/assets",
    express.static(path.join(root, "../apps/management/assets/branding")),
  );
  app.use(
    "/marketplace/assets",
    express.static(path.join(root, "../apps/management/assets/fonts")),
  );
  app.use(
    "/marketplace/assets",
    express.static(path.join(root, "../apps/management/assets/images")),
  );
  app.get("/marketplace", async (req, res) => {
    const source = req.query;
    const query: Record<string, unknown> = {};
    for (const k of ["q", "type", "capacity", "amenity", "sort", "page"])
      if (source[k] !== undefined && source[k] !== "") query[k] = source[k];
    for (const k of ["minRent", "maxRent", "maxMoveInCost"]) {
      const amount = price(source[k]);
      if (amount !== undefined) query[k] = amount;
    }
    const result = await transaction(pool, (db) => publicSearch(db, query));
    const amenities = (
      await pool.query("SELECT id,name FROM amenities ORDER BY name")
    ).rows;
    const field = (name: string, label: string) =>
      `<div><label for="${name}">${label}</label><input id="${name}" name="${name}" inputmode="decimal" value="${esc(source[name] ?? "")}" placeholder="PHP"></div>`;
    const types = ["Studio", "1 Bedroom", "2 Bedroom", "Room", "House"];
    const next = (page: number) => {
      const p = new URLSearchParams();
      for (const [key, v] of Object.entries(source))
        if (typeof v === "string") p.set(key, v);
      p.set("page", String(page));
      return "/marketplace?" + p;
    };
    page(
      res,
      "Find a place that fits",
      `<main><section class="hero"><div class="container"><div class="eyebrow">Room for what comes next</div><h1>Find a place<br>that feels like yours.</h1><p>Explore available homes, understand the move-in costs, and start a conversation with the landlord.</p><form class="search" action="/marketplace" method="get"><div class="search-row"><div><label for="q">Where would you like to live?</label><input id="q" name="q" value="${esc(source.q ?? "")}" placeholder="City, neighborhood or rental name"></div><div><label for="type">Space</label><select id="type" name="type"><option value="">Any type</option>${types.map((t) => `<option ${source.type === t ? "selected" : ""}>${t}</option>`).join("")}</select></div><button type="submit">Find a place</button></div><details><summary>Price, amenities & more</summary><div class="filters">${field("minRent", "Minimum monthly rent")}${field("maxRent", "Maximum monthly rent")}${field("maxMoveInCost", "Maximum move-in cost")}<div><label for="capacity">Residents</label><input id="capacity" name="capacity" type="number" min="1" max="20" value="${esc(source.capacity ?? "")}" placeholder="Any capacity"></div><div><label for="amenity">Amenity</label><select id="amenity" name="amenity"><option value="">Any amenity</option>${amenities.map((a) => `<option value="${a.id}" ${source.amenity === a.id ? "selected" : ""}>${esc(a.name)}</option>`).join("")}</select></div><div><label for="sort">Sort by</label><select id="sort" name="sort"><option value="newest">Newest first</option><option value="rent_asc" ${source.sort === "rent_asc" ? "selected" : ""}>Lowest rent</option><option value="rent_desc" ${source.sort === "rent_desc" ? "selected" : ""}>Highest rent</option></select></div></div></details></form></div></section><section class="section container"><div class="section-head"><h2>Make yourself at home</h2><span class="count">${result.total} available ${result.total === 1 ? "rental" : "rentals"}</span></div>${result.data.length ? `<div class="grid">${result.data.map(card).join("")}</div>` : '<div class="empty"><h2>No rentals match just yet.</h2><p>Try a nearby area or adjust your filters.</p><a class="link" href="/marketplace">See all rentals</a></div>'}<div class="pager">${result.page > 1 ? `<a href="${esc(next(result.page - 1))}">Previous</a>` : ""}${result.page * result.pageSize < result.total ? `<a href="${esc(next(result.page + 1))}">Next</a>` : ""}</div></section></main>`,
    );
  });
  app.get("/marketplace/listings/:id", async (req, res) => {
    let l: any;
    try {
      l = await transaction(pool, (db) =>
        publicListing(db, z.uuid().parse(req.params.id)),
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) {
        res.status(404);
        page(
          res,
          "Rental unavailable",
          '<main class="section container"><div class="empty"><h1>This rental is no longer available.</h1><a class="button" href="/marketplace">Find another place</a></div></main>',
          { noindex: true },
        );
        return;
      }
      throw e;
    }
    const images = l.photos.length
      ? l.photos.map((id: string) => "/api/v1/public/photos/" + id)
      : [photo(l)];
    page(
      res,
      l.title,
      `<main class="detail container"><a class="back" href="/marketplace">← All available rentals</a><div class="detail-layout"><article><span class="tag">Available · Publisher reviewed</span><h1>${esc(l.title)}</h1><div class="location">${esc(l.locationLabel)} · ${esc(l.locationPrecision)} location disclosure</div><div class="gallery">${images.map((src: string, i: number) => `<img src="${src}" alt="${esc(l.title)} — photo ${i + 1}" ${i ? 'loading="lazy"' : ""} width="900" height="600">`).join("")}</div><div class="panel"><h2>A little about this place</h2><div class="chips"><span class="chip">${esc(l.type)}</span><span class="chip">Up to ${l.capacity} residents</span>${l.amenities.map((a: any) => `<span class="chip">${esc(a.name)}</span>`).join("")}</div><p class="prose">${esc(l.description)}</p></div>${l.houseRules ? `<div class="panel"><h2>House rules</h2><div class="prose">${esc(l.houseRules)}</div></div>` : ""}<div class="panel"><h2>Publisher review</h2><p class="muted">This publisher's submitted documentation was reviewed. This label describes that review; it does not guarantee a rental or replace your own viewing and agreement.</p><div class="actions"><button type="button" class="outline" data-save="${l.id}">Save rental</button><button type="button" class="outline" data-share>Share</button></div><details><summary>Report this listing</summary><form id="report-form" data-listing="${l.id}"><div class="form-field"><label for="reason">What should we review?</label><textarea id="reason" name="reason" required minlength="10" maxlength="2000" rows="3"></textarea></div><button type="submit" class="outline">Send report</button><div class="status" role="status"></div></form></details></div></article><aside class="aside"><div class="panel"><div class="price">${pesos(l.rent)} <span>/ month</span></div><div class="row"><span>Advertised move-in cost</span><strong>${pesos(l.moveInCost)}</strong></div><p class="fineprint">Confirm the complete rental terms and any additional costs with the landlord.</p>${l.publicPhone || l.publicEmail ? `<div class="notice">Public contact: ${esc(l.publicPhone)} ${esc(l.publicEmail)}</div>` : ""}<h2>Start a conversation</h2><form id="inquiry-form" data-listing="${l.id}"><div class="form-field"><label for="name">Your name</label><input id="name" name="name" required maxlength="120" autocomplete="name"></div><div class="form-field"><label for="email">Email address</label><input id="email" name="email" type="email" required maxlength="254" autocomplete="email"></div><div class="form-field"><label for="phone">Phone (optional)</label><input id="phone" name="phone" type="tel" maxlength="60" autocomplete="tel"></div><div class="form-field"><label for="message">Your message</label><textarea id="message" name="message" required minlength="10" maxlength="3000" rows="3" placeholder="Tell the landlord a little about what you're looking for."></textarea></div><details><summary>Request a viewing (optional)</summary><div class="form-field"><label for="viewingAt">Your preferred date and time</label><input id="viewingAt" name="viewingAt" type="datetime-local"></div></details><div class="hp" aria-hidden="true"><label>Website<input name="website" tabindex="-1" autocomplete="off"></label></div><p class="muted">Your contact details are shared with this rental's authorized landlord team. A viewing needs confirmation.</p><button class="full" type="submit">Send inquiry</button><div class="status" role="status"></div></form></div></aside></div></main>`,
      {
        description: l.description.slice(0, 155),
        path: "/marketplace/listings/" + l.id,
        structured: {
          "@context": "https://schema.org",
          "@type": "RealEstateListing",
          name: l.title,
          description: l.description,
          url: origin() + "/marketplace/listings/" + l.id,
          datePosted: l.published,
          image: images.map((s: string) => origin() + s),
        },
      },
    );
  });
  app.get("/marketplace/saved", (_req, res) =>
    page(
      res,
      "Your saved rentals",
      '<main class="section container"><div class="section-head"><h1>Your saved rentals</h1></div><p class="muted">Saved on this browser. Availability is checked each time you open this page.</p><div class="grid" id="saved-list"></div></main>',
      { noindex: true },
    ),
  );
  app.get("/marketplace/track/:id", (req, res) => {
    const id = z.uuid().parse(req.params.id);
    page(
      res,
      "Your rental inquiry",
      `<main class="track" data-track="${id}"><a class="back" href="/marketplace">← Browse rentals</a><h1 id="track-title">Your rental inquiry</h1><p id="track-state"></p><div class="status error" id="track-error" role="alert"></div><div class="panel" id="messages"></div><form class="panel" id="reply-form"><label for="reply-message">Reply to the landlord</label><textarea id="reply-message" name="message" required maxlength="3000" rows="3"></textarea><p></p><button type="submit">Send reply</button><div class="status" role="status"></div></form><h2>Viewings</h2><div id="viewings"></div><form class="panel" id="viewing-form"><label for="scheduledAt">Request another viewing time</label><input type="datetime-local" id="scheduledAt" name="scheduledAt" required><p class="muted">Only one active viewing request at a time. A request is not a confirmed appointment.</p><button type="submit" class="outline">Request viewing</button><div class="status" role="status"></div></form></main>`,
      { noindex: true },
    );
  });
  app.get("/sitemap.xml", async (_req, res) => {
    const rows = (
      await pool.query(
        `SELECT l.id,l.updated_at ${publicJoins} WHERE ${eligible}`,
      )
    ).rows;
    res
      .type("application/xml")
      .send(
        `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${esc(origin())}/marketplace</loc></url>${rows.map((r) => `<url><loc>${esc(origin())}/marketplace/listings/${r.id}</loc><lastmod>${r.updated_at.toISOString()}</lastmod></url>`).join("")}</urlset>`,
      );
  });
  app.get("/robots.txt", (_req, res) =>
    res
      .type("text")
      .send(
        `User-agent: *\nAllow: /marketplace\nDisallow: /marketplace/track/\nDisallow: /api/\nDisallow: /docs\nSitemap: ${origin()}/sitemap.xml\n`,
      ),
  );
}
