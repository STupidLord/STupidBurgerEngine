# Safely cherry-pick one verified upstream commit, or cascade all missing ancestor commits, onto a GitHub fork.
# PowerShell 7+. Never pushes. Diagnostic output is intentionally detailed:
# important phases, candidate commits, no-op reasons, commands, conflicts, audits, and tests are logged.
# Failed or incomplete cascades preserve their patch branch for inspection.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $SourceUrl,
    [Parameter(Position = 1)]
    [string] $Commit,
    [switch] $Force,
    [switch] $Cascade,
    [switch] $AutoTheirs,
    [ValidateRange(0, 10)]
    [int] $MergeMainline = 0
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
  pwsh -File .\merge-cascade.ps1 https://github.com/OWNER/UPSTREAM.git FULL_COMMIT_SHA

Cascade all commits reachable from the selected commit that are not ancestors of the current HEAD:
  pwsh -File .\merge-cascade.ps1 URL SHA -Cascade

If the cascade contains merge commits, choose their mainline explicitly (usually 1):
  pwsh -File .\merge-cascade.ps1 URL SHA -Cascade -MergeMainline 1

In cascade mode, automatic conflict preference is disabled unless explicitly enabled:
  pwsh -File .\merge-cascade.ps1 URL SHA -Cascade -AutoTheirs

Optional custom test command:
  $env:PATCH_TEST_CMD = 'dotnet test; ./scripts/smoke-test.ps1'

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
Write-Log INFO ("Mode: {0}; merge mainline: {1}; conflict fallback: {2}" -f $(if ($Cascade) { 'cascade candidate commit set' } else { 'single commit' }), $(if ($MergeMainline -gt 0) { $MergeMainline } else { '(not set)' }), $(if ($Cascade -and -not $AutoTheirs) { 'automatic -X theirs disabled' } elseif ($Cascade -and $AutoTheirs) { 'automatic -X theirs explicitly enabled' } else { 'automatic -X theirs enabled for single-commit mode' }))
Write-Log INFO 'Safety invariants: require clean worktree; validate GitHub fork parent unless -Force; never push; report no-op commits explicitly.'

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
if ($parentRepo -ine $sourceRepo) {
    if (-not $Force) { Fail "$destRepo is a fork of '$parentRepo', not '$sourceRepo'. Use -Force only after verifying this cross-repository source is intentional. No changes made." }
    Write-Log WARN ("-Force accepted a cross-repository source: destination {0} has immediate parent {1}, while the requested source is {2}. The parent relationship did NOT match." -f $destRepo, $parentRepo, $sourceRepo)
} else {
    Write-Log OK ("Fork relationship verified: {0} -> {1}" -f $destRepo, $sourceRepo)
}

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
if ($parentCount -gt 1 -and -not $Cascade) { Fail 'Merge commits are intentionally rejected in single-commit mode. Use -Cascade with an explicit -MergeMainline value if you have reviewed the merge semantics.' }
if ($parentCount -eq 0) { Fail 'Root commits have no parent to compare against and are not supported by this cherry-pick workflow.' }
$commitParentIndex = if ($MergeMainline -gt 0 -and $MergeMainline -le $parentCount) { $MergeMainline - 1 } else { 0 }
$commitParent = $parentIds[$commitParentIndex]
Write-Log INFO ("Selected parent for patch inspection: {0} (parent number {1})" -f $commitParent, ($commitParentIndex + 1))

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

