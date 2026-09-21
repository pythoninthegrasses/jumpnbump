# Development

Local dev workflow notes that don't fit `docs/build-layout.md` or `docs/porting-playbook.md`.

## Running CI locally with `act`

`.actrc` maps the runner labels (`ubuntu-latest`, `blacksmith-4vcpu-ubuntu-2404`,
`self-hosted`/`macOS`/`ARM64`) so `act` can run the GitHub Actions workflows locally.
A few of its settings have sharp edges worth knowing before trusting a local `act` run:

- **`--container-architecture=linux/arm64`** matches the host (Apple Silicon), but the
  real Linux CI runner (`blacksmith-4vcpu-ubuntu-2404`) is `x86_64`. An arm64 local run
  can't load `x86_64`-only artifacts (e.g. `game/bin/libjumpnbump.linux.*.x86_64.so`) and
  will fail in ways the real runner never would. To get a representative Linux result,
  override the flag: `act push -j linux --container-architecture=linux/amd64`. This runs
  under QEMU emulation and is noticeably slower than the native arm64 path.

- **`--reuse` persists a named Docker *volume*, not just a container.** `docker rm -f` on
  the `act-CI-<job>-<hash>` container does **not** clear the matching
  `act-CI-<job>-<hash>` / `act-CI-<job>-<hash>-env` volumes (or `act-toolcache`), so stale
  build artifacts from a previous run (e.g. `.o` files built for a different
  architecture) can silently survive a container reset and produce misleading link
  errors (`Relocations in generic ELF`, `file in wrong format`) on the next run. To
  actually start clean:

  ```sh
  docker ps -a --filter "name=act-" -q | xargs -r docker rm -f
  docker volume ls --filter "name=act-" -q | xargs -r docker volume rm
  ```

- **`.dockerignore` does not apply.** `act`'s checkout step is a literal
  `docker cp <working dir> <container>`, not a `docker build`, so `.dockerignore` (which
  only filters a build context) is never consulted. `act`'s own `--use-gitignore` flag
  doesn't filter this path either (verified: gitignored files are copied into the
  container regardless of `--use-gitignore=true` or `=false`). The only reliable fix is
  to make sure the host working tree itself is free of stale gitignored build output
  (`*.o`, `sdl.a`, etc.) before running `act` — those files get copied in verbatim and
  can shadow a fresh in-container build.

## Known CI task-graph gaps

- `task game:test` depends on `task game:import` (populates the Godot `.godot/` global
  class cache — without it, `class_name` types like `SimWorld`/`TickDriver` fail to
  resolve on a fresh checkout). See `taskfiles/game.yml`.
- `task check` (the documented CI gate) does **not** build the GDExtension shim
  (`task extension:build` does that separately) — its own docstring says so. Any test
  that touches a native class (e.g. `SimWorld.OK`, which resolves to
  `JumpnbumpWorld.JNB_OK` from the compiled extension) will fail on a truly clean
  checkout once the class-cache gap above is fixed, since nothing in `ci.yml` builds
  `game/bin/libjumpnbump.*` before `game:test` runs. Not yet fixed — tracked as a
  follow-up.
