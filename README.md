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

  `.github/workflows/images.yml` builds a variant for linux/amd64 and pushes it **only when its inputs changed**: the
  files in `image/` (other than image.yml), the variant's build args, or the exact image behind one of the
  Dockerfile's `FROM` lines (a new `ionnet-gss-base`, a republished JRE). Every image carries its inputs as
  `dev.ionnet.gss.inputs*` labels; the workflow compares them with the published image's labels
  (`.github/scripts/image-inputs.sh`) and logs per tag `unchanged (inputs …), skipped` or what changed. It checks on
  every push that touches an `image/` folder or the scripts, daily, and on demand (Actions → Images → Run workflow,
  optionally one game, and **force** to build even when nothing changed). A check with nothing to build takes
  seconds. Packages installed in the build (`apt`) are not an input of their own: they arrive when the image they
  come from is republished, or with a forced build. Unneeded rebuilds are avoided on purpose, because every rebuilt
  tag is downloaded again by each host and recreates the server's container at its next install. The workflow keeps
  no artifacts or build cache and deletes each built image's untagged versions afterwards, so the registry holds only
  the current tags.
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

## Game settings (`settings`)

`settings` adds a Game settings tab to a server: the panel reads the config file through the file API, shows the
declared fields that apply to this server, and writes back only the keys the owner changed (the file stays the source
of truth; comments, order and unknown keys are kept). A child definition's `settings` replace the parent's whole block.

- The game version `since`/`until` compare against comes from `game_version` (below). Unknown (`latest` before the
  first install): the newest fields apply. `version` and `version_file` inside `settings` are the older spelling,
  used only without `game_version`.
- `files[]`: `file`, `format` (as in `configs`), `label` (section title), `others: true` (also list keys in the file no
  applicable field declares, as text fields under "Other": keys of versions the definition doesn't know yet), `hide`
  (keys never listed under "Other" and refused on save: container-breaking ones like `server-ip`, unpublished ports,
  secrets) and `groups[]` (`name`, optional `description`, `fields[]`).
- Field: `key`, `type` (`string`, `number`, `boolean`, `select`), `label`, `description`, `default` (what the game uses
  when the key is missing: shown, not written), `options` and `labels` (`select`: the values as written in the file and
  their display text), `min`, `max`, `integer`, `unit` (`number`), `pattern` (`string`), `since` (first version that has
  the key, inclusive), `until` (first version that no longer has it, exclusive) and `when` (variable values, as for
  variables).
- A key can be declared more than once with disjoint `since`/`until`/`when`: the first field that applies wins (numeric
  `difficulty` before 1.14, names since). Keys `configs.set` manages in the same file can't be declared.

```yaml
settings:
  files:
    - file: server.properties
      format: properties
      others: true
      groups:
        - name: Performance and network
          fields:
            - { key: view-distance, label: View distance, type: number, integer: true, min: 3, max: 32, default: 10, unit: chunks }
            - { key: pause-when-empty-seconds, type: number, integer: true, default: 60, since: "1.21.2" }
```

## Game version (`game_version`)

Where the panel learns which game version is installed, for the Game settings fields and the mod catalogs:

- `file`: a file below `/data` whose first line is the installed version. The install hook writes it, so `latest` is
  resolved (`minecraft-java` writes `gss-version`). It wins when it holds a version.
- `value`: a template of `{{vars.<key>}}` only (`"{{vars.version}}"`), used until the file exists. A value that isn't a
  version (`latest`) counts as unknown.

Versions compare by their numeric parts: `1.21.4 < 26.1`, `1.21 == 1.21.0`.

```yaml
game_version:
  value: "{{vars.version}}"
  file: gss-version
```

## Mods (`mods`)

`mods` adds a Mods tab to a server: a list of folders whose entries are mods. The panel lists them, takes uploads by
drag and drop, disables a mod by moving it to a second folder the game doesn't read (and back), deletes them, and can
install from a catalog with the required dependencies. All of it goes through the file API, so it works for any game
that loads mods from a folder. What the panel installed from a catalog is recorded in `gss-mods.json` at the data root
(title, version, where it came from); entries put there any other way are listed by name.

- `key`: unique in the definition (`mods`, `plugins`, `addons`); folders merge by key with `extends`.
- `label`, `description`: the section title and a sentence under it.
- `folder`: below `/data` (`mods`, `garrysmod/addons`). Created on the first upload or install.
- `disabled_folder`: where disabled mods go. Default `<folder>.disabled`; never inside `folder`.
- `match`: the entry names that count as mods, one path segment each: `*` and `?` match within the name, a trailing
  `/` matches folders only (`["*.jar"]`, `["*/", "*.gma"]`). Other entries are left alone. Uploads must match a file
  pattern; folders can't be uploaded yet.
- `when`: only for some variable values (`{ flavour: [forge, neoforge] }`), as for variables.
- `catalogs`: where mods can be searched and installed from, in the order the tab offers them. Each has `provider`
  (`curseforge` or `modrinth`), `project_type` (the provider's kind: Modrinth `mod`, `plugin`…; CurseForge the class
  slug `mc-mods`, `bukkit-plugins`…), `loaders` (loader names this server runs, templates allowed:
  `["{{vars.flavour}}"]`; CurseForge maps `forge`, `neoforge`, `fabric`, `quilt` to its types; empty = any) and, for
  CurseForge, `game_id` (432 = Minecraft). The panel filters by these and the installed `game_version`, hides
  client-only mods where the catalog knows, checks every download's hash, offers updates, and fetches only from hosts
  on its `MOD_CATALOG_HOSTS`. CurseForge needs the operator's own API key (Settings → Mod catalogs); without one it is
  shown as unavailable.
- `packs`: importing a modpack into the folder. `formats`: `curseforge` (a CurseForge profile or modpack export, its
  `manifest.json` alone or in the zip), `mrpack` (Modrinth) and `zip` (any zip of mod files, e.g. a server pack).
  `overrides`: the top-level folders the pack may also write files into (`[config, defaultconfigs, kubejs]`);
  everything else in the pack is skipped and listed. The import shows a preview first. CurseForge files are downloaded
  with the operator's key; without one the preview links each mod so the owner can download it and drop it in.

```yaml
mods:
  - key: mods
    label: Mods
    folder: mods
    match: ["*.jar"]
    when: { flavour: [forge, neoforge] }
    catalogs:
      - { provider: curseforge, game_id: 432, project_type: mc-mods, loaders: ["{{vars.flavour}}"] }
      - { provider: modrinth, project_type: mod, loaders: ["{{vars.flavour}}"] }
    packs: { formats: [curseforge, mrpack, zip], overrides: [config, defaultconfigs, kubejs] }
  - key: addons            # Garry's Mod: folders and .gma files, no catalog
    folder: garrysmod/addons
    match: ["*/", "*.gma"]
```

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
