# Safely cherry-pick one verified upstream commit onto a GitHub fork.
# PowerShell 7+. Never pushes. Diagnostic output is intentionally detailed:
# every important phase, command, result, changed path, conflict, and test action
# is surfaced for a developer debugging the cherry-pick.
# Test failures leave the patch branch available for inspection.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $SourceUrl,
    [Parameter(Position = 1)]
    [string] $Commit
)

$ErrorActionPreference = 'Stop'
$script:LogSequence = 0

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('PHASE','INFO','CMD','OUT','OK','WARN','ERROR','DEBUG')][string] $Level,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message
    )
    $script:LogSequence++
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'
    $line = '[{0} #{1:D4}] [{2,-5}] {3}' -f $time, $script:LogSequence, $Level, $Message
    $color = switch ($Level) {
        'PHASE' { 'Cyan' }
        'CMD'   { 'DarkCyan' }
        'OUT'   { 'DarkGray' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-Phase([string] $Title) {
    Write-Host ''
    Write-Log PHASE ('=' * 88)
    Write-Log PHASE $Title
    Write-Log PHASE ('=' * 88)
}

function Get-SafeText([string] $Value) {
    if ($null -eq $Value) { return '' }
    # Avoid printing embedded HTTP(S) credentials in remote URLs or arguments.
    return ($Value -replace '(?i)(https?://)[^/@\s]+@', '$1[credentials-redacted]@')
}

function Format-CommandLine {
    param([string] $File, [string[]] $Arguments)
    $shown = foreach ($argument in $Arguments) {
        $safe = Get-SafeText ([string]$argument)
        if ($safe -match '[\s"'']') {
            '"' + ($safe -replace '"', '\"') + '"'
        } else {
            $safe
        }
    }
    return ((Get-SafeText $File) + ' ' + ($shown -join ' ')).Trim()
}

function Fail([string] $Message, [int] $Code = 1) {
    Write-Log ERROR $Message
    Write-Log ERROR "Terminating with exit code $Code. No push operation is performed by this script."
    exit $Code
}

function Usage {
    @'
Usage (run inside the destination fork's clean Git working tree):
  pwsh -File .\burger-max-verbose.ps1 https://github.com/OWNER/UPSTREAM.git FULL_COMMIT_SHA

Optional custom test command:
  $env:PATCH_TEST_CMD = 'dotnet test; ./scripts/smoke-test.ps1'
  pwsh -File .\burger-max-verbose.ps1 URL SHA

Requires: PowerShell 7+, git, gh (authenticated with GitHub).
The script creates a local patch branch and NEVER pushes.
'@ | Write-Host
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $File,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $FailureMessage = "$File failed.",
        [switch] $Capture,
        [switch] $AllowFailure,
        [switch] $SuppressOutput
    )

    Write-Log CMD (Format-CommandLine $File $Arguments)
    $items = @(& $File @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $lines = @($items | ForEach-Object { [string]$_ })
    if ($SuppressOutput) {
        Write-Log DEBUG ("Captured {0} output line(s); raw output intentionally omitted because the caller parses structured fields." -f $lines.Count)
    } else {
        foreach ($line in $lines) { Write-Log OUT $line }
    }
    Write-Log $(if ($exitCode -eq 0) { 'OK' } else { 'WARN' }) ("exit code: {0}" -f $exitCode)

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        Fail "$FailureMessage (exit code $exitCode). See the command and output immediately above."
    }
    if ($Capture) { return ($lines -join "`n") }
}

function Write-GitSnapshot([string] $Label) {
    Write-Log INFO $Label
    $branch = Invoke-Checked git @('branch', '--show-current') 'Could not determine the current branch.' -Capture
    $head = Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve HEAD.' -Capture
    $shortHead = Invoke-Checked git @('rev-parse', '--short=12', 'HEAD') 'Could not resolve short HEAD.' -Capture
    $status = Invoke-Checked git @('status', '--short', '--branch', '--untracked-files=all') 'Could not inspect repository status.' -Capture
    Write-Log INFO ("Current branch: {0}" -f $(if ($branch.Trim()) { $branch.Trim() } else { '(detached HEAD)' }))
    Write-Log INFO ("HEAD: {0} ({1})" -f $head.Trim(), $shortHead.Trim())
    if ($status.Trim()) {
        Write-Log INFO 'Working-tree status follows (branch line plus changed/untracked paths):'
        foreach ($line in ($status -split "`n")) { Write-Log INFO $line }
    } else {
        Write-Log INFO 'Git status command returned no lines.'
    }
}

if (-not $SourceUrl -or -not $Commit) {
    Usage
    exit 2
}

$Commit = $Commit.ToLowerInvariant()
Write-Phase 'Invocation and runtime'
Write-Log INFO ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
Write-Log INFO ("Edition: {0}; OS: {1}" -f $PSVersionTable.PSEdition, [System.Runtime.InteropServices.RuntimeInformation]::OSDescription)
Write-Log INFO ("Process ID: {0}; started: {1}" -f $PID, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Write-Log INFO ("Working directory on entry: {0}" -f (Get-Location).Path)
Write-Log INFO ("Source repository input: {0}" -f (Get-SafeText $SourceUrl))
Write-Log INFO ("Requested commit: {0}" -f $Commit)
Write-Log INFO 'Safety invariants: require clean worktree; validate GitHub fork parent; reject merge/root commits; do not push.'

if ($Commit -notmatch '^[0-9a-f]{40}$') {
    Fail 'Provide the full 40-character Git commit SHA, not a branch name or abbreviated SHA.' 2
}

Write-Phase 'Dependency and authentication checks'
foreach ($command in @('git', 'gh')) {
    $resolved = Get-Command $command -ErrorAction SilentlyContinue
    if (-not $resolved) { Fail "Missing dependency: $command" }
    Write-Log INFO ("{0} executable: {1}" -f $command, $resolved.Source)
}
Invoke-Checked git @('--version') 'Could not read Git version.'
Invoke-Checked gh @('--version') 'Could not read GitHub CLI version.'
Invoke-Checked gh @('auth', 'status') 'GitHub CLI authentication failed. Authenticate with: gh auth login'

Write-Phase 'Locate and validate destination working tree'
$root = (Invoke-Checked git @('rev-parse', '--show-toplevel') 'Run this inside the destination fork clone.' -Capture).Trim()
if (-not $root) { Fail 'Git returned an empty repository root. Run this inside the destination fork clone.' }
Set-Location $root
Write-Log INFO ("Repository root: {0}" -f $root)
Write-GitSnapshot 'Initial repository snapshot, before any fetch or branch creation:'

$statusPorcelain = (Invoke-Checked git @('status', '--porcelain=v1', '--untracked-files=all') 'Could not inspect Git working-tree status.' -Capture).Trim()
if ($statusPorcelain) {
    Write-Log ERROR 'Refusing to proceed because the destination worktree/index is not clean.'
    Write-Log ERROR 'Every status entry below must be committed or stashed before retrying:'
    foreach ($line in ($statusPorcelain -split "`n")) { Write-Log ERROR $line }
    Fail 'Working tree is not clean. No branch has been created by this script.'
}
Write-Log OK 'Precondition passed: tracked files, index, and untracked files are clean.'

$originUrl = (Invoke-Checked git @('remote', 'get-url', 'origin') 'Destination repo must have an origin remote.' -Capture).Trim()
if (-not $originUrl) { Fail 'Destination repo must have an origin remote.' }
Write-Log INFO ("origin URL: {0}" -f (Get-SafeText $originUrl))
Invoke-Checked git @('remote') 'Could not list configured remote names.'
Invoke-Checked git @('branch', '-vv', '--no-abbrev') 'Could not list local branches and upstream tracking references.'
Invoke-Checked git @('config', '--show-origin', '--get-regexp', '^(user\.(name|email)|commit\.gpgsign|gpg\.format|core\.hooksPath)$') 'Git configuration query failed.' -AllowFailure
Invoke-Checked git @('var', 'GIT_AUTHOR_IDENT') 'Could not resolve Git author identity; inspect user.name/user.email.'
Invoke-Checked git @('var', 'GIT_COMMITTER_IDENT') 'Could not resolve Git committer identity; inspect user.name/user.email.'

Write-Phase 'Verify source repository and GitHub fork relationship'
$sourceJson = Invoke-Checked gh @('repo', 'view', $SourceUrl, '--json', 'nameWithOwner') 'Could not identify source GitHub repository.' -Capture
$destJson = Invoke-Checked gh @('repo', 'view', $originUrl, '--json', 'nameWithOwner') 'Could not identify destination origin on GitHub.' -Capture
try {
    $sourceRepo = ($sourceJson | ConvertFrom-Json).nameWithOwner
    $destRepo = ($destJson | ConvertFrom-Json).nameWithOwner
} catch {
    Fail "Could not parse GitHub repository-identification response: $($_.Exception.Message)"
}
if (-not $sourceRepo -or -not $destRepo) { Fail 'GitHub did not return both source and destination repository names.' }
Write-Log INFO ("Resolved source repository: {0}" -f $sourceRepo)
Write-Log INFO ("Resolved destination repository (origin): {0}" -f $destRepo)

$destApi = Invoke-Checked gh @('api', "repos/$destRepo") "Could not read GitHub metadata for destination $destRepo." -Capture -SuppressOutput
try { $dest = $destApi | ConvertFrom-Json } catch { Fail "GitHub returned invalid repository JSON for $destRepo." }
Write-Log INFO ("GitHub says destination fork flag: {0}" -f $dest.fork)
$parentRepo = [string]$dest.parent.full_name
Write-Log INFO ("GitHub says destination parent: {0}" -f $(if ($parentRepo) { $parentRepo } else { '(missing)' }))
if ($dest.fork -ne $true) { Fail "$destRepo is not marked as a GitHub fork. No changes made." }
if (-not $parentRepo) { Fail "$destRepo is marked as a fork, but GitHub returned no parent.full_name metadata. No changes made." }
if ($parentRepo -ine $sourceRepo) { Fail "$destRepo is a fork of '$parentRepo', not '$sourceRepo'. No changes made." }
Write-Log OK ("Fork relationship verified: {0} -> {1}" -f $destRepo, $sourceRepo)

Write-Phase 'Validate and fetch the requested commit'
$apiSha = Invoke-Checked gh @('api', "repos/$sourceRepo/commits/$Commit", '--jq', '.sha') "Commit $Commit was not found in $sourceRepo." -Capture
if ($apiSha.Trim().ToLowerInvariant() -ne $Commit) { Fail "GitHub returned SHA '$($apiSha.Trim())', which does not match requested SHA '$Commit'." }
Write-Log OK "GitHub API confirms full commit SHA: $Commit"

$fetchArgs = @('fetch', '--verbose', '--progress', '--no-tags', $SourceUrl, $Commit)
Write-Log CMD (Format-CommandLine git $fetchArgs)
& git fetch --verbose --progress --no-tags $SourceUrl $Commit
$fetchExit = $LASTEXITCODE
Write-Log $(if ($fetchExit -eq 0) { 'OK' } else { 'ERROR' }) ("git fetch exit code: {0}" -f $fetchExit)
if ($fetchExit -ne 0) { Fail "Could not fetch requested commit $Commit from $SourceUrl (exit code $fetchExit)." }
Invoke-Checked git @('cat-file', '-e', "$Commit^{commit}") 'Fetched object is not a commit.'
Invoke-Checked git @('show', '-s', '--format=fuller', '--decorate=full', $Commit) 'Could not read fetched commit metadata.'
Invoke-Checked git @('show', '--stat', '--summary', '--find-renames', $Commit) 'Could not produce commit summary.'

$parentLine = (Invoke-Checked git @('rev-list', '--parents', '-n', '1', $Commit) 'Could not inspect commit parents.' -Capture).Trim()
$parentIds = @($parentLine -split '\s+' | Select-Object -Skip 1)
$parentCount = $parentIds.Count
Write-Log INFO ("Commit object/parent line: {0}" -f $parentLine)
Write-Log INFO ("Parent count: {0}" -f $parentCount)
if ($parentCount -gt 1) { Fail 'Merge commits are intentionally rejected: select a non-merge commit to avoid guessing its mainline.' }
if ($parentCount -eq 0) { Fail 'Root commits have no parent to compare against and are not supported by this one-commit cherry-pick workflow.' }
$commitParent = $parentIds[0]
Write-Log INFO ("First and only parent: {0}" -f $commitParent)

Write-Phase 'Inspect the exact upstream change before applying it'
Write-Log INFO 'Commit summary and changed-file statistics:'
Invoke-Checked git @('show', '--format=fuller', '--find-renames', '--stat', '--summary', $Commit) 'Could not display commit summary.'
Write-Log INFO 'Changed paths with status (A/M/D/R/etc.):'
Invoke-Checked git @('diff', '--find-renames', '--name-status', $commitParent, $Commit) 'Could not list changed paths.'
Write-Log INFO 'Per-file insertion/deletion counts:'
Invoke-Checked git @('diff', '--find-renames', '--numstat', $commitParent, $Commit) 'Could not calculate change counts.'
Write-Log INFO 'Whitespace/error check on the upstream patch (non-zero is reported but is not an automatic stop):'
Invoke-Checked git @('diff', '--check', $commitParent, $Commit) 'Could not run git diff --check.' -AllowFailure
Write-Log INFO 'Full textual patch from the commit parent to the target commit follows. Binary files are summarized by Git rather than dumping binary payloads.'
$patchArgs = @('diff', '--no-ext-diff', '--no-color', '--find-renames', '--submodule=log', $commitParent, $Commit)
Write-Log CMD (Format-CommandLine git $patchArgs)
& git diff --no-ext-diff --no-color --find-renames --submodule=log $commitParent $Commit
$patchExit = $LASTEXITCODE
Write-Log $(if ($patchExit -eq 0) { 'OK' } else { 'WARN' }) ("Upstream patch display exit code: {0}" -f $patchExit)
if ($patchExit -ne 0) { Fail 'Could not display the upstream patch; refusing to continue without a reliable pre-apply review.' }

Write-Phase 'Check whether the commit is already in the current history'
$base = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve destination HEAD.' -Capture).Trim()
$originalBranch = (Invoke-Checked git @('branch', '--show-current') 'Could not determine original branch name.' -Capture).Trim()
Write-Log INFO ("Original HEAD (rollback target): {0}" -f $base)
Write-Log INFO ("Original branch name: {0}" -f $(if ($originalBranch) { $originalBranch } else { '(detached HEAD)' }))
Write-Log CMD (Format-CommandLine git @('merge-base', '--is-ancestor', $Commit, 'HEAD'))
& git merge-base --is-ancestor $Commit HEAD
$ancestorExit = $LASTEXITCODE
Write-Log INFO ("git merge-base --is-ancestor exit code: {0} (0=already ancestor; 1=not ancestor; >1=error)" -f $ancestorExit)
if ($ancestorExit -eq 0) {
    Write-Log OK "Commit $Commit is already an ancestor of HEAD; nothing to apply."
    exit 0
}
if ($ancestorExit -gt 1) { Fail 'git merge-base --is-ancestor failed for an unexpected reason.' }

$short = $Commit.Substring(0, 12)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$branch = "auto-patch/$short-$stamp-$PID"
# Recovery is a nested function, so retain its inputs explicitly in script scope.
$script:base = $base
$script:originalBranch = $originalBranch
$script:branch = $branch
Write-Log INFO ("New working branch will be: {0}" -f $branch)
Write-Log INFO ("Original HEAD is preserved as rollback target: {0}" -f $base)
Invoke-Checked git @('switch', '-c', $branch) 'Could not create the patch branch.'
Write-GitSnapshot 'Repository snapshot immediately after creating the patch branch:'

function Restore-OriginalBranch {
    Write-Phase 'Recovery: restore original checkout after failed cherry-pick'
    Write-Log WARN 'Attempting to abort any in-progress cherry-pick before switching branches.'
    Invoke-Checked git @('cherry-pick', '--abort') 'git cherry-pick --abort returned non-zero during recovery.' -AllowFailure

    $restored = $false
    if ($script:originalBranch) {
        Write-Log INFO ("Restoring original branch: {0}" -f $script:originalBranch)
        Invoke-Checked git @('switch', $script:originalBranch) 'Could not switch back to original branch.' -AllowFailure
        if ($LASTEXITCODE -eq 0) { $restored = $true }
    } else {
        Write-Log INFO 'The original checkout was detached; restoring the exact original HEAD.'
    }

    if (-not $restored) {
        Write-Log WARN ("Attempting detached checkout of rollback target {0}." -f $script:base)
        Invoke-Checked git @('switch', '--detach', $script:base) 'Could not restore original HEAD in detached mode.' -AllowFailure
        if ($LASTEXITCODE -eq 0) { $restored = $true }
    }

    if ($restored) {
        Write-Log OK 'Original checkout/HEAD restored.'
        Write-Log INFO ("Removing temporary patch branch if it is safe to delete: {0}" -f $script:branch)
        Invoke-Checked git @('branch', '-D', $script:branch) 'Could not remove temporary failed patch branch.' -AllowFailure
    } else {
        Write-Log ERROR 'Could not restore the original checkout automatically. The temporary patch branch is intentionally preserved for manual recovery.'
        Write-Log ERROR ("Expected rollback target: {0}; temporary branch: {1}" -f $script:base, $script:branch)
        Invoke-Checked git @('status', '--short', '--branch') 'Could not report recovery status.' -AllowFailure
    }
}

Write-Phase 'Cherry-pick attempt 1: normal three-way application'
Write-Log INFO 'Git is asked to apply the commit without editing its default message.'
$normalArgs = @('-c', 'advice.mergeConflict=false', 'cherry-pick', '--no-edit', $Commit)
Write-Log CMD (Format-CommandLine git $normalArgs)
& git -c advice.mergeConflict=false cherry-pick --no-edit $Commit
$normalExit = $LASTEXITCODE
Write-Log $(if ($normalExit -eq 0) { 'OK' } else { 'WARN' }) ("Normal cherry-pick exit code: {0}" -f $normalExit)

if ($normalExit -eq 0) {
    $resolution = 'clean cherry-pick'
    Write-Log OK 'Normal cherry-pick completed without Git reporting a conflict.'
} else {
    Write-Phase 'Diagnose failed normal cherry-pick'
    $unmerged = (Invoke-Checked git @('ls-files', '-u') 'Could not inspect unmerged index entries.' -Capture -AllowFailure).Trim()
    if ($unmerged) {
        Write-Log WARN 'Unmerged index entries exist. This is a conflict path; details follow.'
        Write-Log INFO 'Unmerged index stages (mode/object/stage/path):'
        foreach ($line in ($unmerged -split "`n")) { Write-Log INFO $line }
        Write-Log INFO 'Conflicted path names:'
        Invoke-Checked git @('diff', '--name-only', '--diff-filter=U') 'Could not list conflicted paths.' -AllowFailure
        Write-Log INFO 'Current status while conflicts are present:'
        Invoke-Checked git @('status', '--short', '--branch') 'Could not inspect conflict status.' -AllowFailure
        Write-Log INFO 'Combined conflict diff follows (conflict markers and competing hunks are useful when reviewing the automatic fallback):'
        Invoke-Checked git @('diff', '--cc', '--no-ext-diff', '--no-color') 'Could not display combined conflict diff.' -AllowFailure

        Write-Log WARN 'Aborting the first attempt before retrying. The fallback uses -X theirs: incoming-commit content wins in overlapping conflicting hunks; this does not mean every file is replaced wholesale.'
        Invoke-Checked git @('cherry-pick', '--abort') 'Could not abort first conflicted cherry-pick.'
        Invoke-Checked git @('status', '--short', '--branch') 'Could not confirm state after cherry-pick abort.'

        Write-Phase 'Cherry-pick attempt 2: retry with -X theirs'
        Write-Log WARN 'Applying Git strategy option -X theirs can discard fork-side edits inside overlapping conflict hunks. Review the resulting diff before merging or pushing.'
        $theirsArgs = @('-c', 'advice.mergeConflict=false', 'cherry-pick', '--no-edit', '-X', 'theirs', $Commit)
        Write-Log CMD (Format-CommandLine git $theirsArgs)
        & git -c advice.mergeConflict=false cherry-pick --no-edit -X theirs $Commit
        $theirsExit = $LASTEXITCODE
        Write-Log $(if ($theirsExit -eq 0) { 'OK' } else { 'WARN' }) ("-X theirs cherry-pick exit code: {0}" -f $theirsExit)
        if ($theirsExit -eq 0) {
            $resolution = 'automatic -X theirs merge (incoming side wins overlapping hunks; nearby fork edits in the same hunk may be replaced)'
        } else {
            Write-Log ERROR 'The -X theirs retry failed. Do not assume this was a merge conflict; hooks, signing, identity, or another Git operation may have failed.'
            Write-Log INFO 'Repository status after the failed retry:'
            Invoke-Checked git @('status', '--short', '--branch') 'Could not inspect failed retry status.' -AllowFailure
            Write-Log INFO 'Unmerged index entries after the failed retry:'
            Invoke-Checked git @('ls-files', '-u') 'Could not inspect failed retry index entries.' -AllowFailure
            Write-Log INFO 'Staged diff summary after the failed retry:'
            Invoke-Checked git @('diff', '--cached', '--stat') 'Could not inspect failed retry staged diff.' -AllowFailure
            Write-Log INFO 'Staged diff after the failed retry:'
            Invoke-Checked git @('diff', '--cached', '--no-ext-diff', '--no-color') 'Could not inspect failed retry staged patch.' -AllowFailure
            Write-Log INFO 'Combined conflict diff after the failed retry:'
            Invoke-Checked git @('diff', '--cc', '--no-ext-diff', '--no-color') 'Could not inspect failed retry conflict diff.' -AllowFailure
            Restore-OriginalBranch
            Fail "The -X theirs retry failed (exit code $theirsExit). Recovery was attempted; inspect the diagnostics above."
        }
    } else {
        # An empty cherry-pick has CHERRY_PICK_HEAD but no unmerged index entries.
        Write-Log WARN 'No unmerged index entries were found. This is not an ordinary content conflict; checking for an empty cherry-pick or another Git failure.'
        Write-Log CMD 'git rev-parse -q --verify CHERRY_PICK_HEAD'
        $cherryPickHead = (& git rev-parse -q --verify CHERRY_PICK_HEAD 2>$null | Out-String).Trim()
        $cherryPickHeadExit = $LASTEXITCODE
        Write-Log DEBUG ("git rev-parse CHERRY_PICK_HEAD exit code: {0}; value: {1}" -f $cherryPickHeadExit, $(if ($cherryPickHead) { $cherryPickHead } else { '(none)' }))
        if ($cherryPickHeadExit -eq 0 -and $cherryPickHead) {
            Write-Log WARN 'Git has CHERRY_PICK_HEAD without unresolved paths. Before classifying it as empty, checking whether the index actually contains an applied patch.'
            Invoke-Checked git @('status', '--short', '--branch') 'Could not inspect in-progress cherry-pick status.' -AllowFailure
            Write-Log CMD 'git diff --cached --quiet'
            & git diff --cached --quiet
            $cachedDiffExit = $LASTEXITCODE
            Write-Log DEBUG ("git diff --cached --quiet exit code: {0} (0=no staged diff; 1=staged changes exist; >1=inspection error)" -f $cachedDiffExit)
            if ($cachedDiffExit -eq 1) {
                Write-Log ERROR 'The index contains staged changes. This is not an empty cherry-pick; likely causes include a commit hook, signing, or another commit-phase failure.'
                Invoke-Checked git @('diff', '--cached', '--stat') 'Could not inspect staged patch after cherry-pick failure.' -AllowFailure
                Invoke-Checked git @('diff', '--cached', '--no-ext-diff', '--no-color') 'Could not display staged patch after cherry-pick failure.' -AllowFailure
                Restore-OriginalBranch
                Fail 'Cherry-pick stopped with CHERRY_PICK_HEAD and staged changes. It was not skipped as empty; inspect the Git/hook/signing diagnostics above.'
            } elseif ($cachedDiffExit -gt 1) {
                Restore-OriginalBranch
                Fail 'Could not verify whether the failed cherry-pick produced staged changes. Recovery was attempted rather than assuming it was empty.'
            }
            Write-Log WARN 'No unmerged paths and no staged delta remain, so the cherry-pick appears empty. Asking Git to skip it is the prescribed cleanup.'
            Invoke-Checked git @('cherry-pick', '--skip') 'Git could not skip the empty cherry-pick.'
            $headAfterSkip = (Invoke-Checked git @('rev-parse', 'HEAD') 'Could not resolve HEAD after skipping empty cherry-pick.' -Capture).Trim()
            Write-Log INFO ("HEAD after --skip: {0}" -f $headAfterSkip)
            if ($headAfterSkip -eq $base) {
                Restore-OriginalBranch
                Write-Log WARN "NO CHANGES: commit $Commit resulted in an empty cherry-pick; no patch branch was retained."
                Write-Log INFO 'The change may already be represented in the destination tree, or earlier changes may make this commit redundant. Nothing was pushed.'
                exit 0
            }
            Restore-OriginalBranch
            Fail 'Git skipped an empty cherry-pick after HEAD changed unexpectedly. Recovery was attempted; inspect the logs above.'
        }

        Write-Log ERROR 'Cherry-pick failed without unresolved paths and without CHERRY_PICK_HEAD. The failure is not a merge conflict or a standard empty cherry-pick.'
        Write-Log INFO 'Relevant diagnostics: effective Git identity, hooks/signing config, final status, and Git output from the attempt above.'
        Invoke-Checked git @('status', '--short', '--branch') 'Could not inspect failed cherry-pick status.' -AllowFailure
        Invoke-Checked git @('config', '--show-origin', '--get-regexp', '^(user\.(name|email)|commit\.gpgsign|gpg\.format|core\.hooksPath)$') 'Could not inspect Git identity/hook config.' -AllowFailure
        Restore-OriginalBranch
        Fail 'Cherry-pick failed for a non-conflict reason. Original checkout restoration was attempted; inspect Git identity/hooks/signing configuration and the Git output above.'
    }
}

Write-Phase 'Post-apply verification'
Write-Log OK ("Patch applied using resolution: {0}" -f $resolution)
$appliedHead = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve HEAD after cherry-pick.' -Capture).Trim()
Write-Log INFO ("New HEAD: {0}" -f $appliedHead)
Invoke-Checked git @('show', '-s', '--format=fuller', '--decorate=full', 'HEAD') 'Could not inspect resulting commit metadata.'
Write-Log INFO 'Resulting commit statistics and summary:'
Invoke-Checked git @('show', '--stat', '--summary', '--find-renames', 'HEAD') 'Could not display resulting commit summary.'
Write-Log INFO 'Paths changed by the resulting commit:'
Invoke-Checked git @('diff-tree', '--no-commit-id', '--find-renames', '--name-status', '-r', 'HEAD') 'Could not list paths changed by resulting commit.'
Write-Log INFO 'Full resulting commit patch follows. This shows the actual committed result, including any conflict resolution, rather than only the upstream source patch.'
Invoke-Checked git @('show', '--format=fuller', '--find-renames', '--no-ext-diff', '--no-color', 'HEAD') 'Could not display the final applied patch.'
Write-Log INFO 'Whitespace/error check on the resulting commit (reported for review; does not undo the patch):'
Invoke-Checked git @('diff', '--check', 'HEAD^', 'HEAD') 'Could not check resulting commit for whitespace errors.' -AllowFailure
Write-Log INFO 'Final worktree and branch status before tests:'
Write-GitSnapshot 'Post-cherry-pick repository snapshot:'

function Invoke-Tests {
    Write-Phase 'Test/build discovery and execution'
    if ($env:PATCH_TEST_CMD) {
        Write-Log INFO 'PATCH_TEST_CMD is set; using this explicit project test command instead of auto-detection.'
        Write-Log CMD (Get-SafeText $env:PATCH_TEST_CMD)
        Invoke-Expression $env:PATCH_TEST_CMD
        if ($null -ne $LASTEXITCODE) { $testExit = $LASTEXITCODE } else { $testExit = 0 }
        Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("Custom test command exit code: {0}" -f $testExit)
        return $testExit
    } elseif ((Test-Path Cargo.toml) -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Log INFO 'Detected Cargo.toml and cargo. Running cargo test.'
        Write-Log CMD 'cargo test'
        & cargo test
        $testExit = $LASTEXITCODE
        Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("cargo test exit code: {0}" -f $testExit)
        return $testExit
    } elseif ((Test-Path go.mod) -and (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Log INFO 'Detected go.mod and go. Running go test ./...'
        Write-Log CMD 'go test ./...'
        & go test ./...
        $testExit = $LASTEXITCODE
        Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("go test exit code: {0}" -f $testExit)
        return $testExit
    } elseif ((Test-Path package.json) -and (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Log INFO 'Detected package.json and node. Checking whether package.json defines a test script.'
        try { $package = Get-Content package.json -Raw | ConvertFrom-Json } catch { $package = $null }
        if ($package -and $package.scripts -and $package.scripts.test -is [string]) {
            if ((Test-Path pnpm-lock.yaml) -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                $testCommand = 'pnpm test'; Write-Log INFO 'Package-manager choice: pnpm-lock.yaml and pnpm executable found.'; Write-Log CMD $testCommand; & pnpm test
            } elseif ((Test-Path yarn.lock) -and (Get-Command yarn -ErrorAction SilentlyContinue)) {
                $testCommand = 'yarn test'; Write-Log INFO 'Package-manager choice: yarn.lock and yarn executable found.'; Write-Log CMD $testCommand; & yarn test
            } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
                $testCommand = 'npm test'; Write-Log INFO 'Package-manager choice: npm fallback.'; Write-Log CMD $testCommand; & npm test
            } else {
                Write-Log ERROR 'package.json has a test script, but no supported package manager was found.'; return 125
            }
            $testExit = $LASTEXITCODE
            Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("$testCommand exit code: {0}" -f $testExit)
            return $testExit
        }
        Write-Log INFO 'package.json has no string-valued scripts.test entry; checking other supported project types.'
    } elseif ((Test-Path pyproject.toml) -or (Test-Path pytest.ini) -or (Test-Path setup.cfg)) {
        Write-Log INFO 'Detected Python project metadata. Checking for pytest and unittest discovery.'
        if (Get-Command python -ErrorAction SilentlyContinue) {
            Write-Log CMD "python -c 'import pytest'"
            & python -c 'import pytest' *> $null
            $pytestImportExit = $LASTEXITCODE
            Write-Log DEBUG ("pytest import check exit code: {0}" -f $pytestImportExit)
            if ($pytestImportExit -eq 0) {
                Write-Log CMD 'python -m pytest'; & python -m pytest
                $testExit = $LASTEXITCODE; Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("pytest exit code: {0}" -f $testExit); return $testExit
            }
            if ((Test-Path tests) -or (Test-Path test)) {
                Write-Log CMD 'python -m unittest discover'; & python -m unittest discover
                $testExit = $LASTEXITCODE; Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("unittest exit code: {0}" -f $testExit); return $testExit
            }
        }
        Write-Log WARN 'Python project found, but no supported test runner/tests were detected.'
        return 125
    } elseif (Get-Command dotnet -ErrorAction SilentlyContinue) {
        Write-Log INFO 'dotnet is available. Searching for a solution or test project (excluding .git, bin, and obj).'
        $solution = Get-ChildItem -Path . -Recurse -File -Include *.sln,*.slnx -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj)[\\/]' } | Select-Object -First 1
        $testProject = Get-ChildItem -Path . -Recurse -File -Filter '*test*.csproj' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj)[\\/]' } | Select-Object -First 1
        if ($solution) {
            Write-Log INFO ("Selected .NET solution: {0}" -f $solution.FullName)
            Write-Log CMD (Format-CommandLine dotnet @('test', $solution.FullName, '--verbosity', 'normal'))
            & dotnet test $solution.FullName --verbosity normal
            $testExit = $LASTEXITCODE; Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("dotnet test exit code: {0}" -f $testExit); return $testExit
        }
        if ($testProject) {
            Write-Log INFO ("Selected .NET test project: {0}" -f $testProject.FullName)
            Write-Log CMD (Format-CommandLine dotnet @('test', $testProject.FullName, '--verbosity', 'normal'))
            & dotnet test $testProject.FullName --verbosity normal
            $testExit = $LASTEXITCODE; Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("dotnet test exit code: {0}" -f $testExit); return $testExit
        }
        Write-Log WARN 'dotnet exists, but no .NET solution or test project was detected.'
        return 125
    } elseif ((Test-Path Makefile) -and (Get-Command make -ErrorAction SilentlyContinue)) {
        Write-Log INFO 'Detected Makefile and make. Checking for a test target.'
        if (Select-String -Path Makefile -Pattern '^\s*test\s*:' -Quiet) {
            Write-Log CMD 'make test'; & make test
            $testExit = $LASTEXITCODE; Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("make test exit code: {0}" -f $testExit); return $testExit
        }
    } elseif ((Test-Path build/CTestTestfile.cmake) -and (Get-Command ctest -ErrorAction SilentlyContinue)) {
        Write-Log INFO 'Detected build/CTestTestfile.cmake and ctest.'
        Write-Log CMD 'ctest --test-dir build --output-on-failure'; & ctest --test-dir build --output-on-failure
        $testExit = $LASTEXITCODE; Write-Log $(if ($testExit -eq 0) { 'OK' } else { 'ERROR' }) ("ctest exit code: {0}" -f $testExit); return $testExit
    }
    Write-Log WARN "No supported test command was detected. Set PATCH_TEST_CMD to this repository's test/build command."
    return 125
}

$testStatus = Invoke-Tests
Write-Phase 'Final outcome and next developer actions'
Write-Log INFO ("Patch branch: {0}" -f $branch)
Write-Log INFO ("Resulting HEAD: {0}" -f $appliedHead)
Write-Log INFO ("Resolution path: {0}" -f $resolution)
Write-Log INFO 'The original branch was not modified by the cherry-pick; all changes are on the patch branch unless recovery was required.'
Write-Log INFO 'No push was attempted. Review the resulting commit and run any additional project-specific checks before pushing.'

if ($testStatus -eq 0) {
    Write-Log OK 'SUCCESS: patch applied and detected tests passed.'
    Write-Log INFO 'Review commands:'
    Write-Log INFO '  git show --format=fuller --stat HEAD'
    Write-Log INFO '  git show --find-renames --format=fuller HEAD'
    Write-Log INFO '  git diff HEAD^ HEAD'
    Write-Log INFO '  git status --short --branch'
    Write-Log INFO '  git log --oneline --decorate -5'
    exit 0
} elseif ($testStatus -eq 125) {
    Write-Log WARN 'PATCH APPLIED, BUT TESTS WERE NOT RUN: no supported test command was detected.'
    Write-Log INFO 'Set PATCH_TEST_CMD to a project-specific test/build command, then review the patch branch.'
    Write-Log INFO 'Nothing was pushed. Use git show --find-renames --format=fuller HEAD and git status --short --branch.'
    exit 2
} else {
    Write-Log ERROR ("PATCH APPLIED, BUT TESTS FAILED (exit code {0})." -f $testStatus)
    Write-Log WARN 'The patch branch is intentionally retained so you can inspect, fix, amend, or discard it.'
    Write-Log INFO 'Inspect test output above, then run git status --short --branch, git diff HEAD^ HEAD, and the failing test command.'
    exit 1
}