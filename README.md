# Ionnet GSS game definitions

The official game definitions for [Ionnet GSS](https://gss.ionnet.dev) (Ionnet Game Server Studio). A panel adds
this repository as a source (Manage → Sources) and offers every game in it:

| Game | Folder |
| --- | --- |
| Minecraft: Java Edition (vanilla, Paper, Forge, NeoForge) | `minecraft-java` |
| Garry's Mod | `garrys-mod` |
| Garry's Mod with a MariaDB database beside it | `garrys-mod-mysql` |

One folder per game: `<id>/game.yml` plus any files it references (`hooks/*.sh`, config templates). A server keeps
the version of the definition it was created with until its owner upgrades it. In the panel's own repository this
repository is the `games` folder, which a development panel loads as its built-in source (`GAMES_DIR`).

## Images

A game runs in an image from `ghcr.io/ionnet-dev`. A bare `image: ionnet-gss-<name>[:tag]` in game.yml gets the
panel's `IMAGE_REGISTRY` in front (`ionnet-gss-minecraft-server:java21` →
`ghcr.io/ionnet-dev/ionnet-gss-minecraft-server:java21`); any other reference (`mariadb:11.4`) is used as written.

- `ionnet-gss-base` (Debian with `gss-init`, which every game image needs) is built and published by the panel's
  repository, because it compiles `gss-init` from the agent's code.
- A game that needs more than the base keeps its image here, next to its game.yml: `<game>/image/Dockerfile`
  (`FROM ${BASE}`, default `ghcr.io/ionnet-dev/ionnet-gss-base:latest`) and `<game>/image/image.yml`, which names the
  image and its tags:

  ```yaml
  name: ionnet-gss-minecraft-server
  variants:
    - tag: java21
      args: { JAVA: "21" } # Build args for the Dockerfile.
  ```

  `.github/workflows/images.yml` builds every variant for linux/amd64 and pushes it: on a push that changes an
  `image/` folder (only those games), every Monday (all games, so they pick up a new base image and OS or runtime
  updates) and on demand (Actions → Images → Run workflow, optionally one game). It keeps no artifacts or build cache
  and deletes each image's untagged versions afterwards, so the registry holds only the current tags.
- Hosts pull an image when a server installs or reinstalls, so a rebuilt tag reaches a server at its next
  (re)install; running servers keep the image they have until then.
- A new image's package on GHCR starts private: make it public once (package settings → Change visibility) so hosts
  can pull it without logging in.

## Format

- Hooks run inside the container as uid 1000 in `/data`, with `GSS_VAR_<KEY>`, `GSS_PORT_<NAME>` and `GSS_SERVER_ID`
  in the environment. Non-zero exit = the step failed.
- Install steps: `download`, `extract`, `write`, `hook` and `steamcmd`. Config formats: `properties`, `template`,
  `ini`, `json`, `yaml` and `cfg` (below).
- Git sources (Manage → Sources) use the same layout below their `path`; the panel syncs them on add, on demand and
  every `syncIntervalMin`. A game that fails validation keeps its previous version, and its error shows on the source.

## steamcmd games

`install: [{ steamcmd: { app: 4020, beta: …, validate: true } }]` installs a Steam app anonymously into `/data` (or
`dir:` below it). gss-init fetches its own steamcmd into `/data/.gss/steamcmd` (per server, nothing shared between
servers), prints steamcmd's progress lines to the console and tries a failing run up to three times. "Update game" in the panel
(`POST /api/servers/:id/update`, while stopped, or after a failed update) re-runs only the `steamcmd` steps and the
`update` hook. A Source game's files are large (Garry's Mod: about 7 GB) and every server has its own copy: size
`limits.disk` for it.

## Config formats

Each `configs` entry names a `file` below `/data`, a `format` and the keys to `set`. Only those keys change: comments,
blank lines, order, line endings and every other key stay as the owner left them, and a missing file is created.

| Format | Key addressing | Notes |
| --- | --- | --- |
| `properties` | literal key | `key=value` (Java properties) |
| `ini` | `section.key` (`key` alone = before the first section) | missing sections are appended |
| `json` | dotted path (`server.name`, `admins.0`) | an existing value keeps its type while the new one fits it; a new key is typed by the value (`true`/`false`, a number, else a string). JSONC is refused |
| `yaml` | dotted path | same typing; edited as YAML nodes, so comments survive |
| `cfg` | literal cvar, case-insensitive | Source engine `key "value"` lines; `"` in a value becomes `'` (the engine has no escape), `;` and `//` inside the quotes are plain text |
| `template` | none | the whole file is rendered from `template:` every time |

## Packages and services

- `packages: [name, …]` (Debian names, not ending in `-`, `:i386` allowed, at most 50): the agent builds a derived image from `image` once
  per host (`ionnet-gss-derived:<hash>`, build lines in the console) and reuses it for every server with the same
  list. Only list what the game really loads: check with `ldd` on its binaries first. Garry's Mod needs none. The
  build runs on the agent's filtered `gss-build` network (public mirrors only), so it fails while the host's egress
  filtering doesn't work.