Write-Phase 'Build candidate commit set and compare it against the destination HEAD'
$base = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve destination HEAD.' -Capture).Trim()
$originalBranch = (Invoke-Checked git @('branch', '--show-current') 'Could not determine original branch name.' -Capture).Trim()
Write-Log INFO ("Original HEAD (rollback target): {0}" -f $base)
Write-Log INFO ("Original branch name: {0}" -f $(if ($originalBranch) { $originalBranch } else { '(detached HEAD)' }))
if ($Cascade -and $originalBranch -ine 'main') {
    Write-Log WARN ("Cascade compares against current HEAD on '{0}', not a branch named 'main'. Check out the intended destination branch before running if main is the target." -f $(if ($originalBranch) { $originalBranch } else { '(detached HEAD)' }))
}
Write-Log CMD (Format-CommandLine git @('merge-base', '--is-ancestor', $Commit, 'HEAD'))
& git merge-base --is-ancestor $Commit HEAD
$ancestorExit = $LASTEXITCODE
Write-Log INFO ("git merge-base --is-ancestor exit code: {0} (0=already ancestor; 1=not ancestor; >1=error)" -f $ancestorExit)
if ($ancestorExit -eq 0) {
    Write-Log OK "The selected commit $Commit is already an ancestor of HEAD. Its ancestry is therefore already reachable from this branch; nothing to apply."
    Write-Log INFO 'This proves commit-history inclusion, not that every unrelated source-branch commit is present.'
    exit 0
}
if ($ancestorExit -gt 1) { Fail 'git merge-base --is-ancestor failed for an unexpected reason.' }

