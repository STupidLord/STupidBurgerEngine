# Safely cherry-pick one verified upstream commit onto a GitHub fork.
# PowerShell 7+ version of burger.sh. Never pushes.
# Test failures leave the patch branch available for inspection.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $SourceUrl,
    [Parameter(Position = 1)]
    [string] $Commit
)

$ErrorActionPreference = 'Stop'

function Fail([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function Usage {
    @'
Usage (run inside the destination fork's clean Git working tree):
  pwsh -File .\burger.ps1 https://github.com/OWNER/UPSTREAM.git FULL_COMMIT_SHA

Optional custom test command:
  $env:PATCH_TEST_CMD = 'dotnet test; ./scripts/smoke-test.ps1'
  pwsh -File .\burger.ps1 URL SHA

Requires: git, gh (authenticated with GitHub). Test tools are project-specific.
'@ | Write-Host
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $File,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $FailureMessage = "$File failed.",
        [switch] $Capture
    )
    if ($Capture) {
        $output = (& $File @Arguments 2>&1 | Out-String).Trim()
    } else {
        & $File @Arguments
        $output = $null
    }
    if ($LASTEXITCODE -ne 0) { Fail $FailureMessage }
    if ($Capture) { return $output }
}

if (-not $SourceUrl -or -not $Commit) {
    Usage
    exit 2
}

$Commit = $Commit.ToLowerInvariant()
if ($Commit -notmatch '^[0-9a-f]{40}$') {
    Fail 'Provide the full 40-character Git commit SHA, not a branch name or abbreviated SHA.' 2
}

foreach ($command in @('git', 'gh')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "Missing dependency: $command"
    }
}
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Authenticate first with: gh auth login' }

$root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $root) { Fail "Run this inside the destination fork clone." }
Set-Location $root

$status = (& git status --porcelain --untracked-files=all | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Fail 'Could not inspect Git working-tree status.' }
if ($status) { Fail 'Working tree is not clean. Commit or stash changes first.' }

$originUrl = (& git remote get-url origin 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $originUrl) { Fail 'Destination repo must have an origin remote.' }

$sourceJson = Invoke-Checked gh @('repo', 'view', $SourceUrl, '--json', 'nameWithOwner') 'Could not identify source GitHub repository.' -Capture
$destJson = Invoke-Checked gh @('repo', 'view', $originUrl, '--json', 'nameWithOwner') 'Could not identify destination origin on GitHub.' -Capture
$sourceRepo = ($sourceJson | ConvertFrom-Json).nameWithOwner
$destRepo = ($destJson | ConvertFrom-Json).nameWithOwner

$destApi = Invoke-Checked gh @('api', "repos/$destRepo") "Could not read GitHub metadata for destination $destRepo." -Capture
try { $dest = $destApi | ConvertFrom-Json } catch { Fail "GitHub returned invalid repository JSON for $destRepo." }

if ($dest.fork -ne $true) { Fail "$destRepo is not marked as a GitHub fork. No changes made." }
$parentRepo = [string]$dest.parent.full_name
if (-not $parentRepo) { Fail "$destRepo is marked as a fork, but GitHub returned no parent.full_name metadata. No changes made." }
if ($parentRepo -ine $sourceRepo) { Fail "$destRepo is a fork of '$parentRepo', not '$sourceRepo'. No changes made." }
Write-Host "Fork verified: $destRepo -> $sourceRepo"

$apiSha = Invoke-Checked gh @('api', "repos/$sourceRepo/commits/$Commit", '--jq', '.sha') "Commit $Commit was not found in $sourceRepo." -Capture
if ($apiSha.Trim().ToLowerInvariant() -ne $Commit) { Fail 'GitHub returned a different commit SHA.' }
Invoke-Checked git @('fetch', '--no-tags', $SourceUrl, $Commit) 'Could not fetch the requested commit.'
Invoke-Checked git @('cat-file', '-e', "$Commit^{commit}") 'Fetched object is not a commit.'

& git merge-base --is-ancestor $Commit HEAD
if ($LASTEXITCODE -eq 0) {
    Write-Host "Commit $Commit is already an ancestor of HEAD; nothing to apply."
    exit 0
}

$parentLine = (& git rev-list --parents -n 1 $Commit | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Fail 'Could not inspect commit parents.' }
$parentCount = @($parentLine -split '\s+').Count - 1
if ($parentCount -gt 1) { Fail 'Merge commits are intentionally rejected: select a non-merge commit to avoid guessing its mainline.' }
if ($parentCount -eq 0) { Fail 'Root commits have no parent to compare against and are not supported by this one-commit cherry-pick workflow.' }

$base = (& git rev-parse HEAD | Out-String).Trim()
$originalBranch = (& git branch --show-current | Out-String).Trim()
$short = $Commit.Substring(0, 12)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$branch = "auto-patch/$short-$stamp-$PID"
Invoke-Checked git @('switch', '-c', $branch) 'Could not create the patch branch.'

function Restore-OriginalBranch {
    & git cherry-pick --abort *> $null
    if ($script:originalBranch) {
        & git switch $script:originalBranch *> $null
        if ($LASTEXITCODE -ne 0) { & git switch --detach $script:base *> $null }
    } else {
        & git switch --detach $script:base *> $null
    }
    & git branch -D $script:branch *> $null
}

