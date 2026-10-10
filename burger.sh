#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-${TMPDIR:-/tmp}/burgerengine-dotnet}"
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"
mkdir -p "$DOTNET_CLI_HOME"
dotnet restore BurgerEngine.sln
dotnet build BurgerEngine.sln -c Release -nologo --no-restore
exec dotnet src/Burger.Tools/bin/Release/net8.0/burger.dll "$@"
