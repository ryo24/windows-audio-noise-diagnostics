$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot;$checks=0
function Assert-Launcher {param([bool]$Value,[string]$Message);if(-not $Value){throw ('FAIL: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
function Invoke-FixtureGit {param([string]$Repo,[string[]]$Arguments);$previous=$ErrorActionPreference;$ErrorActionPreference='Continue';$value=& git -C $Repo @Arguments 2>&1;$result=$LASTEXITCODE;$ErrorActionPreference=$previous;if($result -ne 0){throw ($value -join "`n")};return $value}
function Launch {param([string]$Repo,[string]$Mode='Update')
    $p=New-Object Diagnostics.Process;$p.StartInfo.FileName='powershell.exe'
    $p.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $Repo 'scripts/Launch-Develop.ps1')+'" -Mode '+$Mode+' -NoPause -SmokeTest'
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    $p.StartInfo.StandardOutputEncoding=[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage);$p.StartInfo.StandardErrorEncoding=$p.StartInfo.StandardOutputEncoding
    try{[void]$p.Start();$output=$p.StandardOutput.ReadToEndAsync();$errors=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(30000)){$p.Kill();throw 'Launcher timed out'};[pscustomobject]@{code=$p.ExitCode;output=$output.Result+$errors.Result}}finally{$p.Dispose()}
}
$temporary=Join-Path (Join-Path $root 'test-output') ('dev-'+[guid]::NewGuid().ToString('N').Substring(0,12)+" 日本語 O'Brien")
[IO.Directory]::CreateDirectory($temporary)|Out-Null
try{
    $remote=Join-Path $temporary 'remote.git';$author=Join-Path $temporary 'author';$client=Join-Path $temporary 'client'
    [void](Invoke-FixtureGit $temporary @('init','--bare','--initial-branch=main',$remote));[void](Invoke-FixtureGit $temporary @('clone',$remote,$author))
    [void](Invoke-FixtureGit $author @('config','user.name','Fixture'));[void](Invoke-FixtureGit $author @('config','user.email','fixture@example.invalid'));[void](Invoke-FixtureGit $author @('config','commit.gpgsign','false'))
    [IO.Directory]::CreateDirectory((Join-Path $author 'scripts'))|Out-Null
    foreach($name in @('Launch-Develop.ps1','Develop-Tool.ps1','Update-Tool.ps1')){Copy-Item -LiteralPath (Join-Path $root ('scripts/'+$name)) -Destination (Join-Path $author ('scripts/'+$name))}
    [IO.File]::WriteAllText((Join-Path $author '.gitignore'),"/data/`n")
    [IO.File]::WriteAllText((Join-Path $author 'VERSION'),'main')
    $app='param([switch]$SmokeTest);$r=Split-Path -Parent $PSScriptRoot;[IO.Directory]::CreateDirectory((Join-Path $r "data"))|Out-Null;[IO.File]::WriteAllText((Join-Path $r "data/started.txt"),(Get-Content (Join-Path $r "VERSION") -Raw));exit 0'
    [IO.File]::WriteAllText((Join-Path $author 'scripts/Start-Diagnostics.ps1'),$app)
    [void](Invoke-FixtureGit $author @('add','.'));[void](Invoke-FixtureGit $author @('commit','-m','main fixture'));[void](Invoke-FixtureGit $author @('push','origin','main'))
    [void](Invoke-FixtureGit $author @('switch','-c','develop'));[IO.File]::WriteAllText((Join-Path $author 'VERSION'),'develop one')
    [void](Invoke-FixtureGit $author @('add','VERSION'));[void](Invoke-FixtureGit $author @('commit','-m','develop fixture'));[void](Invoke-FixtureGit $author @('push','origin','develop'))
    [void](Invoke-FixtureGit $temporary @('clone','--branch','main','--single-branch',$remote,$client))
    [IO.Directory]::CreateDirectory((Join-Path $client 'data'))|Out-Null
    $private=Join-Path $client 'data/private.json';[IO.File]::WriteAllText($private,'private fixture')
    $head=Invoke-FixtureGit $client @('rev-parse','HEAD');$runtime=Join-Path $client 'data/develop-tool'
    $result=Launch $client
    if($result.code -ne 0){throw $result.output}
    Assert-Launcher ($result.code -eq 0 -and (Get-Content (Join-Path $runtime 'VERSION') -Raw) -eq 'develop one') 'Main single-branch clone can install develop into its own ignored folder'
    Assert-Launcher ((Invoke-FixtureGit $client @('branch','--show-current')) -eq 'main' -and (Invoke-FixtureGit $client @('rev-parse','HEAD')) -eq $head -and -not @(Invoke-FixtureGit $client @('status','--porcelain')).Count -and (Get-Content $private -Raw) -eq 'private fixture') 'Main branch, clean checkout and existing data remain unchanged'
    Assert-Launcher (-not (Test-Path (Join-Path $runtime 'data/started.txt'))) 'Update command does not start the app'
    $result=Launch $client 'Start'
    Assert-Launcher ($result.code -eq 0 -and (Get-Content (Join-Path $runtime 'data/started.txt') -Raw) -eq 'develop one') 'Start command updates and launches the development app'
    [IO.File]::WriteAllText((Join-Path $runtime 'data/keep.json'),'development data')
    [IO.File]::WriteAllText((Join-Path $author 'VERSION'),'develop two')
    Add-Content (Join-Path $author 'scripts/Develop-Tool.ps1') '# self-update fixture' -Encoding UTF8
    [void](Invoke-FixtureGit $author @('add','VERSION','scripts/Develop-Tool.ps1'));[void](Invoke-FixtureGit $author @('commit','-m','develop update'));[void](Invoke-FixtureGit $author @('push','origin','develop'))
    $result=Launch $runtime 'Start'
    Assert-Launcher ($result.code -eq 0 -and (Get-Content (Join-Path $runtime 'data/started.txt') -Raw) -eq 'develop two' -and (Get-Content (Join-Path $runtime 'data/keep.json') -Raw) -eq 'development data' -and -not (Test-Path (Join-Path $runtime 'data/develop-tool'))) 'Existing develop checkout updates itself and preserves data without nesting another clone'
    [IO.File]::WriteAllText((Join-Path $runtime 'VERSION'),'local edit')
    $result=Launch $client 'Start'
    Assert-Launcher ($result.code -ne 0 -and (Get-Content (Join-Path $runtime 'VERSION') -Raw) -eq 'local edit' -and (Get-Content (Join-Path $runtime 'data/started.txt') -Raw) -eq 'develop two') 'Local edits prevent update and launch without overwriting them'
    [void](Invoke-FixtureGit $runtime @('restore','VERSION'));[IO.File]::WriteAllText((Join-Path $runtime 'untracked.md'),'keep')
    $result=Launch $client
    Assert-Launcher ($result.code -ne 0 -and (Get-Content (Join-Path $runtime 'untracked.md') -Raw) -eq 'keep') 'Untracked development files are retained and stop updates'
    Remove-Item -LiteralPath (Join-Path $runtime 'untracked.md')
    [void](Invoke-FixtureGit $runtime @('switch','-c','codex/fixture'));$result=Launch $client
    Assert-Launcher ($result.code -ne 0 -and (Invoke-FixtureGit $runtime @('branch','--show-current')) -eq 'codex/fixture') 'A managed clone on a feature branch is never silently switched'
    [void](Invoke-FixtureGit $runtime @('switch','develop'))
    $lock=[IO.File]::Open((Join-Path $runtime 'data/tool.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$result=Launch $client;Assert-Launcher ($result.code -ne 0) 'Running development app prevents code updates'}finally{$lock.Dispose()}
    $lock=[IO.File]::Open((Join-Path $client 'data/develop-launch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$result=Launch $client;Assert-Launcher ($result.code -ne 0) 'Concurrent development launchers are serialized'}finally{$lock.Dispose()}
    [void](Invoke-FixtureGit $runtime @('remote','set-url','origin',(Join-Path $temporary 'missing.git')));$result=Launch $client
    Assert-Launcher ($result.code -ne 0) 'Changed managed origin is not silently used'
    [void](Invoke-FixtureGit $runtime @('remote','set-url','origin',$remote))
    [void](Invoke-FixtureGit $client @('remote','set-url','origin',(Join-Path $temporary 'missing.git')));[void](Invoke-FixtureGit $runtime @('remote','set-url','origin',(Join-Path $temporary 'missing.git')))
    $before=Invoke-FixtureGit $runtime @('rev-parse','HEAD');$result=Launch $client 'Start'
    Assert-Launcher ($result.code -ne 0 -and (Invoke-FixtureGit $runtime @('rev-parse','HEAD')) -eq $before -and (Get-Content (Join-Path $runtime 'data/keep.json') -Raw) -eq 'development data') 'Network failure retains installed develop and data without launching stale code'
    $fresh=Join-Path $temporary 'fresh';[void](Invoke-FixtureGit $temporary @('clone','--branch','main','--single-branch',$remote,$fresh));[void](Invoke-FixtureGit $fresh @('remote','set-url','origin',(Join-Path $temporary 'missing.git')))
    $result=Launch $fresh
    Assert-Launcher ($result.code -ne 0 -and -not (Test-Path (Join-Path $fresh 'data/develop-tool')) -and -not @(Get-ChildItem (Join-Path $fresh 'data') -Filter '.develop-tool-download-*').Count) 'Failed first install leaves no completed-looking clone or partial staging tree'
    [IO.Directory]::CreateDirectory((Join-Path $fresh 'data/develop-tool'))|Out-Null;[IO.File]::WriteAllText((Join-Path $fresh 'data/develop-tool/keep.txt'),'keep')
    $result=Launch $fresh
    Assert-Launcher ($result.code -ne 0 -and (Get-Content (Join-Path $fresh 'data/develop-tool/keep.txt') -Raw) -eq 'keep') 'Unrelated files at the managed destination are never replaced'
    Write-Host ('All '+$checks+' development launcher checks passed.')
}finally{
    $allowed=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($temporary).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
