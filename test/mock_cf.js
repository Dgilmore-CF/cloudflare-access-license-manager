// Minimal mock of the Cloudflare Access users + seats API for testing the PS script.
const http = require("http");

const now = Date.now();
const daysAgo = (d) => new Date(now - d * 86400000).toISOString();

// Fixtures. seat semantics: access_seat / gateway_seat = holds that seat type.
const USERS = [
  { id: "u-a", email: "a@ex.com", name: "Alice",   access_seat: true,  gateway_seat: false, seat_uid: "seat-a", last_successful_login: daysAgo(400), created_at: daysAgo(500) },
  { id: "u-b", email: "b@ex.com", name: "Bob",     access_seat: true,  gateway_seat: false, seat_uid: "seat-b", last_successful_login: daysAgo(10),  created_at: daysAgo(600) },
  { id: "u-c", email: "c@ex.com", name: "Carol",   access_seat: false, gateway_seat: true,  seat_uid: "seat-c", last_successful_login: null,          created_at: daysAgo(500) },
  { id: "u-d", email: "d@ex.com", name: "Dave",    access_seat: false, gateway_seat: true,  seat_uid: "seat-d", last_successful_login: null,          created_at: daysAgo(5)   },
  { id: "u-e", email: "e@ex.com", name: "Eve",     access_seat: true,  gateway_seat: true,  seat_uid: "seat-e", last_successful_login: daysAgo(200), created_at: daysAgo(700) },
  { id: "u-f", email: "f@ex.com", name: "Frank",   access_seat: false, gateway_seat: false, seat_uid: "seat-f", last_successful_login: daysAgo(999), created_at: daysAgo(999) },
  { id: "u-g", email: "g@ex.com", name: "Grace",   access_seat: true,  gateway_seat: false, seat_uid: "seat-g", last_successful_login: daysAgo(95),  created_at: daysAgo(800) },
];

const PAGE_SIZE = 3; // force pagination regardless of requested per_page

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

  if (req.method === "GET" && url.pathname === "/user/tokens/verify") {
    return send(200, { success: true, errors: [], messages: [], result: { id: "tok", status: "active" } });
  }

  const m = url.pathname.match(/^\/accounts\/([^/]+)\/access\/users$/);
  if (req.method === "GET" && m) {
    const page = parseInt(url.searchParams.get("page") || "1", 10);
    const totalPages = Math.ceil(USERS.length / PAGE_SIZE);
    const slice = USERS.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
    return send(200, {
      success: true, errors: [], messages: [], result: slice,
      result_info: { count: slice.length, page, per_page: PAGE_SIZE, total_count: USERS.length, total_pages: totalPages },
    });
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
