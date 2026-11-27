# Toolcraft

Fork оригинального [Toolcraft](https://github.com/pixel-point/toolcraft) ([toolcraft.sh](https://toolcraft.sh)) — pnpm-monorepo со starter-шаблоном и набором example-приложений. Собранные демо публикуются на [toolcraft.ermolaev.site](https://toolcraft.ermolaev.site).

[English version](README.md)

## Что это сейчас

Не CLI-стартер «из коробки», а локальный monorepo:

| Путь | Назначение |
| --- | --- |
| `starter/` | Базовый шаблон Toolcraft (runtime, UI, docs для агентов) |
| `examples/*` | Готовые design-приложения (~32 демо) |
| `screenshots/` | Превью для каталога на сайте |
| `scripts/` | Сборка examples и публикация статики |
| `docs/deploy-toolcraft.md` | Инструкция по деплою |

Сайт: каталог на `/`, каждое приложение на `/<имя>/` (например [`/glass/`](https://toolcraft.ermolaev.site/glass/)).

## Требования

- Node.js 24+
- pnpm 12

```bash
pnpm install
```

## Команды

```bash
# Собрать все examples (base = /<имя>/)
pnpm run build:examples

# Прогнать тесты publish-скрипта
pnpm run test:publish-site

# Запустить одно приложение локально
pnpm --filter ./examples/glass dev
```

Публикация на origin: `scripts/publish-site.sh` (нужны `SITE_ROOT` и `SITE_URL`). В CI это делает workflow `.github/workflows/deploy.yml` на push в `main`.

## Структура workspace

```
toolcraft/
├── starter/           # шаблон
├── examples/          # ascii, glass, prism-flow, …
├── screenshots/       # *.webp превью
├── scripts/
│   ├── build-examples.mjs
│   ├── publish-site.sh
│   └── publish-site.test.sh
└── docs/
    └── deploy-toolcraft.md
```

## Деплой

Push в `main` (изменения в `examples/**`, lockfile, скриптах или workflow) → self-hosted runner `toolcraft-deploy` → сборка → выкладка в `/var/www/toolcraft.ermolaev.site`.

Подробности: [docs/deploy-toolcraft.md](docs/deploy-toolcraft.md).

## Ссылки

- Оригинальный проект: [github.com/pixel-point/toolcraft](https://github.com/pixel-point/toolcraft)
- Сайт Toolcraft: [toolcraft.sh](https://toolcraft.sh)
- Этот репозиторий: [github.com/detailcore/toolcraft](https://github.com/detailcore/toolcraft)
- Живой каталог демо: [toolcraft.ermolaev.site](https://toolcraft.ermolaev.site)

## Лицензия

[MIT](LICENSE.md) (copyright Pixel Point).