if ($Cascade) {
    Write-Log INFO 'Cascade mode: collecting every commit reachable from the selected endpoint that is not already an ancestor of the original HEAD.'
    $candidateText = Invoke-Checked git @('rev-list', '--reverse', '--topo-order', $Commit, '--not', $base) 'Could not enumerate source ancestry missing from destination history.' -Capture
    $script:CommitsToApply = @($candidateText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($script:CommitsToApply.Count -eq 0) {
        Write-Log OK 'CASCADE NO-OP: no source commit objects remain outside destination HEAD history.'
        Write-Log INFO 'No branch was created and nothing was pushed.'
        exit 0
    }

    Write-Log INFO ("Candidate commit count: {0}; order: oldest/parent-first, topologically sorted." -f $script:CommitsToApply.Count)
    $script:CommitOutcomes = @{}
    $script:MergeCommits = @()
    foreach ($candidate in $script:CommitsToApply) {
        $candidateParentsLine = (Invoke-Checked git @('rev-list', '--parents', '-n', '1', $candidate) 'Could not inspect candidate commit parents.' -Capture).Trim()
        $candidateParents = @($candidateParentsLine -split '\s+' | Select-Object -Skip 1)
        if ($candidateParents.Count -eq 0) {
            Fail "Cascade includes root commit $candidate. Root commits cannot be safely cherry-picked by this workflow; select a later endpoint/range or handle this root separately."
        }
        if ($candidateParents.Count -gt 1) {
            $script:MergeCommits += $candidate
            if ($MergeMainline -eq 0) {
                Write-Log WARN ("Merge commit requires an explicit mainline choice: {0} (parents: {1})" -f $candidate, $candidateParents.Count)
            } elseif ($MergeMainline -gt $candidateParents.Count) {
                Fail "-MergeMainline $MergeMainline is invalid for merge commit $candidate, which has only $($candidateParents.Count) parents."
            }
        }
    }
    if ($script:MergeCommits.Count -gt 0 -and $MergeMainline -eq 0) {
        Write-Log ERROR 'Cascade stopped before creating a branch because the candidate set contains merge commits and no mainline was selected.'
        Write-Log ERROR 'Review each merge, then rerun with -MergeMainline 1 (or another valid parent number). This choice affects the patch represented by each merge commit.'
        Fail ("Merge commits requiring a mainline: {0}" -f ($script:MergeCommits -join ', '))
    }
    if ($MergeMainline -gt 0) {
        Write-Log WARN ("Cascade will cherry-pick each merge commit relative to parent number {0}. This is an explicit, potentially consequential choice; inspect the final patch." -f $MergeMainline)
    }
    Write-Log INFO 'Candidate commit set preview (full SHA and subject; this is the audit set, not a Git .bundle transfer archive):'
    foreach ($candidate in $script:CommitsToApply) {
        Invoke-Checked git @('show', '-s', '--format=%H %s', $candidate) 'Could not summarize a candidate commit.'
    }
} else {
    $script:CommitsToApply = @($Commit)
    $script:CommitOutcomes = @{}
    $script:MergeCommits = @()
    Write-Log INFO 'Single-commit mode: only the explicitly selected commit will be attempted.'
}

Write-Log INFO 'Patch-equivalence preflight: git cherry marks source commits with + (no patch-equivalent commit detected in the destination) or - (equivalent patch already present).'
$preflightCherry = Invoke-Checked git @('cherry', '-v', $base, $Commit) 'Could not compare source commit patches against destination history.' -Capture
$preflightLines = @($preflightCherry -split "`n" | Where-Object { $_.Trim() })
$preflightPlus = @($preflightLines | Where-Object { $_ -match '^\+\s' }).Count
$preflightMinus = @($preflightLines | Where-Object { $_ -match '^-\s' }).Count
Write-Log INFO ("Patch-equivalence preflight summary: {0} potentially distinct patch(es), {1} patch-equivalent commit(s). This is advisory; actual empty application is checked during replay." -f $preflightPlus, $preflightMinus)

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
    Write-Log INFO 'Checking whether a cherry-pick is still active before attempting cleanup.'
    $activePick = (& git rev-parse -q --verify CHERRY_PICK_HEAD 2>$null | Out-String).Trim()
    $activePickExit = $LASTEXITCODE
    Write-Log DEBUG ("CHERRY_PICK_HEAD inspection exit code: {0}; value: {1}" -f $activePickExit, $(if ($activePick) { $activePick } else { '(none)' }))

    if ($activePickExit -eq 0 -and $activePick) {
        Write-Log WARN ("An in-progress cherry-pick was detected ({0}); aborting it before switching branches." -f $activePick)
        Invoke-Checked git @('cherry-pick', '--abort') 'git cherry-pick --abort returned non-zero during recovery.' -AllowFailure
    } elseif ($activePickExit -eq 1 -and -not $activePick) {
        Write-Log INFO 'No active cherry-pick remains; abort is unnecessary (for example, the operation may already have been skipped).'
    } else {
        Write-Log WARN 'Could not conclusively inspect CHERRY_PICK_HEAD; attempting cherry-pick abort as a recovery fallback.'
        Invoke-Checked git @('cherry-pick', '--abort') 'git cherry-pick --abort returned non-zero during recovery.' -AllowFailure
    }

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
        $patchBranchHead = (& git rev-parse --verify "refs/heads/$script:branch" 2>$null | Out-String).Trim()
        $patchBranchHeadExit = $LASTEXITCODE
        if ($patchBranchHeadExit -eq 0 -and $patchBranchHead -and $patchBranchHead -ne $script:base) {
            Write-Log WARN ("Preserving temporary patch branch {0}: it contains committed work beyond rollback target {1}." -f $script:branch, $script:base)
            Write-Log INFO ("Inspect it with: git switch {0}; git log --oneline --decorate {1}..HEAD" -f $script:branch, $script:base)
        } else {
            Write-Log INFO ("Removing temporary patch branch because it contains no committed work beyond the rollback target: {0}" -f $script:branch)
            Invoke-Checked git @('branch', '-D', $script:branch) 'Could not remove temporary failed patch branch.' -AllowFailure
        }
    } else {
        Write-Log ERROR 'Could not restore the original checkout automatically. The temporary patch branch is intentionally preserved for manual recovery.'
        Write-Log ERROR ("Expected rollback target: {0}; temporary branch: {1}" -f $script:base, $script:branch)
        Invoke-Checked git @('status', '--short', '--branch') 'Could not report recovery status.' -AllowFailure
    }
}

$script:AppliedCount = 0
$script:EmptyCount = 0
$script:CandidateIndex = 0
$script:ResolutionRecords = @()

