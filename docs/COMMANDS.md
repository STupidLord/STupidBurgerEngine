# BurgerEngine command reference

Run commands from the repository root unless noted otherwise.

## Prerequisites

- .NET SDK 8 or newer
- A graphical X11 or Wayland session for the game or Studio
- Python 3; map generation additionally needs NumPy, SciPy, and Pillow
- `git`, authenticated `gh`, and `jq` for upstream patch automation

## Build and launch

```bash
dotnet restore BurgerEngine.sln
dotnet build BurgerEngine.sln -c Release
dotnet build src/Burger.Game/Burger.Game.csproj -c Release

./BurgerStudio.sh
./burger.sh
./BurgerEngine.sh run SampleGame
./BurgerEngine.sh run Earth1930 --perf --log-dir logs
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia ./BurgerEngine.sh run Earth1930 --perf --log-dir logs
./WBE.sh
```

The Bash launchers restore and build Release binaries before running. `BurgerEngine.sh` defaults to the CLI `list` command; `burger.sh` is the direct CLI launcher.

`__NV_PRIME_RENDER_OFFLOAD=1` requests NVIDIA PRIME render offload, which runs the game on the discrete NVIDIA GPU instead of the integrated GPU when the system supports PRIME. `__GLX_VENDOR_LIBRARY_NAME=nvidia` tells the GLX loader to use NVIDIA's OpenGL implementation. Together, they launch Earth 1930 using the NVIDIA GPU; they are mainly useful on hybrid-GPU Linux laptops and are unnecessary on systems with only one GPU. The final command, `./BurgerEngine.sh run Earth1930`, builds the engine if needed and starts the Earth 1930 project.

## CLI commands

The CLI is available as `./burger.sh <command>` or as `dotnet src/Burger.Tools/bin/Release/net8.0/burger.dll <command>` after building.

```bash
./burger.sh help
./burger.sh list
./burger.sh presets

./burger.sh new MyGame
./burger.sh new MyGame --preset hoi4 --base isle
./burger.sh new MyGame --blank
./burger.sh new MyGame --preset hoi4 --features military,combat_hoi4,politics

./burger.sh features MyGame
./burger.sh features MyGame add military combat_hoi4
./burger.sh features MyGame remove ai

./burger.sh validate MyGame
./burger.sh validate MyGame --days 30
./burger.sh validate MyGame --days 60 --profile

./burger.sh run MyGame
./burger.sh run MyGame --tag USA

./burger.sh export MyGame
./burger.sh export MyGame --name MyGame
./burger.sh export MyGame --name MyGame --out projects/MyGame/export/custom
./burger.sh export MyGame --name MyGame --rid win-x64

./burger.sh generate-locations MyGame
./burger.sh docs
./burger.sh docs MyGame
```

Project arguments can be names such as `MyGame` or project paths. Feature removal moves changed files to `removed_features/<feature-id>/`. `burger validate` checks data and simulates the requested number of days headlessly. `burger docs` regenerates `docs/SCRIPT_REFERENCE.md`.

## Direct binaries and runtime options

```bash
dotnet src/Burger.Game/bin/Release/net8.0/Burger.Game.dll --game projects/SampleGame/game
dotnet src/Burger.Game/bin/Release/net8.0/Burger.Game.dll --game projects/Earth1930/game --observe
dotnet src/Burger.Game/bin/Release/net8.0/Burger.Game.dll --game projects/Earth1930/game --perf --size 1280x720 --log-dir logs
dotnet src/Burger.Studio/bin/Release/net8.0/BurgerStudio.dll
```

Common runtime options are `--game <folder>`, `--observe`, `--perf`, `--size WIDTHxHEIGHT`, `--log-dir <folder>`, and `--tag <TAG>` where supported. Runtime errors normally go to `logs/error.log`.

## UI and asset tools

```bash
tools/compress-ui-bg.sh --help
tools/compress-ui-bg.sh
tools/compress-ui-bg.sh --apply --jobs 4
tools/compress-ui-bg.sh --dir assets/ui/bg --apply

python3 tools/ui-bg-preview.py
python3 tools/ui-bg-preview.py --source assets/ui/bg --output /tmp/ui-bg-preview.html

python3 tools/assets/make_ui_gfx.py projects/MyGame/game
python3 tools/assets/backend_gen.py src/Burger.Core assets/backend
```

`compress-ui-bg.sh` is a dry run unless `--apply` is supplied. It uses `oxipng`, `zopflipng`, or Pillow and verifies decoded pixels before replacement. The UI generator writes editable textures to a project's `game/gfx/interface/ui/` directory.

## Earth map and population tools

Run these from `tools/earth/`:

```bash
cd tools/earth
python3 get_elevation.py elev_z5.npy
python3 make_earth.py <geojson-dir> elev_z5.npy ../../assets_src/earth1930/game
python3 make_pops.py <pop_units.json> ../../projects/Earth1930/game
cd ../..
```

The map source is `assets_src/earth1930/game`; generated wizard assets are copied to `assets/bases/earth1930`. See `tools/earth/README.txt` for Natural Earth inputs and required layers.

## Testing and inspection

```bash
dotnet restore BurgerEngine.sln
dotnet build BurgerEngine.sln -c Release --no-restore
./burger.sh validate SampleGame --days 60 --profile
dotnet build src/Burger.Game/Burger.Game.csproj -c Release

git status --short --branch
git diff --stat
git log -10 --oneline --decorate
```

There is no conventional .NET test project in the repository; project validation and headless simulation are performed by `burger validate`.

## Git and upstream patch automation

`tools/burger.sh` applies one verified, non-merge upstream commit to a clean GitHub fork. It creates a new branch, never pushes, retries conflicts with `-X theirs`, and runs detected tests.

```bash
tools/burger.sh
gh auth status
gh auth login
./tools/burger.sh https://github.com/BurgerKingHotline/BurgerEngine.git FULL_40_CHARACTER_SHA

git remote -v
git fetch --no-tags <remote-url> <sha>
git show --stat <sha>
git switch -c feature/my-change
git cherry-pick <sha>
git cherry-pick --abort
git diff main...HEAD
```

The automation rejects merge commits and restores the original branch if it cannot apply the patch automatically.

To validate, commit, rebase onto `origin/main`, and push directly to the remote `main` branch, run this from a change branch:

```bash
tools/check-rebase-push-main.sh "Describe the change"
```

The script runs `./burger.sh validate SampleGame --days 60`, displays the pending changes, asks for confirmation before staging and rebasing, asks again before pushing, and refuses to run from `main`. After a successful push, it fast-forwards and selects local `main`, then deletes the original change branch. Override the validation command when needed with `CHECK_CMD='...' tools/check-rebase-push-main.sh "message"`. It uses `git add -A`, so all tracked and untracked changes are included; inspect the displayed status carefully.

## Output locations

- Logs: `logs/`, or the directory passed to `--log-dir`
- Saves: `saves/` beside the running game
- Exports: `projects/<Project>/export/<Name>/`
- Script reference: `docs/SCRIPT_REFERENCE.md`
- UI preview: `assets/ui/bg/ui-bg-preview.html`

Avoid committing temporary logs, saves, previews, or build output unless the generated file is an intentional repository asset.
