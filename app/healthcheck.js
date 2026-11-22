// Docker HEALTHCHECK: exit 0 when /api/health answers 200 within 2 s, otherwise exit 1.
// Plain Node, so the image needs no curl or wget.
const http = require("http");

const port = Number(process.env.PORT || 3000);
const req = http.get({ host: "127.0.0.1", port, path: "/api/health", timeout: 2000 }, (res) => {
  res.resume();
  process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on("timeout", () => req.destroy(new Error("timeout")));
req.on("error", () => process.exit(1));
