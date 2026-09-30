// Minimal mock of the Cloudflare Access users + seats API for testing the PS script.
const http = require("http");

const now = Date.now();
const daysAgo = (d) => new Date(now - d * 86400000).toISOString();

// Fixtures. seat semantics: access_seat / gateway_seat = holds that seat type.
// last_successful_login is the last *Access* login only; WARP/Gateway activity is
// expressed via device REGISTRATIONS below (last_seen_at), exactly like the real API.
//
// Expected outcome at -InactiveDays 90 (Either):
//   a  Alice  Access login 400d, no devices                      -> inactive (last_successful_login)
//   b  Bob    Access login 10d                                    -> active
//   c  Carol  gateway-only, never Access login, device seen 3d    -> ACTIVE  (was wrongly flagged before device support)
//   d  Dave   gateway-only, created 5d, device seen 2d            -> active
//   e  Eve    Access 200d, no devices                             -> inactive (last_successful_login)
//   f  Frank  holds no seat                                       -> ignored
//   g  Grace  Access 95d                                          -> inactive (last_successful_login)
//   h  Heidi  Access 400d BUT device seen 20d                     -> ACTIVE  (device activity wins)
//   i  Ivan   gateway-only, never Access login, device seen 120d  -> inactive (device_last_seen)
//   j  Judy   access seat, never Access login, no devices, 300d   -> inactive (created_at) unless -ExcludeNeverLoggedIn
const USERS = [
  { id: "u-a", email: "a@ex.com", name: "Alice",   access_seat: true,  gateway_seat: false, seat_uid: "seat-a", last_successful_login: daysAgo(400), created_at: daysAgo(500) },
  { id: "u-b", email: "b@ex.com", name: "Bob",     access_seat: true,  gateway_seat: false, seat_uid: "seat-b", last_successful_login: daysAgo(10),  created_at: daysAgo(600) },
  { id: "u-c", email: "c@ex.com", name: "Carol",   access_seat: false, gateway_seat: true,  seat_uid: "seat-c", last_successful_login: null,          created_at: daysAgo(500) },
  { id: "u-d", email: "d@ex.com", name: "Dave",    access_seat: false, gateway_seat: true,  seat_uid: "seat-d", last_successful_login: null,          created_at: daysAgo(5)   },
  { id: "u-e", email: "e@ex.com", name: "Eve",     access_seat: true,  gateway_seat: true,  seat_uid: "seat-e", last_successful_login: daysAgo(200), created_at: daysAgo(700) },
  { id: "u-f", email: "f@ex.com", name: "Frank",   access_seat: false, gateway_seat: false, seat_uid: "seat-f", last_successful_login: daysAgo(999), created_at: daysAgo(999) },
  { id: "u-g", email: "g@ex.com", name: "Grace",   access_seat: true,  gateway_seat: false, seat_uid: "seat-g", last_successful_login: daysAgo(95),  created_at: daysAgo(800) },
  { id: "u-h", email: "h@ex.com", name: "Heidi",   access_seat: true,  gateway_seat: true,  seat_uid: "seat-h", last_successful_login: daysAgo(400), created_at: daysAgo(900) },
  { id: "u-i", email: "i@ex.com", name: "Ivan",    access_seat: false, gateway_seat: true,  seat_uid: "seat-i", last_successful_login: null,          created_at: daysAgo(700) },
  { id: "u-j", email: "j@ex.com", name: "Judy",    access_seat: true,  gateway_seat: false, seat_uid: "seat-j", last_successful_login: null,          created_at: daysAgo(300) },
];

// WARP device registrations (GET /devices/registrations). Multiple registrations per user
// are normal; the newest last_seen_at wins. Revoked registrations still count as evidence
// of past activity. Users u-i is referenced by *email only* to prove the email fallback.
const REGISTRATIONS = [
  { id: "reg-c1", last_seen_at: daysAgo(40),  revoked_at: null,        user: { id: "u-c", email: "c@ex.com", name: "Carol" }, device: { id: "dev-c1", name: "carol-laptop" }, registration_type: "warp" },
  { id: "reg-c2", last_seen_at: daysAgo(3),   revoked_at: null,        user: { id: "u-c", email: "c@ex.com", name: "Carol" }, device: { id: "dev-c2", name: "carol-phone"  }, registration_type: "warp" },
  { id: "reg-d1", last_seen_at: daysAgo(2),   revoked_at: null,        user: { id: "u-d", email: "d@ex.com", name: "Dave"  }, device: { id: "dev-d1", name: "dave-laptop"  }, registration_type: "warp" },
  { id: "reg-h1", last_seen_at: daysAgo(20),  revoked_at: null,        user: { id: "u-h", email: "h@ex.com", name: "Heidi" }, device: { id: "dev-h1", name: "heidi-mac"    }, registration_type: "warp" },
  { id: "reg-h2", last_seen_at: daysAgo(500), revoked_at: daysAgo(490), user: { id: "u-h", email: "h@ex.com", name: "Heidi" }, device: { id: "dev-h2", name: "heidi-old"    }, registration_type: "warp" },
  { id: "reg-i1", last_seen_at: daysAgo(120), revoked_at: null,        user: { id: null,  email: "I@EX.COM", name: "Ivan"  }, device: { id: "dev-i1", name: "ivan-pc"      }, registration_type: "warp" },
  { id: "reg-x1", last_seen_at: null,         revoked_at: null,        user: { id: "u-a", email: "a@ex.com", name: "Alice" }, device: { id: "dev-a1", name: "alice-never" }, registration_type: "warp" },
];

