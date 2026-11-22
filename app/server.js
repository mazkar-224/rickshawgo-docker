// RickshawGo live API v2.2 - container-ready (configurable bind address, graceful shutdown)
const os = require("os");
const express = require("express");
const morgan = require("morgan");

const PORT = Number(process.env.PORT || 3000);
// In a container the app must listen on all interfaces (HOST=0.0.0.0, set in the image);
// outside a container the safe default stays 127.0.0.1 (only Nginx on the same machine).
const HOST = process.env.HOST || "127.0.0.1";
const KEY = process.env.MAPS_KEY;
const VERSION = "2.2";

if (!KEY) {
  console.error("FATAL: MAPS_KEY is not set. Refusing to start.");
  process.exit(1);
}

const app = express();
app.disable("x-powered-by");
app.use(morgan("combined"));

const rickshaws = [
  { id: "PSH-101", area: "Saddar", status: "free" },
  { id: "PSH-117", area: "University Town", status: "busy" },
  { id: "PSH-142", area: "Hayatabad", status: "free" },
  { id: "PSH-150", area: "Board Bazaar", status: "free" },
];

app.get("/api/health", (req, res) => {
  // "instance" is the container's hostname: it shows which copy answered (in a container every pid is 1)
  res.json({ status: "ok", version: VERSION, instance: os.hostname(), port: PORT, pid: process.pid });
});

app.get("/api/rickshaws", (req, res) => {
  res.json({ rickshaws: rickshaws });
});

app.get("/api/rickshaws/free", (req, res) => {
  res.json({ rickshaws: rickshaws.filter((r) => r.status === "free") });
});

app.get("/api/rickshaws/count", (req, res) => {
  const free = rickshaws.filter((r) => r.status === "free").length;
  res.json({ total: rickshaws.length, free: free });
});

app.use((req, res) => {
  res.status(404).json({ error: "not found" });
});

const server = app.listen(PORT, HOST, () => {
  console.log(`RickshawGo API v${VERSION} listening on ${HOST}:${PORT}`);
});

// `docker stop` sends SIGTERM: finish the requests in flight, then exit cleanly
// (without this, Node as PID 1 ignores SIGTERM and Docker kills it after 10 s).
function shutdown(signal) {
  console.log(`${signal} received: closing the server`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 8000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
