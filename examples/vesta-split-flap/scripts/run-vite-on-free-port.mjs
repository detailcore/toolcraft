#!/usr/bin/env node

import { access, readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { findAvailablePort, readPreferredPort } from "./creative-apps-kit-port.mjs";

const viteCommand = process.argv[2] ?? "dev";
const passthroughArgs = process.argv.slice(3).filter((arg) => arg !== "--");
const preferredPort = readPreferredPort([
  "CREATIVE_APPS_KIT_DEV_PORT",
  "CREATIVE_APPS_KIT_PORT",
  "PORT",
]);
const port = await findAvailablePort(preferredPort);

if (port !== preferredPort) {
  console.log(`[creative-apps-kit] Port ${preferredPort} is busy; using ${port} instead.`);
}

const projectDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const viteJsPath = join(projectDir, "node_modules", "vite", "bin", "vite.js");
const indexHtmlPath = join(projectDir, "index.html");

try {
  await access(viteJsPath);
} catch {
  console.error(
    "Vite is not installed. Run this app's dependency installation command before starting the dev server.",
  );
  process.exit(1);
}

function readExpectedAppMarker(html) {
  const metaMatch =
    html.match(
      /<meta\s+[^>]*name=["'](?:toolcraft-app-title|creative-apps-kit-app-title)["'][^>]*content=["']([^"']+)["'][^>]*>/i,
    ) ||
    html.match(
      /<meta\s+[^>]*content=["']([^"']+)["'][^>]*name=["'](?:toolcraft-app-title|creative-apps-kit-app-title)["'][^>]*>/i,
    );

  if (metaMatch?.[1]?.trim()) {
    return { kind: "meta", value: metaMatch[1].trim() };
  }

  const titleMatch = html.match(/<title>\s*([^<]+?)\s*<\/title>/i);

  if (titleMatch?.[1]?.trim()) {
    return { kind: "title", value: titleMatch[1].trim() };
  }

  return null;
}

function responseMatchesApp(html, marker) {
  if (!marker) {
    return /\bid=["']root["']/.test(html);
  }

  if (marker.kind === "meta") {
    return (
      html.includes(marker.value) &&
      /name=["'](?:toolcraft-app-title|creative-apps-kit-app-title)["']/i.test(html)
    );
  }

  const titleMatch = html.match(/<title>\s*([^<]+?)\s*<\/title>/i);
  return titleMatch?.[1]?.trim() === marker.value;
}

let expectedAppMarker = null;

try {
  expectedAppMarker = readExpectedAppMarker(await readFile(indexHtmlPath, "utf8"));
} catch {
  // Fall back to a generic root-mount check if index.html is unavailable.
}

// Spawn Node + vite.js directly. On Windows/Node 24, spawning *.cmd via child_process
// without a shell raises spawn EINVAL.
const child = spawn(
  process.execPath,
  [
    viteJsPath,
    viteCommand,
    "--host",
    "127.0.0.1",
    "--port",
    String(port),
    "--strictPort",
    ...passthroughArgs,
  ],
  {
    env: {
      ...process.env,
      CREATIVE_APPS_KIT_ACTIVE_PORT: String(port),
      PORT: String(port),
    },
    stdio: "inherit",
  },
);

const signalExitCodes = {
  SIGINT: 130,
  SIGTERM: 143,
};

let childExit = null;
let resolveChildExit;
const childExitPromise = new Promise((resolve) => {
  resolveChildExit = resolve;
});

function markChildExit(code, signal) {
  if (childExit) {
    return;
  }

  childExit = { code, signal };
  resolveChildExit(childExit);
}

child.on("exit", (code, signal) => {
  markChildExit(code, signal);
});

child.on("error", (error) => {
  console.error(`[creative-apps-kit] Failed to start Vite: ${error?.message ?? error}`);
  markChildExit(1, null);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    if (!childExit) {
      child.kill(signal);
    }
  });
}

function exitFromChild(code, signal) {
  if (signal) {
    process.exit(signalExitCodes[signal] ?? 1);
    return;
  }

  process.exit(code ?? 0);
}

async function stopChild(signal = "SIGTERM") {
  if (childExit) {
    return childExit;
  }

  child.kill(signal);

  await Promise.race([
    childExitPromise,
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);

  if (!childExit) {
    child.kill("SIGKILL");
    await Promise.race([
      childExitPromise,
      new Promise((resolve) => setTimeout(resolve, 1_000)),
    ]);
  }

  return childExit;
}

async function waitForAppReady(url, { timeoutMs = 15_000, intervalMs = 200 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;

  while (Date.now() <= deadline) {
    if (childExit) {
      throw new Error(`Vite exited before serving this app on ${url}`);
    }

    try {
      const response = await fetch(url, { cache: "no-store" });

      if (!response.ok) {
        lastError = new Error(`HTTP ${response.status}`);
      } else {
        const html = await response.text();

        if (responseMatchesApp(html, expectedAppMarker)) {
          return;
        }

        lastError = new Error(
          expectedAppMarker
            ? `response did not match local app marker "${expectedAppMarker.value}"`
            : "response did not look like this app",
        );
      }
    } catch (error) {
      lastError = error;
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  throw new Error(
    `Timed out waiting for ${url}${lastError?.message ? ` (${lastError.message})` : ""}`,
  );
}

const appUrl = `http://127.0.0.1:${port}/`;

try {
  const startupResult = await Promise.race([
    waitForAppReady(appUrl).then(() => "ready"),
    childExitPromise.then(() => "exited"),
  ]);

  if (startupResult === "exited") {
    throw new Error(`Vite exited before serving this app on ${appUrl}`);
  }

  console.log(`[creative-apps-kit] Verified this app on ${appUrl}`);
} catch (error) {
  console.error(`[creative-apps-kit] ${error?.message ?? error}`);

  await stopChild("SIGTERM");
  process.exit(1);
}

if (childExit) {
  exitFromChild(childExit.code, childExit.signal);
}

childExitPromise.then(({ code, signal }) => {
  exitFromChild(code, signal);
});
