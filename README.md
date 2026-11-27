# Toolcraft

Fork of the original [Toolcraft](https://github.com/pixel-point/toolcraft) ([toolcraft.sh](https://toolcraft.sh)) — a pnpm monorepo with the starter template and a set of example apps. Built demos are published at [toolcraft.ermolaev.site](https://toolcraft.ermolaev.site).

[Русская версия](README.ru.md)

## What this is now

Not the out-of-the-box CLI starter — a local monorepo:

| Path | Purpose |
| --- | --- |
| `starter/` | Base Toolcraft template (runtime, UI, agent docs) |
| `examples/*` | Ready-made design apps (~32 demos) |
| `screenshots/` | Catalog preview images |
| `scripts/` | Example builds and static site publishing |
| `docs/deploy-toolcraft.md` | Deploy instructions |

Site layout: catalog at `/`, each app at `/<name>/` (e.g. [`/glass/`](https://toolcraft.ermolaev.site/glass/)).

## Requirements

- Node.js 24+
- pnpm 12

```bash
pnpm install
```

## Commands

```bash
# Build all examples (base = /<name>/)
pnpm run build:examples

# Run publish-script tests
pnpm run test:publish-site

# Run one app locally
pnpm --filter ./examples/glass dev
```

Publishing to origin: `scripts/publish-site.sh` (requires `SITE_ROOT` and `SITE_URL`). In CI this runs via `.github/workflows/deploy.yml` on push to `main`.

## Workspace layout

```
toolcraft/
├── starter/           # template
├── examples/          # ascii, glass, prism-flow, …
├── screenshots/       # *.webp previews
├── scripts/
│   ├── build-examples.mjs
│   ├── publish-site.sh
│   └── publish-site.test.sh
└── docs/
    └── deploy-toolcraft.md
```

## Deploy

Push to `main` (changes under `examples/**`, lockfile, scripts, or workflow) → self-hosted runner `toolcraft-deploy` → build → publish to `/var/www/toolcraft.ermolaev.site`.

Details: [docs/deploy-toolcraft.md](docs/deploy-toolcraft.md).

## Links

- Upstream project: [github.com/pixel-point/toolcraft](https://github.com/pixel-point/toolcraft)
- Toolcraft website: [toolcraft.sh](https://toolcraft.sh)
- This repository: [github.com/detailcore/toolcraft](https://github.com/detailcore/toolcraft)
- Live demo catalog: [toolcraft.ermolaev.site](https://toolcraft.ermolaev.site)

## License

[MIT](LICENSE.md) (copyright Pixel Point).