foreach ($candidateCommit in $script:CommitsToApply) {
    $script:CandidateIndex++
    $candidateSubject = (Invoke-Checked git @('show', '-s', '--format=%s', $candidateCommit) 'Could not read candidate commit subject.' -Capture).Trim()
    $candidateShort = $candidateCommit.Substring(0, [Math]::Min(12, $candidateCommit.Length))
    $candidateHeadBefore = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve HEAD before candidate cherry-pick.' -Capture).Trim()
    $candidateParentLine = (Invoke-Checked git @('rev-list', '--parents', '-n', '1', $candidateCommit) 'Could not inspect candidate commit parent list.' -Capture).Trim()
    $candidateParents = @($candidateParentLine -split '\s+' | Select-Object -Skip 1)
    $candidateIsMerge = $candidateParents.Count -gt 1
    $candidateDiffParentIndex = if ($candidateIsMerge) { $MergeMainline - 1 } else { 0 }
    $candidateDiffParent = $candidateParents[$candidateDiffParentIndex]

    Write-Phase ("Apply candidate {0}/{1}: {2}" -f $script:CandidateIndex, $script:CommitsToApply.Count, $candidateShort)
    Write-Log INFO ("Candidate commit: {0}" -f $candidateCommit)
    Write-Log INFO ("Subject: {0}" -f $candidateSubject)
    Write-Log INFO ("HEAD immediately before this candidate: {0}" -f $candidateHeadBefore)
    Write-Log INFO 'Candidate summary and per-file change counts:'
    Invoke-Checked git @('show', '--stat', '--summary', '--find-renames', $candidateCommit) 'Could not display candidate commit summary.'
    Write-Log INFO ("Candidate changed paths relative to selected parent {0}:" -f $candidateDiffParent)
    Invoke-Checked git @('diff', '--find-renames', '--name-status', $candidateDiffParent, $candidateCommit) 'Could not list candidate changed paths.'
    if ($candidateIsMerge) {
        Write-Log WARN ("This is a merge commit; using parent {0} as the mainline for its patch." -f $MergeMainline)
    }
    Write-Log INFO 'Git is asked to apply this commit without editing its default message.'

    $normalArgs = @('-c', 'advice.mergeConflict=false', 'cherry-pick', '--no-edit')
    if ($candidateIsMerge) { $normalArgs += @('-m', [string]$MergeMainline) }
    $normalArgs += $candidateCommit
    Write-Log CMD (Format-CommandLine git $normalArgs)
    & git @normalArgs
    $normalExit = $LASTEXITCODE
    Write-Log $(if ($normalExit -eq 0) { 'OK' } else { 'WARN' }) ("Normal cherry-pick exit code for {0}: {1}" -f $candidateShort, $normalExit)

    if ($normalExit -eq 0) {
        $resolution = if ($candidateIsMerge) { "clean cherry-pick using mainline $MergeMainline" } else { 'clean cherry-pick' }
        $script:CommitOutcomes[$candidateCommit] = 'APPLIED'
        $script:AppliedCount++
        $script:ResolutionRecords += ("{0}: {1}" -f $candidateShort, $resolution)
        Write-Log OK ("APPLIED: commit {0} was committed successfully." -f $candidateCommit)
        continue
    }

    Write-Phase ("Diagnose failed cherry-pick for {0}" -f $candidateShort)
    $unmerged = (Invoke-Checked git @('ls-files', '-u') 'Could not inspect unmerged index entries.' -Capture -AllowFailure).Trim()
    if ($unmerged) {
        Write-Log WARN 'Unmerged index entries exist. This is a content-conflict path; details follow.'
        Write-Log INFO 'Unmerged index stages (mode/object/stage/path):'
        foreach ($line in ($unmerged -split "`n")) { Write-Log INFO $line }
        Write-Log INFO 'Conflicted path names:'
        Invoke-Checked git @('diff', '--name-only', '--diff-filter=U') 'Could not list conflicted paths.' -AllowFailure
        Write-Log INFO 'Current status while conflicts are present:'
        Invoke-Checked git @('status', '--short', '--branch') 'Could not inspect conflict status.' -AllowFailure
        Write-Log INFO 'Combined conflict diff follows:'
        Invoke-Checked git @('diff', '--cc', '--no-ext-diff', '--no-color') 'Could not display combined conflict diff.' -AllowFailure

        if ($Cascade -and -not $AutoTheirs) {
            Write-Log ERROR 'Cascade conflict detected. Automatic -X theirs resolution is disabled by default in cascade mode because it can replace fork-side edits in overlapping hunks.'
            Write-Log INFO 'The conflict paths and combined diff are shown above. Re-run with -AutoTheirs only if preferring incoming commit content is intentional, or resolve the candidate manually.'
            Invoke-Checked git @('cherry-pick', '--abort') 'Could not abort conflicted cascade candidate.'
            Restore-OriginalBranch
            Fail ("Cascade stopped at conflicting commit $candidateCommit before applying any automatic -X theirs fallback.")
        }

        Write-Log WARN 'Aborting this attempt before retrying. The fallback uses -X theirs: incoming-commit content wins in overlapping conflicting hunks; nearby fork edits in the same hunk may be replaced.'
        Invoke-Checked git @('cherry-pick', '--abort') 'Could not abort first conflicted cherry-pick.'
        Invoke-Checked git @('status', '--short', '--branch') 'Could not confirm state after cherry-pick abort.'

        Write-Phase ("Retry candidate {0} with -X theirs" -f $candidateShort)
        $theirsArgs = @('-c', 'advice.mergeConflict=false', 'cherry-pick', '--no-edit', '-X', 'theirs')
        if ($candidateIsMerge) { $theirsArgs += @('-m', [string]$MergeMainline) }
        $theirsArgs += $candidateCommit
        Write-Log CMD (Format-CommandLine git $theirsArgs)
        & git @theirsArgs
        $theirsExit = $LASTEXITCODE
        Write-Log $(if ($theirsExit -eq 0) { 'OK' } else { 'WARN' }) ("-X theirs cherry-pick exit code for {0}: {1}" -f $candidateShort, $theirsExit)
        if ($theirsExit -eq 0) {
            $resolution = 'automatic -X theirs merge (incoming side wins overlapping hunks; nearby fork edits in the same hunk may be replaced)'
            $script:CommitOutcomes[$candidateCommit] = 'APPLIED'
            $script:AppliedCount++
            $script:ResolutionRecords += ("{0}: {1}" -f $candidateShort, $resolution)
            Write-Log WARN ("APPLIED WITH AUTOMATIC CONFLICT RESOLUTION: {0}. Review its resulting patch carefully." -f $candidateCommit)
            continue
        }

        Write-Log ERROR 'The -X theirs retry failed. Do not assume it was a merge conflict; hooks, signing, identity, or another Git operation may have failed.'
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
        Fail ("The -X theirs retry failed for candidate $candidateCommit (exit code $theirsExit). Recovery was attempted; inspect the diagnostics above.")
    }

    # No unmerged index entries: distinguish an empty cherry-pick from a non-conflict failure.
    Write-Log WARN 'No unmerged index entries were found. Checking CHERRY_PICK_HEAD and the staged index before deciding whether this candidate is a genuine no-op.'
    Write-Log CMD 'git rev-parse -q --verify CHERRY_PICK_HEAD'
    $cherryPickHead = (& git rev-parse -q --verify CHERRY_PICK_HEAD 2>$null | Out-String).Trim()
    $cherryPickHeadExit = $LASTEXITCODE
    Write-Log DEBUG ("git rev-parse CHERRY_PICK_HEAD exit code: {0}; value: {1}" -f $cherryPickHeadExit, $(if ($cherryPickHead) { $cherryPickHead } else { '(none)' }))
    if ($cherryPickHeadExit -eq 0 -and $cherryPickHead) {
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
            Fail ("Cherry-pick for $candidateCommit stopped with CHERRY_PICK_HEAD and staged changes. It was not skipped as empty.")
        } elseif ($cachedDiffExit -gt 1) {
            Restore-OriginalBranch
            Fail ("Could not verify the staged index after the failed cherry-pick for $candidateCommit; recovery was attempted.")
        }

        Write-Log WARN ("NO-OP DETECTED: commit {0} ({1}) has no staged tree delta when applied on current HEAD {2}." -f $candidateCommit, $candidateSubject, $candidateHeadBefore)
        Write-Log INFO 'Interpretation: this commit currently contributes no new tracked-content change at this point in the replay. Its effect may already be represented, may have been superseded, or may be redundant after earlier commits. This does not prove that the exact source SHA exists in destination history.'
        Write-Log INFO 'Source commit paths for review:'
        Invoke-Checked git @('diff-tree', '--no-commit-id', '--name-status', '-r', $candidateCommit) 'Could not list source commit paths for no-op report.' -AllowFailure
        Write-Log CMD 'git cherry-pick --skip'
        & git cherry-pick --skip
        $skipExit = $LASTEXITCODE
        Write-Log $(if ($skipExit -eq 0) { 'OK' } else { 'ERROR' }) ("git cherry-pick --skip exit code: {0}" -f $skipExit)
        if ($skipExit -ne 0) {
            Restore-OriginalBranch
            Fail ("Git could not cleanly skip no-op candidate $candidateCommit.")
        }
        $headAfterSkip = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve HEAD after skipping an empty cherry-pick.' -Capture).Trim()
        Write-Log INFO ("HEAD after --skip: {0}" -f $headAfterSkip)
        if ($headAfterSkip -ne $candidateHeadBefore) {
            Restore-OriginalBranch
            Fail ("HEAD changed unexpectedly while skipping empty candidate $candidateCommit. Recovery was attempted.")
        }
        $script:CommitOutcomes[$candidateCommit] = 'EMPTY'
        $script:EmptyCount++
        Write-Log OK ("SKIPPED AS REDUNDANT AT APPLICATION TIME: {0}. Cascade processing will continue if enabled." -f $candidateCommit)
        if (-not $Cascade) {
            Restore-OriginalBranch
            Write-Log WARN ("NO CHANGES: selected commit {0} ({1}) produces no net tree delta on the destination branch. No patch branch was retained." -f $candidateCommit, $candidateSubject)
            Write-Log INFO 'Nothing was pushed. The script has explicitly classified this as an empty application, rather than an unresolved merge conflict.'
            exit 0
        }
        continue
    }

    Write-Log ERROR 'Cherry-pick failed without unresolved paths and without CHERRY_PICK_HEAD. This is neither an ordinary conflict nor a standard empty cherry-pick.'
    Write-Log INFO 'Relevant diagnostics: Git identity, hooks/signing configuration, repository status, and Git output above.'
    Invoke-Checked git @('status', '--short', '--branch') 'Could not inspect failed cherry-pick status.' -AllowFailure
    Invoke-Checked git @('config', '--show-origin', '--get-regexp', '^(user\.(name|email)|commit\.gpgsign|gpg\.format|core\.hooksPath)$') 'Could not inspect Git identity/hook config.' -AllowFailure
    Restore-OriginalBranch
    Fail ("Cherry-pick failed for candidate $candidateCommit for a non-conflict reason. Recovery was attempted.")
}