- `services: { <name>: { image, env, volume, healthcheck, limits } }` (at most 4) run next to the game on the server's
  own network as host `<name>`, never published. They start first and the game waits until each is healthy. Their
  data lives in `services/<name>` beside the server's `data/` (deleting with "keep data" keeps it too) and counts
  toward the server's disk limit (`limits.disk`) like `data/` does, and their
  `limits` (the panel fills defaults) count toward the owner's quota. `volume` is a clean absolute path
  (`/var/lib/mysql`, not `/var/lib/mysql/` or `/a//b`); `healthcheck.startTimeout` is 1-600 seconds (default 120) and
  the start request waits for the longest one. See `garrys-mod-mysql`.

## Lists from the web (`options_from`)

A `select` variable can take its choices from a JSON document: `options_from: { url, items, value, where, include,
reverse, limit }` (see `minecraft-java`'s `version`). The panel fetches it (https, hosts on `OPTIONS_FETCH_HOSTS`, at
most 2 MiB, cached), puts the static `options` first, and checks submitted values against the list. When the list
can't be fetched the form becomes free text, so give the variable a `pattern` the value must then match.

A list can depend on other variables: `{{vars.<key>}}` (no filters) may appear in `url` after the host (URL-encoded),
in `where` values and in `include` (matched as literal text). The form sends their current values and fetches the
list again when they change; a picked value the new list no longer offers moves to the list's first choice. See
`minecraft-java`'s `forge_version` (`include: '^{{vars.version}}-'`) and `neoforge_version`
(`where: { requires.0.equals: '{{vars.version}}' }`). A list can't depend on a secret, on itself, or in a circle.

## Showing a variable only sometimes (`when`)

`when: { flavour: [forge] }` shows a variable only while `flavour` is `forge` (several keys must all match; booleans
are written `"true"` / `"false"`). A hidden variable keeps its value (its default, at create) and a hidden select isn't
checked against its `options_from` list, so a hook still gets it: check the flavour before using it.

## Minecraft loaders

The install hook writes `gss-launch.args`, which `start` passes to java after the memory flags: `-jar server.jar`
(vanilla, Paper), `@libraries/…/unix_args.txt` (Forge 1.17+ and NeoForge, from their installer) or
`-jar forge-<version>.jar` (older Forge). The Forge list comes from Forge's maven, the NeoForge list from Prism
Launcher's index (NeoForge's maven doesn't say which Minecraft version a build is for); both installers are downloaded
from the official mavens and checked against their `.sha256`. `recommended` is Forge's recommended build (else its
newest), or NeoForge's newest stable build (else its newest beta). With Minecraft `latest`, the hook falls back to the
loader's newest Minecraft version when it doesn't support the newest release yet. The panel's `OPTIONS_FETCH_HOSTS`
needs `maven.minecraftforge.net` and `meta.prismlauncher.org` (in the default list).

## Patterns

`pattern` (a whole-value match) and `options_from.include` (a match anywhere) are regular expressions of at most 200
characters, matched against values of at most 1024. The panel runs them on a backtracking engine and a server's
owner picks the value, so it refuses what can take exponential or high-polynomial time: look-around and back
references, a repeated group that contains a quantifier or `|` (`([a-z0-9_]+)*`, `(a|ab)+`, `(\.[0-9]+)*`; a `?`
on such a group is fine, as in `[0-9]+\.[0-9]+(\.[0-9]+)?`), and more than three unbounded quantifiers (`*`, `+`,
`{n,}`). Write a character class or one quantifier instead (`[a-z0-9_]*`).

## Player patterns

`players.join` and `players.leave` are RE2 patterns that gss-init matches against every console line of the running game
(colour codes stripped); the first capture group is the player name. Anchor them at the line start (`^`, then only
the log prefix) and the line end, so chat can't fake a join or leave: see `minecraft-java/game.yml`. A pattern without a
capture group is refused.

## Templates and quoting

Strings in `image`, `install`, `configs`, `hooks`, `start`, `ready`, `stop`, `console`, `players`, `backup` and
`services` may use `{{vars.<key>}}`, `{{ports.<name>}}`, `{{server.id}}` and `{{server.name}}`. The panel renders
them before anything reaches the host. A filter after `|` quotes the value for where it lands:

| Placeholder | Renders `It's <ok>` as | Use in |
| --- | --- | --- |
| `{{vars.motd}}` | `It's <ok>` | `properties` values, plain config text |
| `{{vars.motd\|sh}}` | `'It'\''s <ok>'` (POSIX single quotes) | `start`, `stop.command`, anything run by `/bin/sh` |
| `{{vars.motd\|json}}` | `"It's <ok>"` | JSON or YAML config templates |

`start` runs through `/bin/sh -c`, so a definition fails validation when a `string` or `secret` variable, a `select`
with `options_from` (its list comes from another site) or `server.name` appears unfiltered in `start`,
`stop.command` or a hook path: write `{{vars.motd|sh}}`. Numbers, booleans and static `select` values (the author's
own options) need no filter. `image` and `services.<name>.image` may only use a `select` with static `options`
(no `options_from`, string, secret or server name), so an owner can't choose what runs. Values never contain line breaks or control
characters (the panel refuses them, the server name included).

## Limits and timeouts

- `number` variables may set `min` and `max`; the panel refuses values outside them (400) and the create form shows
  them. A variable with `bind: limits.memory` is the container's memory limit, so size a JVM heap from it with
  `-XX:MaxRAMPercentage=75.0` rather than `-Xmx{{vars.memory}}M` (a heap as large as the limit gets OOM-killed).
- `install_timeout` (seconds, at least 60, default 7200) cancels an install that hangs; the server ends
  `install_failed` and can be reinstalled. A stop request during the install cancels it too.