const PAGE_SIZE = 3;     // force page-number pagination regardless of requested per_page
const REG_PAGE_SIZE = 4; // force cursor pagination for registrations

// Special account IDs to simulate real-world API variations:
//   acct-nototal : users list omits result_info.total_pages (only total_count) -> script must still paginate
//   acct-nodev   : device registrations endpoint returns 403 (token lacks Zero Trust: Read)


const patched = []; // records PATCH bodies

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  const send = (code, obj) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(obj)); };

  // Test-only: reset accumulated PATCH state so each removal assertion is hermetic.
  // Clears the in-memory log and deletes patched.json (no auth required).
  if (req.method === "POST" && url.pathname === "/__reset") {
    patched.length = 0;
    try { require("fs").unlinkSync(require("path").join(__dirname, "patched.json")); } catch (e) {}
    return send(200, { success: true });
  }

  // Auth check
  const auth = req.headers["authorization"] || "";
  if (!auth.startsWith("Bearer ")) return send(401, { success: false, errors: [{ code: 1000, message: "missing token" }] });

  if (req.method === "GET" && (url.pathname === "/user/tokens/verify" || /^\/accounts\/[^/]+\/tokens\/verify$/.test(url.pathname))) {
    return send(200, { success: true, errors: [], messages: [], result: { id: "tok", status: "active" } });
  }

  const m = url.pathname.match(/^\/accounts\/([^/]+)\/access\/users$/);
  if (req.method === "GET" && m) {
    const acct = m[1];
    const page = parseInt(url.searchParams.get("page") || "1", 10);
    const totalPages = Math.ceil(USERS.length / PAGE_SIZE);
    const slice = USERS.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
    const result_info = { count: slice.length, page, per_page: PAGE_SIZE, total_count: USERS.length };
    if (acct !== "acct-nototal") result_info.total_pages = totalPages;
    return send(200, { success: true, errors: [], messages: [], result: slice, result_info });
  }

  const d = url.pathname.match(/^\/accounts\/([^/]+)\/devices\/registrations$/);
  if (req.method === "GET" && d) {
    if (d[1] === "acct-nodev") {
      return send(403, { success: false, errors: [{ code: 10000, message: "Authentication error" }], messages: [], result: null });
    }
    // Opaque cursor = stringified offset. Last page returns no cursor.
    const cursor = url.searchParams.get("cursor");
    const offset = cursor ? parseInt(Buffer.from(cursor, "base64").toString("utf8"), 10) : 0;
    const slice = REGISTRATIONS.slice(offset, offset + REG_PAGE_SIZE);
    const next = offset + REG_PAGE_SIZE < REGISTRATIONS.length ? Buffer.from(String(offset + REG_PAGE_SIZE)).toString("base64") : undefined;
    const result_info = { count: slice.length, per_page: REG_PAGE_SIZE, total_count: REGISTRATIONS.length };
    if (next) result_info.cursor = next;
    return send(200, { success: true, errors: [], messages: [], result: slice, result_info });
  }

  const s = url.pathname.match(/^\/accounts\/([^/]+)\/access\/seats$/);
  if (req.method === "PATCH" && s) {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let parsed;
      try { parsed = JSON.parse(body || "[]"); } catch (e) { return send(400, { success: false, errors: [{ code: 1000, message: "bad json" }] }); }
      patched.push(parsed);
      try { require("fs").writeFileSync(require("path").join(__dirname, "patched.json"), JSON.stringify(patched, null, 2)); } catch (e) {}
      const result = parsed.map((p) => ({ seat_uid: p.seat_uid, access_seat: p.access_seat, gateway_seat: p.gateway_seat, created_at: daysAgo(700), updated_at: new Date().toISOString() }));
      return send(200, { success: true, errors: [], messages: [], result, result_info: { count: result.length, page: 1, per_page: 1000, total_count: result.length, total_pages: 1 } });
    });
    return;
  }

  send(404, { success: false, errors: [{ code: 1000, message: "not found: " + req.method + " " + url.pathname }] });
});

// dump patched bodies on SIGTERM/exit for assertions
process.on("SIGUSR2", () => {
  require("fs").writeFileSync(require("path").join(__dirname, "patched.json"), JSON.stringify(patched, null, 2));
});

const PORT = parseInt(process.env.PORT || "8787", 10);
server.listen(PORT, "127.0.0.1", () => console.log("mock listening on " + PORT));
