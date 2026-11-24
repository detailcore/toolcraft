import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? "");
const mode = process.argv[3] ?? "ok";

if (!process.argv[2]) {
  process.stderr.write("usage: publish-site-fixture.mjs <siteRoot> <mode>\n");
  process.exit(1);
}

function fileFor(urlPath) {
  let decoded = urlPath.split("?")[0];
  try {
    decoded = decodeURIComponent(decoded);
  } catch {
    return null;
  }
  const relative = decoded.replace(/^\/+/, "");
  if (relative.split("/").includes("..")) return null;
  const file = path.resolve(root, relative);
  const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
  if (file !== root && !file.startsWith(prefix)) return null;
  return file;
}

function send(res, status, headers, body) {
  const payload = Buffer.from(body ?? "");
  res.writeHead(status, { "Content-Length": String(payload.length), ...headers });
  res.end(payload);
}

const server = http.createServer((req, res) => {
  const urlPath = (req.url ?? "/").split("?")[0];
  if (urlPath === "/") {
    if (mode === "no-redirect") {
      send(res, 200, { "Content-Type": "text/html; charset=utf-8" }, "<!doctype html><p>no redirect</p>");
      return;
    }
    const location = mode === "bad-location" ? "/elsewhere/" : "/demos/";
    res.writeHead(302, { Location: location });
    res.end();
    return;
  }

  if (mode === "bad-asset" && /\.(js|css)$/.test(urlPath)) {
    send(res, 404, { "Content-Type": "text/plain; charset=utf-8" }, "missing");
    return;
  }

  const file = fileFor(urlPath);
  if (!file) {
    send(res, 400, { "Content-Type": "text/plain; charset=utf-8" }, "bad path");
    return;
  }

  let target = file;
  if (fs.existsSync(target) && fs.statSync(target).isDirectory()) {
    target = path.join(target, "index.html");
  }
  if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
    send(res, 404, { "Content-Type": "text/plain; charset=utf-8" }, "missing");
    return;
  }

  const ext = path.extname(target);
  const type =
    ext === ".js" ? "text/javascript; charset=utf-8" : ext === ".css" ? "text/css; charset=utf-8" : "text/html; charset=utf-8";
  send(res, 200, { "Content-Type": type }, fs.readFileSync(target));
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") {
    process.stderr.write("fixture server did not bind a TCP port\n");
    process.exit(1);
  }
  fs.writeSync(1, `${address.port}\n`);
});
