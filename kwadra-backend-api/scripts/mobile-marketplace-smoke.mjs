// Run against scripts/browser-server.ts for an isolated, mail-free browser check.
import { resolve } from "node:path";
import { writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { openBrowser } from "./qa-browser.mjs";
const base = process.env.KWADRA_TEST_URL ?? "http://127.0.0.1:3001",
  output = resolve(".local/mobile-marketplace-smoke");
const listing = (await (await fetch(base + "/api/v1/public/listings")).json())
  .data[0];
if (!listing) throw new Error("No public QA listing is available.");
const browser = await openBrowser(output);
const { wait, click, fill, screenshot, evaluate } = browser;
async function signIn(email) {
  await click("Account");
  await click("Sign in", "button");
  await wait("Welcome back");
  await fill("Email address", email);
  await fill("Password", "KwadraDemo!2026");
  await click("Sign in", "button");
}
async function ownerApi(path, body, session) {
  const r = await fetch(base + "/api/v1" + path, {
    method: body ? "POST" : "GET",
    headers: {
      "Content-Type": "application/json",
      ...(session
        ? {
            Authorization: "Bearer " + session.token,
            "X-Organization-Id": session.organizations[0].id,
            "Idempotency-Key": randomUUID(),
          }
        : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await r.json();
  if (!r.ok) throw Error(data.error?.message ?? "Owner API failed.");
  return data;
}
try {
  await browser.metrics(1440, 1050);
  await browser.open(base);
  await wait("Find your next home.");
  await wait(listing.title);
  await browser.delay(1000);
  await screenshot("marketplace-desktop");
  if (browser.requests.some((r) => r.method === "POST"))
    throw Error("Cold launch unexpectedly performed a mutation.");
  await browser.metrics(390, 950);
  await screenshot("marketplace-phone");
  await click(listing.title, "button");
  await wait("Rental details");
  await screenshot("rental-details");
  await click("Message landlord", "button");
  await wait("Welcome back");
  await screenshot("sign-in-gate");
  await click("Back", "button");
  await wait("Rental details");
  if (
    browser.requests.some(
      (r) => r.method === "POST" && r.path.endsWith("/inquiries"),
    )
  )
    throw Error("Guest inquiry was sent.");
  await click("Message landlord", "button");
  await wait("Welcome back");
  await fill("Email address", "renter@example.com");
  await fill("Password", "KwadraDemo!2026");
  await click("Sign in", "button");
  await wait("Send inquiry");
  await fill("Your message", "Native marketplace browser acceptance inquiry.");
  await click("Send inquiry", "button");
  await wait("Conversation");
  await screenshot("conversation");
  await click("Request a viewing", "button");
  await wait("OK");
  await click("OK", "button");
  await browser.delay(300);
  await click("OK", "button");
  await wait("Waiting for landlord confirmation.");
  const inquiry = (
    await evaluate(
      "fetch('/api/v1/marketplace/inquiries',{credentials:'include'}).then(r=>r.json())",
    )
  ).data[0];
  const owner = await ownerApi("/auth/login", {
    email: "alex@example.com",
    password: "KwadraDemo!2026",
    client: "native",
  });
  await ownerApi(
    "/inquiries/" + inquiry.id + "/reply",
    { revision: 1, message: "Yes, please confirm the proposed viewing time." },
    owner,
  );
  let thread = await evaluate(
    `fetch('/api/v1/marketplace/inquiries/${inquiry.id}',{credentials:'include'}).then(r=>r.json())`,
  );
  const v = thread.viewings[0];
  const changed = await fetch(base + "/api/v1/viewings/" + v.id, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer " + owner.token,
      "X-Organization-Id": owner.organizations[0].id,
      "Idempotency-Key": randomUUID(),
    },
    body: JSON.stringify({
      revision: v.revision,
      status: "proposed",
      scheduledAt: new Date(Date.now() + 2 * 86400000).toISOString(),
    }),
  });
  if (!changed.ok) throw Error("Could not propose a viewing.");
  await click("Refresh conversation", "button");
  await wait("Confirm proposed time");
  await click("Confirm proposed time", "button");
  await wait("confirmed");
  await fill(
    "Reply to landlord",
    "Confirmed. Thank you for the viewing proposal.",
  );
  await click("Send reply", "button");
  await wait("Confirmed. Thank you for the viewing proposal.");
  await screenshot("viewing-confirmed");
  await click("Back", "button");
  await wait("Rental details");
  if (
    !(await browser.tree()).some((n) => n.name?.value === "Remove saved rental")
  )
    await click("Save rental", "button");
  await wait("Remove saved rental");
  await click("Back", "button");
  await wait("Find your next home.");
  await click("Saved");
  await wait(listing.title);
  await screenshot("saved-rentals");
  await browser.open(base);
  await wait("Find your next home.");
  await click("Account");
  await wait("Demo Renter");
  await click("Saved");
  await wait(listing.title);
  await click("Messages");
  await wait("Your conversations");
  await wait(listing.title);
  await screenshot("messages-inbox");
  await click("Notifications", "button");
  await wait("Notifications & account");
  await wait("Your rental inquiry has a reply");
  await wait("Viewing update");
  await screenshot("in-app-notifications");
  await click("Mark all read", "button");
  await wait("Marked as read.");
  await click("Back", "button");
  await wait("Your conversations");
  await click("Account");
  await click("Sign out", "button");
  await wait("Find your next home.");
  await signIn("alex@example.com");
  await wait("Manage rentals");
  await click("Manage rentals", "button");
  await wait("Hi, Alex");
  await screenshot("landlord-workspace");
  await click("Back", "button");
  await wait("Your account");
  await click("Explore");
  await wait("Find your next home.");
  thread = await ownerApi("/auth/me", undefined, owner); // validates the owner session remains usable
  const report = {
    guestMarketplaceLanding: true,
    inAppNotifications: true,
    notificationReadState: true,
    liveNotificationStream: browser.requests.some((r) =>
      r.path.includes("/account/notifications/events"),
    ),
    nativeListingDetails: true,
    guestInteractionsRequireSignIn: true,
    signInResumesInquiry: true,
    accountConversation: true,
    viewingRequestAndConfirmation: true,
    seekerReply: true,
    savedRentalPersistsAfterReload: true,
    accountInbox: true,
    landlordWorkspaceAccessible: true,
    returnToMarketplace: true,
    paymentRequests: browser.requests.filter((r) =>
      /\/(payments|receipts|proofs)(\/|$)/.test(r.path),
    ).length,
    runtimeFailures: browser.failures,
  };
  await writeFile(
    resolve(output, "report.json"),
    JSON.stringify(report, null, 2),
  );
  console.log(JSON.stringify(report, null, 2));
  if (browser.failures.length) process.exitCode = 1;
} catch (e) {
  await browser.failure().catch(() => {});
  console.error(e);
  process.exitCode = 1;
} finally {
  await browser.close();
}