$currentHeadAfterCascade = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve HEAD after replay.' -Capture).Trim()
if ($currentHeadAfterCascade -eq $base) {
    Restore-OriginalBranch
    Write-Log WARN ("NO CONTENT NEEDED: all {0} candidate commit(s) were empty when applied; destination HEAD and tree remain unchanged." -f $script:EmptyCount)
    Write-Log INFO 'The no-op results are recorded per commit above. No patch branch was retained and nothing was pushed.'
    exit 0
}

$script:resolution = if ($script:ResolutionRecords.Count -gt 0) { $script:ResolutionRecords -join '; ' } else { 'no commits applied; all candidates were skipped as empty' }

Write-Phase 'Post-apply verification'
Write-Log OK ("Replay completed. Applied commits: {0}; no-op/empty commits: {1}; candidate commits: {2}." -f $script:AppliedCount, $script:EmptyCount, $script:CommitsToApply.Count)
Write-Log INFO ("Resolution record: {0}" -f $script:resolution)
$appliedHead = (Invoke-Checked git @('rev-parse', '--verify', 'HEAD') 'Could not resolve HEAD after cherry-pick.' -Capture).Trim()
Write-Log INFO ("New HEAD: {0}" -f $appliedHead)
Invoke-Checked git @('show', '-s', '--format=fuller', '--decorate=full', 'HEAD') 'Could not inspect resulting commit metadata.'
Write-Log INFO 'Final commit statistics and summary:'
Invoke-Checked git @('show', '--stat', '--summary', '--find-renames', 'HEAD') 'Could not display final commit summary.'
Write-Log INFO 'Paths changed by the final individual commit:'
Invoke-Checked git @('diff-tree', '--no-commit-id', '--find-renames', '--name-status', '-r', 'HEAD') 'Could not list paths changed by final commit.'
Write-Log INFO 'Aggregate change summary for the complete replay, comparing final HEAD against the original destination HEAD:'
Invoke-Checked git @('diff', '--stat', '--find-renames', $base, $appliedHead) 'Could not summarize aggregate replay diff.'
Write-Log INFO 'Aggregate changed paths for the complete replay:'
Invoke-Checked git @('diff', '--find-renames', '--name-status', $base, $appliedHead) 'Could not list aggregate replay paths.'
Write-Log INFO 'Full aggregate patch follows. This is the entire net change from the original destination HEAD across all commits applied in this run.'
$aggregatePatchArgs = @('diff', '--no-ext-diff', '--no-color', '--find-renames', '--submodule=log', $base, $appliedHead)
Write-Log CMD (Format-CommandLine git $aggregatePatchArgs)
& git @aggregatePatchArgs
$aggregatePatchExit = $LASTEXITCODE
Write-Log $(if ($aggregatePatchExit -eq 0) { 'OK' } else { 'ERROR' }) ("Aggregate replay patch display exit code: {0}" -f $aggregatePatchExit)
if ($aggregatePatchExit -ne 0) { Fail 'Could not display the aggregate replay patch.' }
Write-Log INFO 'Whitespace/error check for the entire aggregate replay (reported for review; does not undo the patch):'
Invoke-Checked git @('diff', '--check', $base, $appliedHead) 'Could not check aggregate replay for whitespace errors.' -AllowFailure
Write-Log INFO 'Final worktree and branch status before tests:'
Write-GitSnapshot 'Post-cherry-pick repository snapshot:'

