$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Core.ps1')
. (Join-Path $root 'scripts\Inventory.ps1')
$script:checks=0
function Assert-True { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw ('FAIL: ' + $Message) }; $script:checks++; Write-Host ('PASS: ' + $Message) }
function Invoke-TestGit {
    param([string]$Directory,[string[]]$Arguments)
    $oldPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    $result=& git -C $Directory @Arguments 2>&1
    $code=$LASTEXITCODE
    $ErrorActionPreference=$oldPreference
    if ($code -ne 0) { throw ('Git failed: ' + ($Arguments -join ' ') + ' / ' + ($result -join ' ')) }
    return $result
}
function Invoke-Updater {
    param([string]$Directory,[string]$Script=(Join-Path $root 'scripts\Update-Tool.ps1'))
    $process=New-Object Diagnostics.Process
    $process.StartInfo.FileName='powershell.exe'
    $process.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" -NoPause'
    if ((Split-Path -Leaf $Script) -ne 'Launch-Update.ps1') { $process.StartInfo.Arguments += ' -RepositoryRoot "' + $Directory + '"' }
    $process.StartInfo.UseShellExecute=$false
    $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true
    $process.StartInfo.RedirectStandardError=$true
    $process.StartInfo.StandardOutputEncoding=[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $process.StartInfo.StandardErrorEncoding=$process.StartInfo.StandardOutputEncoding
    [void]$process.Start()
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Updater test timed out' }
    $result=[pscustomobject]@{ code=$process.ExitCode; text=$outTask.Result + $errTask.Result }
    $process.Dispose()
    return $result
}

# All fixtures live below a known temporary workspace. Never delete outside it.
$temporary=Join-Path (Join-Path $root 'test-output') ([guid]::NewGuid().ToString('N') + " 日本語 O'Brien")
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $parseErrors=@()
    foreach ($file in @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') + @(Get-Item $PSCommandPath)) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        $parseErrors+=@($errors)
    }
    Assert-True ($parseErrors.Count -eq 0) 'All PowerShell files parse'
    Add-Type -Path (Join-Path $root 'scripts\AudioEndpoint.cs') -ErrorAction Stop
    Assert-True ($null -ne ('G3Audio.Endpoint' -as [type])) 'Core Audio reader compiles'
    $profile=[pscustomobject]@{ speakerModel='Test speaker'; powerSource='PCのUSB'; cStates='Disabled'; observations='<script>alert(1)</script>' }
    $session=New-DiagnosticSession $profile
    $directory=Join-Path $temporary 'session'
    Save-Session $session $directory
    $loaded=Read-Session (Join-Path $directory 'session.json')
    Assert-True (@($loaded.tests).Count -eq 0) 'An empty session can be resumed'
    $assessment=(Get-Assessment $loaded | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('C-Statesは確認済み') -and $assessment.Contains('基準条件の再現記録が必要')) 'Disabled C-States skipped; missing baseline remains visible'
    $test=New-TestRecord 'baseline35' '3.5mm' 'PCのUSB' '<script>alert(1)</script>' 'baseline' '=HYPERLINK("https://example.invalid")'
    $test.result='Unchanged'; $test.durationSeconds=600; $test.endedUtc=[DateTime]::UtcNow.ToString('o'); $test.noiseUtc=@([DateTime]::UtcNow.ToString('o'))
    $session.tests=@($test)
    $powerTest=New-TestRecord 'independentPower' '3.5mm' '独立したUSB電源' 'Test player' 'USB power only' 'test'
    $powerTest.result='NotRun'; $session.tests+=@($powerTest)
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True (-not $assessment.Contains('USB給電の影響が候補')) 'Skipped power comparison never counts as improvement'
    Assert-True ($assessment.Contains('3. スピーカーのUSB給電を変更')) 'Remaining prerequisite visible after baseline completed'
    $powerTest.result='NoRepro'; $powerTest.durationSeconds=30
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('USB給電の影響が候補') -and $assessment.Contains('観察時間が短い')) 'Comparison changes guidance and exposes short observation'
    $powerTest.noiseUtc=@([DateTime]::UtcNow.ToString('o'))
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('結果とノイズ記録の食い違い') -and -not $assessment.Contains('USB給電の影響が候補')) 'Conflicting no-reproduction records cannot imply a clean comparison'
    $powerTest.noiseUtc=@()
    $test.noiseUtc=@(); $test.result='NoRepro'
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('基準条件の再現記録が必要') -and -not $assessment.Contains('USB給電の影響が候補')) 'No reproduction is not proof of improvement'
    $test.noiseUtc=@([DateTime]::UtcNow.ToString('o')); $test.result='Unchanged'
    $hdmi=New-TestRecord 'hdmi' 'HDMI' '該当なし' 'Test' 'HDMI' ''
    $hdmi.result='Unchanged'; $hdmi.noiseUtc=@([DateTime]::UtcNow.ToString('o')); $hdmi.durationSeconds=600; $session.tests+=@($hdmi)
    Assert-True (((Get-Assessment $session | ForEach-Object { $_.title }) -join ' ').Contains('HDMIにも発生')) 'New HDMI evidence supersedes the initial assumption'
    $session.inventory=[pscustomobject]@{ computer=[pscustomobject]@{status='unavailable';data=$null;errorType='TestFailure'} }
    Save-Session $session $directory
    $loaded=Read-Session (Join-Path $directory 'session.json')
    Assert-True ($loaded.tests.Count -eq 3 -and $loaded.tests[0].noiseUtc.Count -eq 1 -and $loaded.tests[0].tool.version -eq $session.tool.version) 'JSON preserves tests, markers and tool identities'
    Assert-True ($loaded.inventory.computer.status -eq 'unavailable') 'Partial collection failure stays visible'
    $html=Get-Content -LiteralPath (Join-Path $directory 'report.html') -Raw -Encoding UTF8
    Assert-True ($html.Contains('&lt;script&gt;') -and -not $html.Contains('<script>')) 'HTML escapes untrusted notes'
    $csv=Import-Csv -LiteralPath (Join-Path $directory 'tests.csv') -Encoding UTF8
    Assert-True ($csv.Count -eq 3 -and $csv[0].notes.StartsWith("'=")) 'CSV protects against formula injection and preserves rows'
    Assert-True ([int]$csv[0].noise_count -eq $loaded.tests[0].noiseUtc.Count) 'CSV and JSON agree on markers'
    $source=Join-Path $temporary 'future.json'
    $future=$session | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $future.schemaVersion=999
    Write-AtomicText $source ($future | ConvertTo-Json -Depth 20)
    $before=[IO.File]::ReadAllText($source); $rejected=$false
    try { Read-Session $source | Out-Null } catch { $rejected=$true }
    Assert-True ($rejected -and [IO.File]::ReadAllText($source) -eq $before) 'Unsupported schemas reject without altering the source'
    $partial=Invoke-CollectionSection { throw 'fixture' }
    Assert-True ($partial.status -eq 'unavailable' -and $null -eq $partial.data) 'Collection errors never look like successful empty data'
    $deviceRef=Get-AnonymousDeviceRef 'USB\VID_1234&PID_5678\PRIVATE_SERIAL' 'a'
    Assert-True ($deviceRef -notmatch 'PRIVATE' -and $deviceRef -ne (Get-AnonymousDeviceRef 'USB\VID_1234&PID_5678\PRIVATE_SERIAL' 'b')) 'Device references are anonymized per session'

    $remote=Join-Path $temporary 'remote.git'; $author=Join-Path $temporary 'author'; $client=Join-Path $temporary 'client'
    [IO.Directory]::CreateDirectory($remote) | Out-Null
    Invoke-TestGit $remote @('init','--bare','--initial-branch=main') | Out-Null
    Invoke-TestGit $temporary @('clone',$remote,$author) | Out-Null
    foreach ($repo in @($author)) {
        Invoke-TestGit $repo @('config','user.name','Test Author') | Out-Null
        Invoke-TestGit $repo @('config','user.email','test@example.invalid') | Out-Null
        Invoke-TestGit $repo @('config','commit.gpgsign','false') | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $author '.gitignore'),"/data/`n")
    [IO.File]::WriteAllText((Join-Path $author 'version.txt'),'one')
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Update-Tool.ps1') -Destination (Join-Path $author 'Update-Tool.ps1')
    [IO.Directory]::CreateDirectory((Join-Path $author 'scripts')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Update-Tool.ps1') -Destination (Join-Path $author 'scripts\Update-Tool.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Launch-Update.ps1') -Destination (Join-Path $author 'scripts\Launch-Update.ps1')
    Invoke-TestGit $author @('add','.') | Out-Null
    Invoke-TestGit $author @('commit','-m','initial') | Out-Null
    Invoke-TestGit $author @('push','origin','main') | Out-Null
    Invoke-TestGit $temporary @('clone',$remote,$client) | Out-Null
    Invoke-TestGit $client @('config','user.name','Test Author') | Out-Null
    Invoke-TestGit $client @('config','user.email','test@example.invalid') | Out-Null
    Invoke-TestGit $client @('config','commit.gpgsign','false') | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $client 'data')) | Out-Null
    $privateLog=Join-Path $client 'data\session.json'
    [IO.File]::WriteAllText($privateLog,'private fixture')
    $lock=[IO.File]::Open((Join-Path $client 'data\tool.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $update=Invoke-Updater $client; Assert-True ($update.code -ne 0) 'Updater refuses while a diagnostic session holds the lock' } finally { $lock.Dispose() }
    [IO.File]::WriteAllText((Join-Path $author 'version.txt'),'two')
    Add-Content -LiteralPath (Join-Path $author 'Update-Tool.ps1') -Value '# Updated runner fixture' -Encoding UTF8
    Invoke-TestGit $author @('add','.') | Out-Null; Invoke-TestGit $author @('commit','-m','update') | Out-Null; Invoke-TestGit $author @('push','origin','main') | Out-Null
    $runner=Join-Path $temporary 'detached-runner.ps1'; Copy-Item (Join-Path $client 'Update-Tool.ps1') $runner
    $update=Invoke-Updater $client $runner
    Assert-True ($update.code -eq 0) 'Fast-forward succeeds'
    Assert-True ([IO.File]::ReadAllText((Join-Path $client 'version.txt')) -eq 'two') 'The requested update was applied'
    Assert-True ((Get-Content (Join-Path $client 'Update-Tool.ps1') -Raw).Contains('# Updated runner fixture')) 'An updater can update itself from a detached copy'
    Assert-True ([IO.File]::ReadAllText($privateLog) -eq 'private fixture') 'Past diagnostic logs survive an update'
    $update=Invoke-Updater $client
    Assert-True ($update.code -eq 0) 'Already-current updates succeed'
    $update=Invoke-Updater $client (Join-Path $client 'scripts\Launch-Update.ps1')
    Assert-True ($update.code -eq 0) 'Detached bootstrap launches from a Japanese path with an apostrophe'
    [IO.File]::WriteAllText((Join-Path $client 'version.txt'),'local edit')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and [IO.File]::ReadAllText((Join-Path $client 'version.txt')) -eq 'local edit') 'Tracked local changes are never overwritten'
    $update=Invoke-Updater $client (Join-Path $client 'scripts\Launch-Update.ps1')
    Assert-True ($update.code -ne 0) 'Bootstrap propagates update failures to its caller'
    Invoke-TestGit $client @('restore','version.txt') | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'untracked.txt'),'keep')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Test-Path (Join-Path $client 'untracked.txt'))) 'Untracked files are preserved and stop updates'
    Remove-Item -LiteralPath (Join-Path $client 'untracked.txt')
    Invoke-TestGit $client @('remote','set-url','origin',(Join-Path $temporary 'missing-remote.git')) | Out-Null
    $head=Invoke-TestGit $client @('rev-parse','HEAD')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Invoke-TestGit $client @('rev-parse','HEAD')) -eq $head) 'Fetch failure preserves the installed revision'
    Invoke-TestGit $client @('remote','set-url','origin',$remote) | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'local.txt'),'local commit')
    Invoke-TestGit $client @('add','local.txt') | Out-Null; Invoke-TestGit $client @('commit','-m','local-only') | Out-Null
    $head=Invoke-TestGit $client @('rev-parse','HEAD')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Invoke-TestGit $client @('rev-parse','HEAD')) -eq $head) 'Local-only commits are not reset or silently published'
    [IO.File]::WriteAllText((Join-Path $author 'remote.txt'),'remote commit')
    Invoke-TestGit $author @('add','remote.txt') | Out-Null; Invoke-TestGit $author @('commit','-m','remote-only') | Out-Null; Invoke-TestGit $author @('push','origin','main') | Out-Null
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Invoke-TestGit $client @('rev-parse','HEAD')) -eq $head) 'Diverged histories stop without a reset'
    Assert-True ([IO.File]::ReadAllText($privateLog) -eq 'private fixture') 'Logs survive every failure path'
    Write-Host ('All ' + $script:checks + ' checks passed.') -ForegroundColor Green
} finally {
    $expectedRoot=[IO.Path]::GetFullPath((Join-Path $root 'test-output')) + [IO.Path]::DirectorySeparatorChar
    $resolved=[IO.Path]::GetFullPath($temporary)
    if ($resolved.StartsWith($expectedRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
