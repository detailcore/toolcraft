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
const win32 = process.platform === "win32";
let next = 0;
let failed = false;

function runPnpm(args) {
  return new Promise((resolve) => {
    const child = spawn(pnpm, args, {
      cwd: root,
      stdio: "inherit",
      shell: win32,
      // Git-Bash on Windows rewrites leading-/ args into the Git install path.
      env: win32
        ? { ...process.env, MSYS_NO_PATHCONV: "1", MSYS2_ARG_CONV_EXCL: "*" }
        : process.env,
    });
    child.on("error", (error) => {
      console.error(`error: failed to start ${args.join(" ")}: ${error.message}`);
      resolve(1);
    });
    child.on("exit", (code) => resolve(code ?? 1));
  });
}

async function buildExample(name) {
  const base = `/${name}/`;
  console.log(`build ${name} --base ${base}`);
  // pnpm run forwards extras as `vite build -- --base …` for `tsc && vite build`
  // scripts; Vite then ignores --base. Typecheck via the package script, then call
  // vite with real CLI flags.
  const typecheck = await runPnpm([
    "--filter",
    `./examples/${name}`,
    "run",
    "typecheck",
  ]);
  if (typecheck !== 0) return typecheck;
  return runPnpm([
    "--filter",
    `./examples/${name}`,
    "exec",
    "vite",
    "build",
    "--base",
    base,
  ]);
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