if ($Cascade) {
    Write-Phase 'Cascade completeness audit against the resulting patch branch'
    Write-Log INFO 'Comparing source-history patch IDs against the resulting HEAD. A remaining + is investigated; commits explicitly recorded as EMPTY are not treated as missing because replay proved they produce no staged tree delta at that point.'
    $finalCherryAudit = Invoke-Checked git @('cherry', '-v', $appliedHead, $Commit) 'Could not perform final source-vs-result patch-equivalence audit.' -Capture
    $auditLines = @($finalCherryAudit -split "`n" | Where-Object { $_.Trim() })
    $unresolvedAudit = @()
    foreach ($line in $auditLines) {
        if ($line -match '^\+\s+([0-9a-f]{40})') {
            $auditSha = $matches[1].ToLowerInvariant()
            if ($script:CommitOutcomes.ContainsKey($auditSha) -and $script:CommitOutcomes[$auditSha] -eq 'EMPTY') {
                Write-Log INFO ("AUDIT NOTE: {0} remains patch-non-equivalent by patch-id, but was observed to have no staged tree delta when replayed; treated as a verified application-time no-op." -f $auditSha)
            } else {
                $unresolvedAudit += $line
            }
        }
    }
    if ($unresolvedAudit.Count -gt 0) {
        Write-Log ERROR ("CASCADE AUDIT INCOMPLETE: {0} source commit(s) remain patch-non-equivalent and were not classified as application-time no-ops." -f $unresolvedAudit.Count)
        foreach ($line in $unresolvedAudit) { Write-Log ERROR ("Unresolved source patch: {0}" -f $line) }
        Write-Log ERROR 'The patch branch is intentionally left checked out and preserved. Do not merge or push it until the remaining source patches and any conflict resolutions have been reviewed.'
        Write-Log INFO ("Review with: git log --oneline --decorate {0}..HEAD; git diff {1}..HEAD; git show --find-renames --format=fuller HEAD" -f $base, $base)
        exit 3
    }
    if ($script:MergeCommits.Count -gt 0) {
        Write-Log WARN ("NON-MERGE PATCH AUDIT PASSED, BUT MERGE REVIEW IS REQUIRED: git cherry does not independently account for merge commits {0}. They were replayed relative to parent {1}; manually inspect those merge diffs before merging or pushing." -f ($script:MergeCommits -join ', '), $MergeMainline)
        $script:CascadeAuditHasMergeReview = $true
    } else {
        Write-Log OK 'CASCADE PATCH AUDIT PASSED: no unclassified, patch-non-equivalent non-merge source commits remain according to git cherry.'
        $script:CascadeAuditHasMergeReview = $false
    }
    Write-Log INFO 'This audit checks commit patch equivalence and the explicit no-op records; it does not assert that the complete source and destination trees should be identical.'
}

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
Write-Log INFO ("Resolution path(s): {0}" -f $script:resolution)
Write-Log INFO 'The original branch was not modified by the replay; all applied changes are on the temporary patch branch.'
if ($Cascade) { Write-Log INFO ("Cascade totals: {0} applied, {1} empty/no-op, {2} candidates." -f $script:AppliedCount, $script:EmptyCount, $script:CommitsToApply.Count) }
Write-Log INFO 'No push was attempted. Review the resulting commit and run any additional project-specific checks before pushing.'

