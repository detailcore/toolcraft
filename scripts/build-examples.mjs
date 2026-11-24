import { access, readdir } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const concurrency = Number(process.env.BUILD_CONCURRENCY || 2);
const slug = /^[A-Za-z0-9._-]+$/u;

if (!Number.isInteger(concurrency) || concurrency < 1) {
  console.error("error: BUILD_CONCURRENCY must be a positive integer");
  process.exit(1);
}

const entries = await readdir(path.join(root, "examples"), { withFileTypes: true });
const names = [];

for (const entry of entries) {
  if (!entry.isDirectory()) continue;
  if (!slug.test(entry.name)) {
    console.error(`error: example directory name must be a slug: ${entry.name}`);
    process.exit(1);
  }
  try {
    await access(path.join(root, "examples", entry.name, "package.json"));
  } catch {
    continue;
  }
  names.push(entry.name);
}

names.sort();

if (names.length === 0) {
  console.error("error: no examples found under examples/*/");
  process.exit(1);
}

const pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm";
let next = 0;
let failed = false;

function buildExample(name) {
  const base = `/demos/${name}/`;
  console.log(`build ${name} --base ${base}`);
  return new Promise((resolve) => {
    const child = spawn(
      pnpm,
      ["--filter", `./examples/${name}`, "run", "build", "--", "--base", base],
      { cwd: root, stdio: "inherit", shell: process.platform === "win32" },
    );
    child.on("error", (error) => {
      console.error(`error: failed to start build for ${name}: ${error.message}`);
      resolve(1);
    });
    child.on("exit", (code) => resolve(code ?? 1));
  });
}

async function worker() {
  while (!failed) {
    const index = next;
    next += 1;
    if (index >= names.length) return;
    const code = await buildExample(names[index]);
    if (code !== 0) failed = true;
  }
}

await Promise.all(
  Array.from({ length: Math.min(concurrency, names.length) }, () => worker()),
);

if (failed) process.exit(1);

console.log(`built ${names.length} examples`);