Write-Host "Attempting a normal cherry-pick of $Commit..."
& git -c advice.mergeConflict=false cherry-pick --no-edit $Commit
if ($LASTEXITCODE -eq 0) {
    $resolution = 'clean cherry-pick'
} else {
    $unmerged = (& git ls-files -u | Out-String).Trim()
    if ($unmerged) {
        Write-Host "`nConflict detected. Aborting the first attempt and retrying with Git strategy option -X theirs."
        & git cherry-pick --abort
        if ($LASTEXITCODE -ne 0) {
            Restore-OriginalBranch
            Fail 'Could not abort the conflicted cherry-pick cleanly; returned to the original branch if possible.'
        }
        & git -c advice.mergeConflict=false cherry-pick --no-edit -X theirs $Commit
        if ($LASTEXITCODE -eq 0) {
            $resolution = 'automatic -X theirs merge (incoming side wins overlapping hunks; nearby fork edits in the same hunk may be replaced)'
        } else {
            Restore-OriginalBranch
            Fail 'Git could not automatically resolve all conflicts, even with -X theirs. Original branch restored; no patch branch retained.'
        }
    } else {
        Restore-OriginalBranch
        Fail 'Cherry-pick failed for a non-conflict reason. Original branch restored; inspect Git identity/hooks and retry.'
    }
}

Write-Host "Patch applied using $resolution."

function Invoke-Tests {
    if ($env:PATCH_TEST_CMD) {
        Write-Host "Running custom tests: $env:PATCH_TEST_CMD"
        Invoke-Expression $env:PATCH_TEST_CMD
        if ($null -ne $LASTEXITCODE) { return $LASTEXITCODE }
        return 0
    } elseif ((Test-Path Cargo.toml) -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
        & cargo test
        return $LASTEXITCODE
    } elseif ((Test-Path go.mod) -and (Get-Command go -ErrorAction SilentlyContinue)) {
        & go test ./...
        return $LASTEXITCODE
    } elseif ((Test-Path package.json) -and (Get-Command node -ErrorAction SilentlyContinue)) {
        try { $package = Get-Content package.json -Raw | ConvertFrom-Json } catch { $package = $null }
        if ($package -and $package.scripts -and $package.scripts.test -is [string]) {
            if ((Test-Path pnpm-lock.yaml) -and (Get-Command pnpm -ErrorAction SilentlyContinue)) { & pnpm test }
            elseif ((Test-Path yarn.lock) -and (Get-Command yarn -ErrorAction SilentlyContinue)) { & yarn test }
            elseif (Get-Command npm -ErrorAction SilentlyContinue) { & npm test }
            else { [Console]::Error.WriteLine('No Node package manager found.'); return 125 }
            return $LASTEXITCODE
        }
    } elseif ((Test-Path pyproject.toml) -or (Test-Path pytest.ini) -or (Test-Path setup.cfg)) {
        if (Get-Command python -ErrorAction SilentlyContinue) {
            & python -c 'import pytest' *> $null
            if ($LASTEXITCODE -eq 0) { & python -m pytest; return $LASTEXITCODE }
            if ((Test-Path tests) -or (Test-Path test)) { & python -m unittest discover; return $LASTEXITCODE }
        }
        [Console]::Error.WriteLine('Python project found, but no supported test runner/tests detected.')
        return 125
    } elseif (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $solution = Get-ChildItem -Path . -Recurse -File -Include *.sln,*.slnx -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj)[\\/]' } | Select-Object -First 1
        $testProject = Get-ChildItem -Path . -Recurse -File -Filter '*test*.csproj' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj)[\\/]' } | Select-Object -First 1
        if ($solution) { & dotnet test $solution.FullName --verbosity minimal; return $LASTEXITCODE }
        if ($testProject) { & dotnet test $testProject.FullName --verbosity minimal; return $LASTEXITCODE }
        [Console]::Error.WriteLine("No .NET solution or test project detected. Set PATCH_TEST_CMD to the project's test/build command.")
        return 125
    } elseif ((Test-Path Makefile) -and (Get-Command make -ErrorAction SilentlyContinue)) {
        if (Select-String -Path Makefile -Pattern '^\s*test\s*:' -Quiet) { & make test; return $LASTEXITCODE }
    } elseif ((Test-Path build/CTestTestfile.cmake) -and (Get-Command ctest -ErrorAction SilentlyContinue)) {
        & ctest --test-dir build --output-on-failure
        return $LASTEXITCODE
    }
    [Console]::Error.WriteLine('No supported test command detected. Set PATCH_TEST_CMD to the project test command.')
    return 125
}

$testStatus = Invoke-Tests
if ($testStatus -eq 0) {
    Write-Host "`nSUCCESS: patch applied and tests passed.`nResolution: $resolution`nBranch: $branch`nNothing was pushed. Review with: git show --stat HEAD"
} elseif ($testStatus -eq 125) {
    [Console]::Error.WriteLine("`nPATCH APPLIED, BUT TESTS WERE NOT RUN.`nResolution: $resolution`nBranch: $branch`nSet PATCH_TEST_CMD or review with: git show --stat HEAD")
    exit 2
} else {
    [Console]::Error.WriteLine("`nPATCH APPLIED, BUT TESTS FAILED (exit $testStatus).`nResolution: $resolution`nBranch: $branch`nThe original branch remains untouched. Inspect the failure before deciding whether to keep this commit.")
    exit 1
}