if ($testStatus -eq 0) {
    if ($Cascade -and $script:CascadeAuditHasMergeReview) {
        Write-Log WARN 'PATCH REPLAY AND TESTS SUCCEEDED, BUT MERGE-COMMIT REVIEW IS STILL REQUIRED.'
    } else {
        Write-Log OK 'SUCCESS: patch replay completed, cascade audit (if enabled) passed, and detected tests passed.'
    }
    Write-Log INFO 'Review commands:'
    Write-Log INFO '  git show --format=fuller --stat HEAD'
    Write-Log INFO '  git show --find-renames --format=fuller HEAD'
    Write-Log INFO '  git diff HEAD^ HEAD'
    Write-Log INFO ("  git log --oneline --reverse {0}..HEAD" -f $base)
    Write-Log INFO ("  git diff --stat {0}..HEAD" -f $base)
    Write-Log INFO ("  git diff {0}..HEAD" -f $base)
    Write-Log INFO '  git status --short --branch'
    Write-Log INFO '  git log --oneline --decorate -5'
    exit 0
} elseif ($testStatus -eq 125) {
    Write-Log WARN 'PATCH REPLAY COMPLETED, BUT TESTS WERE NOT RUN: no supported test command was detected.'
    Write-Log INFO 'Set PATCH_TEST_CMD to a project-specific test/build command, then review the patch branch.'
    Write-Log INFO 'Nothing was pushed. Use git show --find-renames --format=fuller HEAD and git status --short --branch.'
    exit 2
} else {
    Write-Log ERROR ("PATCH REPLAY COMPLETED, BUT TESTS FAILED (exit code {0})." -f $testStatus)
    Write-Log WARN 'The patch branch is intentionally retained so you can inspect, fix, amend, or discard it.'
    Write-Log INFO 'Inspect test output above, then run git status --short --branch, git diff HEAD^ HEAD, and the failing test command.'
    exit 1
}