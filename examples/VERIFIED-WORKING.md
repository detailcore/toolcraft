# Examples verification status

Durable marker for examples verified by installing dependencies, starting the local app, opening the page in a browser, refreshing, and checking the browser console for errors.

Statuses:
- `working` — started successfully; no blocking console errors after refresh
- `failed` — install, start, or console errors could not be resolved
- `skipped` — not processed
- `pending` — not yet verified in this pass

| Example | Status | Notes |
| --- | --- | --- |
| ascii | working | npm run dev @ http://127.0.0.1:3002/ |
| aura-carousel | working | npm run dev @ http://127.0.0.1:3002/ |
| brick-mosaic | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| bricks | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| dither-lab | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| donut-studio | working | npm run dev @ http://127.0.0.1:3002/ |
| dot-ring-studio | working | npm run dev @ http://127.0.0.1:3002/ |
| draw-tool | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| editorial-pattern-studio | working | npm run dev @ http://127.0.0.1:3002/ |
| fine-details | working | npm run dev @ http://127.0.0.1:3003/ |
| frozen | working | npm run dev @ http://127.0.0.1:3003/; THREE WebGL precision warnings non-blocking |
| frozen-matter | working | npm run dev @ http://127.0.0.1:3002/; THREE WebGL precision warnings non-blocking |
| glass | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| grass-world | working | npm run dev @ http://127.0.0.1:3002/; THREE WebGL precision warnings non-blocking |
| hero | working | npm run dev @ http://127.0.0.1:3003/ |
| kinetic-circle | working | npm run dev @ http://127.0.0.1:3002/ |
| liquid-glass | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| liquid-metal | working | npm run dev @ http://127.0.0.1:3002/; THREE WebGL precision warnings non-blocking; installed missing lightningcss-win32-x64-msvc@1.32.0 |
| logo-sphere | working | npm run dev @ http://127.0.0.1:3002/ |
| mesh-fx | working | npm run dev @ http://127.0.0.1:3002/ |
| mesh-gradient | working | npm run dev @ http://127.0.0.1:3002/ |
| micrographics | working | npm run dev @ http://127.0.0.1:3002/; fixed Maximum update depth in micrographics-canvas selection sync (bail out when filtered selectedIds unchanged) |
| neon-globe | working | npm run dev @ http://127.0.0.1:3002/ |
| neon-iceberg | working | npm run dev @ http://127.0.0.1:3002/; THREE WebGL precision warnings non-blocking |
| particle-typography | working | npm run dev @ http://127.0.0.1:3002/ |
| polar-signals | working | npm run dev @ http://127.0.0.1:3002/ |
| prism-flow | working | npm run dev @ http://127.0.0.1:3002/ |
| spatial-gallery | working | npm run dev @ http://127.0.0.1:3002/; canvas present |
| studio-room | working | npm run dev @ http://127.0.0.1:3002/ |
| suminagashi-studio | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| vesta-split-flap | working | pnpm dev @ http://127.0.0.1:3002/; fixed Windows spawn EINVAL in run-vite-on-free-port.mjs |
| work-with-masks | working | pnpm dev @ http://127.0.0.1:3002/; THREE WebGL precision warnings non-blocking |
