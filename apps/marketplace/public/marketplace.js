const $ = (s) => document.querySelector(s);
const money = (n) =>
  new Intl.NumberFormat("en-PH", { style: "currency", currency: "PHP" }).format(
    n / 100,
  );
const saved = () => {
  try {
    return JSON.parse(
      localStorage.getItem("kwadra.saved.listings") ?? "[]",
    ).filter((v) => typeof v === "string" && /^[a-f0-9-]{36}$/.test(v));
  } catch {
    return [];
  }
};
const api = async (path, body, token) => {
  const response = await fetch("/api/v1/public" + path, {
    method: body ? "POST" : "GET",
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(token ? { "X-Inquiry-Token": token } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await response.json();
  if (!response.ok)
    throw Error(data.error?.message ?? "The request failed. Please try again.");
  return data;
};
function status(form, text, error = false) {
  const node = form.querySelector(".status");
  node.textContent = text;
  node.classList.toggle("error", error);
}
function button(text, action) {
  const b = document.createElement("button");
  b.textContent = text;
  b.type = "button";
  b.className = "outline";
  b.addEventListener("click", action);
  return b;
}
const favorite = $("[data-save]");
if (favorite) {
  const id = favorite.dataset.save;
  const update = () => {
    favorite.textContent = saved().includes(id) ? "Saved" : "Save rental";
    favorite.setAttribute("aria-pressed", String(saved().includes(id)));
  };
  update();
  favorite.addEventListener("click", () => {
    const ids = saved(),
      next = ids.includes(id) ? ids.filter((v) => v !== id) : [...ids, id];
    localStorage.setItem("kwadra.saved.listings", JSON.stringify(next));
    update();
  });
}
$("[data-share]")?.addEventListener("click", async () => {
  try {
    if (navigator.share)
      await navigator.share({ title: document.title, url: location.href });
    else {
      await navigator.clipboard.writeText(location.href);
      $("[data-share]").textContent = "Link copied";
    }
  } catch {}
});
const inquiry = $("#inquiry-form");
inquiry?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = inquiry.querySelector("button[type=submit]");
  submit.disabled = true;
  try {
    const fields = Object.fromEntries(new FormData(inquiry));
    if (fields.viewingAt)
      fields.viewingAt = new Date(fields.viewingAt).toISOString();
    else delete fields.viewingAt;
    const result = await api(
        `/listings/${inquiry.dataset.listing}/inquiries`,
        fields,
      ),
      link = `/marketplace/track/${result.id}#${result.trackingToken}`;
    status(inquiry, result.message + " Keep your private tracking link.");
    const a = document.createElement("a");
    a.href = link;
    a.textContent = "Open your inquiry";
    a.className = "button full";
    inquiry.querySelector(".status").append(document.createElement("br"), a);
    for (const input of inquiry.querySelectorAll("input,textarea"))
      input.disabled = true;
  } catch (error) {
    status(inquiry, error.message, true);
    submit.disabled = false;
  }
});
const report = $("#report-form");
report?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const b = report.querySelector("button");
  b.disabled = true;
  try {
    const r = await api(
      `/listings/${report.dataset.listing}/report`,
      Object.fromEntries(new FormData(report)),
    );
    status(report, r.message);
  } catch (e) {
    status(report, e.message, true);
    b.disabled = false;
  }
});
if ($("#saved-list")) {
  const target = $("#saved-list"),
    ids = saved();
  target.textContent = ids.length
    ? "Loading your saved rentals…"
    : "No saved rentals yet. Open a rental and choose Save rental.";
  const results = await Promise.allSettled(
    ids.map((id) => api("/listings/" + id)),
  );
  target.textContent = "";
  for (const result of results)
    if (result.status === "fulfilled") {
      const l = result.value.data,
        a = document.createElement("a");
      a.className = "card";
      a.href = "/marketplace/listings/" + l.id;
      const img = document.createElement("img");
      img.className = "cover";
      img.src = l.photos.length
        ? "/api/v1/public/photos/" + l.photos[0]
        : "/marketplace/assets/" + l.image + ".jpg";
      img.alt = l.title;
      img.loading = "lazy";
      const body = document.createElement("div");
      body.className = "card-body";
      const title = document.createElement("h3");
      title.textContent = l.title;
      const location = document.createElement("p");
      location.className = "location";
      location.textContent = l.locationLabel;
      const price = document.createElement("p");
      price.className = "price";
      price.textContent = money(l.rent);
      body.append(title, location, price);
      a.append(img, body);
      target.append(a);
    }
  if (!target.children.length)
    target.textContent =
      "Your saved rentals are currently unavailable. Browse for another place.";
}
const track = $("[data-track]");
if (track) {
  const id = track.dataset.track,
    token = location.hash.slice(1);
  let last;
  const refresh = async () => {
    try {
      last = await api("/inquiries/" + id, undefined, token);
      $("#track-title").textContent = last.title;
      $("#track-state").textContent = "Inquiry: " + last.status;
      const messages = $("#messages");
      messages.textContent = "";
      for (const m of last.messages) {
        const row = document.createElement("div");
        row.className = "message";
        const who = document.createElement("strong");
        who.textContent = m.sender === "seeker" ? "You" : "Landlord";
        const text = document.createElement("p");
        text.textContent = m.body;
        row.append(who, text);
        messages.append(row);
      }
      const viewings = $("#viewings");
      viewings.textContent = "";
      for (const v of last.viewings) {
        const row = document.createElement("div");
        row.className = "panel";
        const p = document.createElement("p");
        p.textContent = `${new Date(v.scheduledAt).toLocaleString()} · ${v.status}`;
        row.append(p);
        if (v.status === "proposed")
          row.append(
            button("Confirm proposed time", async () => {
              try {
                await api(
                  "/inquiries/" + id + "/viewings",
                  { id: v.id, revision: v.revision, action: "confirm" },
                  token,
                );
                await refresh();
              } catch (e) {
                alert(e.message);
              }
            }),
          );
        if (["requested", "proposed", "confirmed"].includes(v.status))
          row.append(
            button("Cancel viewing", async () => {
              try {
                await api(
                  "/inquiries/" + id + "/viewings",
                  { id: v.id, revision: v.revision, action: "cancel" },
                  token,
                );
                await refresh();
              } catch (e) {
                alert(e.message);
              }
            }),
          );
        viewings.append(row);
      }
      $("#track-error").textContent = "";
      $("#reply-form").classList.toggle("hidden", last.status === "closed");
    } catch (e) {
      $("#track-error").textContent = e.message;
      $("#reply-form").classList.add("hidden");
    }
  };
  await refresh();
  $("#reply-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.currentTarget,
      b = form.querySelector("button");
    b.disabled = true;
    try {
      await api(
        "/inquiries/" + id + "/messages",
        { message: form.elements.message.value },
        token,
      );
      form.reset();
      await refresh();
    } catch (e) {
      status(form, e.message, true);
    } finally {
      b.disabled = false;
    }
  });
  $("#viewing-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.currentTarget,
      b = form.querySelector("button");
    b.disabled = true;
    try {
      await api(
        "/inquiries/" + id + "/viewings",
        {
          action: "request",
          scheduledAt: new Date(form.elements.scheduledAt.value).toISOString(),
        },
        token,
      );
      form.reset();
      await refresh();
    } catch (e) {
      status(form, e.message, true);
    } finally {
      b.disabled = false;
    }
  });
}
