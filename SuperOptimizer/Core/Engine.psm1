Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path $PSScriptRoot -Parent
$script:ConfigPath = Join-Path $script:AppRoot 'Config.json'
$script:StateRoot = Join-Path $script:AppRoot 'State'
$script:RuntimeRoot = Join-Path $script:StateRoot 'Runtime'
$script:MachinesRoot = Join-Path $script:StateRoot 'Machines'
$script:Config = $null
$script:MachineId = $null
$script:MachineRoot = $null
$script:LogFile = $null
$script:ProgressFile = $null
$script:DryRun = $false
$script:WarningCount = 0
$script:WarningMessages = New-Object System.Collections.Generic.List[string]
$script:ProfileTransitionNeedsReboot = $false
$script:RamNativeApiReady = $false
$script:LastProgressLogMessage = $null
$script:LastProgressLogPercent = -1

function Get-SOConfig {
    if ($null -eq $script:Config) {
        if (-not (Test-Path $script:ConfigPath)) { throw "Config.json ausente: $script:ConfigPath" }
        $script:Config = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:Config
}

function Get-SOMachineId {
    try {
        $id = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($id) { return ($id -replace '[^a-zA-Z0-9-]','_') }
    } catch {}
    return (($env:COMPUTERNAME + '_' + $env:USERNAME) -replace '[^a-zA-Z0-9-]','_')
}

function Initialize-SOEnvironment {
    foreach($p in @($script:StateRoot,$script:RuntimeRoot,$script:MachinesRoot)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
    $script:MachineId = Get-SOMachineId
    $script:MachineRoot = Join-Path $script:MachinesRoot $script:MachineId
    foreach($name in @('Registry','Services','Tasks','Settings','Maintenance','PerGame','Reports','History','Profiles')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:MachineRoot $name) | Out-Null
    }
    [ordered]@{
        MachineId=$script:MachineId
        ComputerName=$env:COMPUTERNAME
        LastSeen=(Get-Date).ToString('o')
        Version=(Get-SOConfig).version
    } | ConvertTo-Json | Set-Content (Join-Path $script:MachineRoot 'machine.json') -Encoding UTF8
}

function Set-SOLogFile([string]$Path) { $script:LogFile = $Path }
function Set-SOProgressFile([string]$Path) { $script:ProgressFile = $Path; $script:LastProgressLogMessage=$null; $script:LastProgressLogPercent=-1 }
function Set-SODryRun([bool]$Enabled) { $script:DryRun = $Enabled }

function Write-SOLog {
    param([string]$Message,[ValidateSet('INFO','OK','WARN','ERROR','PLAN')][string]$Level='INFO')
    if($Level -eq 'WARN'){
        $script:WarningCount++
        if($null -eq $script:WarningMessages){$script:WarningMessages = New-Object System.Collections.Generic.List[string]}
        [void]$script:WarningMessages.Add($Message)
    }
    $line='[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message
    if($script:LogFile){
        try{Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop}catch{}
    }
}

function Reset-SOWarnings {
    $script:WarningCount = 0
    $script:WarningMessages = New-Object System.Collections.Generic.List[string]
}
function Get-SOWarningCount { return [int]$script:WarningCount }
function Get-SOWarningMessages { if($null -eq $script:WarningMessages){return [string[]]@()}; return [string[]]$script:WarningMessages.ToArray() }

function Write-SOProgress {
    param([int]$Percent,[string]$Message,[switch]$NoLog)
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    # Progresso é telemetria/UI. Evita duplicar mensagens idênticas no log e
    # permite atualizações silenciosas (ex.: percentuais de DISM/SFC).
    if(-not $NoLog){
        if(([string]$Message -ne [string]$script:LastProgressLogMessage) -or ($Percent -ne [int]$script:LastProgressLogPercent)){
            Write-SOLog $Message 'INFO'
            $script:LastProgressLogMessage=[string]$Message
            $script:LastProgressLogPercent=[int]$Percent
        }
    }

    # O arquivo de progresso é somente telemetria da UI. Nenhuma falha aqui pode
    # cancelar a operação real (Registro, serviços, DISM, rollback etc.).
    if (-not $script:ProgressFile) { return }
    try {
        $json = ([ordered]@{Percent=$Percent;Message=$Message;Updated=(Get-Date).ToString('o')} | ConvertTo-Json -Compress)
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        for($attempt=1;$attempt -le 5;$attempt++){
            $stream=$null
            try {
                $stream=[IO.File]::Open($script:ProgressFile,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
                $stream.Write($bytes,0,$bytes.Length)
                $stream.Flush()
                return
            } catch {
                if($attempt -lt 5){ Start-Sleep -Milliseconds 25 }
            } finally {
                if($stream){ $stream.Dispose() }
            }
        }
    } catch { return }
}

function Get-SOHash([string]$Text) {
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-SORegDir { Join-Path $script:MachineRoot 'Registry' }
function Get-SOSvcDir { Join-Path $script:MachineRoot 'Services' }
function Get-SOTaskDir { Join-Path $script:MachineRoot 'Tasks' }
function Get-SOSettingsDir { Join-Path $script:MachineRoot 'Settings' }
function Get-SOMaintenanceFile { Join-Path (Join-Path $script:MachineRoot 'Maintenance') 'history.json' }
function Get-SOReportsDir { Join-Path $script:MachineRoot 'Reports' }
function Get-SOHistoryDir { Join-Path $script:MachineRoot 'History' }
function Get-SOHistoryFile { Join-Path (Get-SOHistoryDir) 'events.json' }
function Get-SOCustomProfilesFile { Join-Path (Join-Path $script:MachineRoot 'Profiles') 'custom_profiles.json' }
function Get-SOPostRebootFile { Join-Path (Get-SOSettingsDir) 'post_reboot_pending.json' }
function Get-SOUpdateSessionFile { Join-Path (Get-SOSettingsDir) 'update_session.json' }

function Backup-SORegistryValue {
    param([string]$Path,[string]$Name,[string]$Category)
    $file = Join-Path (Get-SORegDir) ((Get-SOHash "$Path|$Name") + '.json')
    if (Test-Path -LiteralPath $file) {
        try{
            $existing=Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            $valid=([string]$existing.Path -eq $Path) -and ([string]$existing.Name -eq $Name) -and
                   ($existing.PSObject.Properties['Category']) -and ($existing.PSObject.Properties['Exists'])
            if($valid -and [bool]$existing.Exists){
                $valid=($existing.PSObject.Properties['Kind']) -and (@('String','ExpandString','Binary','DWord','MultiString','QWord') -contains [string]$existing.Kind) -and ($existing.PSObject.Properties['Data'])
            }
            if($valid){return $true}
            Write-SOLog ("Backup de Registro inconsistente: {0}" -f $file) 'WARN'
            return $false
        }catch{
            Write-SOLog ("Backup de Registro corrompido: {0} :: {1}" -f $file,$_.Exception.Message) 'WARN'
            return $false
        }
    }

    $exists=$false; $kind=$null; $data=$null; $keyExisted=$false
    $tmp=$file+'.tmp.'+[guid]::NewGuid().ToString('N')
    try {
        $keyExisted=Test-Path -LiteralPath $Path
        if ($keyExisted) {
            $key=Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($key.GetValueNames() -contains $Name) {
                $exists=$true
                $kind=$key.GetValueKind($Name).ToString()
                $data=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        [ordered]@{Path=$Path;Name=$Name;Category=$Category;KeyExisted=$keyExisted;Exists=$exists;Kind=$kind;Data=$data} |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        $verify=Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if([string]$verify.Path -ne $Path -or [string]$verify.Name -ne $Name -or [string]$verify.Category -ne $Category){throw 'Falha validando o backup recém-criado.'}
        if(-not $verify.PSObject.Properties['Exists']){throw 'Backup sem campo Exists.'}
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
        return $true
    } catch {
        Write-SOLog ("Não foi possível criar backup seguro do Registro: {0} / {1} :: {2}" -f $Path,$Name,$_.Exception.Message) 'WARN'
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Test-SORegistryDataEqual {
    param([string]$Kind,$Actual,$Expected)
    try{
        switch($Kind){
            'DWord' { return ([int64]$Actual -eq [int64]$Expected) }
            'QWord' { return ([int64]$Actual -eq [int64]$Expected) }
            'Binary' {
                $a=[byte[]]$Actual;$e=[byte[]]$Expected
                if($a.Length -ne $e.Length){return $false}
                for($i=0;$i -lt $a.Length;$i++){if($a[$i] -ne $e[$i]){return $false}}
                return $true
            }
            'MultiString' {
                $a=@([string[]]$Actual);$e=@([string[]]$Expected)
                if($a.Count -ne $e.Count){return $false}
                for($i=0;$i -lt $a.Count;$i++){if([string]$a[$i] -ne [string]$e[$i]){return $false}}
                return $true
            }
            default { return ([string]$Actual -eq [string]$Expected) }
        }
    }catch{return $false}
}

function Set-SORegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Type,
        $Value,
        [string]$Category,
        [switch]$Optional
    )

    if ($script:DryRun) {
        $suffix=if($Optional){' [opcional]'}else{''}
        Write-SOLog "REG $Category :: $Path :: $Name = $Value ($Type)$suffix" 'PLAN'
        return $true
    }

    $backupOk=Backup-SORegistryValue $Path $Name $Category
    if(-not $backupOk){
        $msg="Ajuste não aplicado porque o estado original não pôde ser salvo: $Path / $Name"
        if($Optional){Write-SOLog ($msg+' — ajuste opcional ignorado.') 'WARN';return $false}
        throw $msg
    }
    try {
        # Nunca execute New-Item -Force sobre uma chave que já existe. No Registry Provider
        # do Windows PowerShell 5.1 isso pode tentar recriar a chave e gerar
        # UnauthorizedAccessException mesmo em HKCU (observado em Explorer\\Advanced).
        if(-not(Test-Path -LiteralPath $Path)){
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $key=Get-Item -LiteralPath $Path -ErrorAction Stop
        if($key.GetValueNames() -contains $Name){
            $currentKind=$key.GetValueKind($Name).ToString()
            if($currentKind -eq $Type){
                Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Force -ErrorAction Stop
            }else{
                New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
            }
        }else{
            New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        $key=Get-Item -LiteralPath $Path -ErrorAction Stop
        $actual=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if(-not(Test-SORegistryDataEqual $Type $actual $Value)){
            throw ("Verificação pós-escrita falhou. Esperado={0}; Atual={1}" -f $Value,$actual)
        }
        Write-SOLog "Registro aplicado e verificado: $Category / $Name" 'OK'
        return $true
    } catch {
        $msg="Falha no Registro: $Path / $Name :: $($_.Exception.Message)"
        if($Optional){
            Write-SOLog ($msg + ' — ajuste opcional ignorado; o perfil continuará.') 'WARN'
            return $false
        }
        Write-SOLog $msg 'ERROR'
        throw
    }
}

function Restore-SORegistry {
    param([string]$Category='ALL')
    $files=@(Get-ChildItem (Get-SORegDir) -Filter '*.json' -ErrorAction SilentlyContinue)
    foreach($f in $files) {
        try {
            $s=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if(-not $s.PSObject.Properties['Path'] -or -not $s.PSObject.Properties['Name']){throw 'Backup sem Path/Name.'}
            if ($Category -ne 'ALL' -and [string]$s.Category -ne $Category) { continue }
            if ($script:DryRun) { Write-SOLog "Restauraria REG $($s.Path) / $($s.Name)" 'PLAN'; continue }

            if ([bool]$s.Exists) {
                $kind=[string]$s.Kind
                if($kind -notin @('String','ExpandString','Binary','DWord','MultiString','QWord')){throw ("Tipo de Registro inválido no backup: {0}" -f $kind)}
                $restorePath=[string]$s.Path;$restoreName=[string]$s.Name
                if(-not(Test-Path -LiteralPath $restorePath)){
                    New-Item -Path $restorePath -Force -ErrorAction Stop | Out-Null
                }
                $val=$s.Data
                if($kind -eq 'Binary'){ $val=[byte[]]$s.Data }
                elseif($kind -eq 'MultiString'){ $val=[string[]]$s.Data }
                $key=Get-Item -LiteralPath $restorePath -ErrorAction Stop
                if($key.GetValueNames() -contains $restoreName){
                    $currentKind=$key.GetValueKind($restoreName).ToString()
                    if($currentKind -eq $kind){
                        Set-ItemProperty -LiteralPath $restorePath -Name $restoreName -Value $val -Force -ErrorAction Stop
                    }else{
                        New-ItemProperty -LiteralPath $restorePath -Name $restoreName -PropertyType $kind -Value $val -Force -ErrorAction Stop | Out-Null
                    }
                }else{
                    New-ItemProperty -LiteralPath $restorePath -Name $restoreName -PropertyType $kind -Value $val -Force -ErrorAction Stop | Out-Null
                }
                $key=Get-Item -LiteralPath $restorePath -ErrorAction Stop
                $actual=$key.GetValue($restoreName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if(-not(Test-SORegistryDataEqual $kind $actual $val)){throw ("Valor restaurado não confere. Atual={0}" -f $actual)}
            } else {
                Remove-ItemProperty -Path ([string]$s.Path) -Name ([string]$s.Name) -Force -ErrorAction SilentlyContinue
                $key=Get-Item -LiteralPath ([string]$s.Path) -ErrorAction SilentlyContinue
                if($key -and $key.GetValueNames() -contains [string]$s.Name){throw 'Valor deveria ter sido removido, mas ainda existe.'}
                # Se esta chave foi criada apenas para o tweak e ficou vazia, remova-a.
                $keyExisted=$true
                if($s.PSObject.Properties['KeyExisted']){$keyExisted=[bool]$s.KeyExisted}
                if(-not $keyExisted -and $key){
                    $hasValues=($key.GetValueNames().Count -gt 0)
                    $hasChildren=@(Get-ChildItem -LiteralPath ([string]$s.Path) -ErrorAction SilentlyContinue).Count -gt 0
                    if(-not $hasValues -and -not $hasChildren){Remove-Item -LiteralPath ([string]$s.Path) -Force -ErrorAction SilentlyContinue}
                }
            }
            Write-SOLog ("Registro restaurado: {0} / {1}" -f $s.Path,$s.Name) 'OK'
        } catch {
            Write-SOLog ("Falha restaurando backup de Registro {0}: {1}" -f $f.Name,$_.Exception.Message) 'WARN'
        }
    }
}

function Backup-SOService {
    param([string]$Name)
    $file=Join-Path (Get-SOSvcDir) ($Name + '.json')
    if(Test-Path -LiteralPath $file){
        try{
            $existing=Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            $valid=([string]$existing.Name -eq $Name) -and ($existing.PSObject.Properties['Start']) -and ($existing.PSObject.Properties['WasRunning']) -and ([int]$existing.Start -ge 0) -and ([int]$existing.Start -le 4)
            if($valid){return $true}
        }catch{}
        Write-SOLog ("Backup de serviço inválido: {0}" -f $file) 'WARN';return $false
    }
    $svc=Get-Service $Name -ErrorAction SilentlyContinue
    $rp="HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if(-not $svc -or -not(Test-Path $rp)){return $false}
    $tmp=$file+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{
        $r=Get-ItemProperty -LiteralPath $rp -ErrorAction Stop
        if(-not $r.PSObject.Properties['Start']){throw 'Valor Start ausente.'}
        $start=[int]$r.Start;$delayed=$null
        if($r.PSObject.Properties['DelayedAutoStart']){$delayed=$r.DelayedAutoStart}
        [ordered]@{Name=$Name;Start=$start;DelayedAutoStart=$delayed;WasRunning=($svc.Status -eq 'Running')} |
            ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        $verify=Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if([string]$verify.Name -ne $Name -or -not $verify.PSObject.Properties['Start'] -or -not $verify.PSObject.Properties['WasRunning']){throw 'Backup de serviço não passou na validação.'}
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
        return $true
    }catch{
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Write-SOLog ("Não foi possível salvar o estado do serviço {0}: {1}" -f $Name,$_.Exception.Message) 'WARN';return $false
    }
}

function Set-SOServiceMode {
    param([string]$Name,[ValidateSet('Disabled','Manual','Automatic')][string]$Mode,[string]$Label='')
    $svc=Get-Service $Name -ErrorAction SilentlyContinue
    if(-not $svc){Write-SOLog "Serviço não presente nesta edição: $Name" 'INFO';return}
    if($script:DryRun){Write-SOLog "Serviço $Name -> $Mode ($Label)" 'PLAN';return}
    if(-not(Backup-SOService $Name)){Write-SOLog ("Serviço {0} não alterado porque o backup original não pôde ser garantido" -f $Name) 'WARN';return}
    try {
        switch($Mode){
            'Disabled' {Set-Service $Name -StartupType Disabled -ErrorAction Stop;Stop-Service $Name -Force -ErrorAction SilentlyContinue}
            'Manual' {Set-Service $Name -StartupType Manual -ErrorAction Stop}
            'Automatic' {Set-Service $Name -StartupType Automatic -ErrorAction Stop}
        }
        $expectedStart=switch($Mode){'Disabled'{4};'Manual'{3};'Automatic'{2}}
        $actualStart=Get-SOServiceStart $Name
        if($null -eq $actualStart -or [int]$actualStart -ne [int]$expectedStart){throw ("StartupType não confirmou o modo {0}. Start={1}" -f $Mode,$actualStart)}
        Write-SOLog "Serviço $Name -> $Mode (verificado)" 'OK'
    } catch {Write-SOLog ("Falha no serviço {0}: {1}" -f $Name,$_.Exception.Message) 'WARN'}
}

function Set-SOServiceStartupFromBackup {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Start,
        $DelayedAutoStart=$null
    )
    $startArg=switch($Start){
        2 { if($null -ne $DelayedAutoStart -and [int]$DelayedAutoStart -eq 1){'delayed-auto'}else{'auto'} }
        3 { 'demand' }
        4 { 'disabled' }
        default { throw ("StartupType não suportado para restauração: {0} (Start={1})" -f $Name,$Start) }
    }
    & sc.exe config $Name start= $startArg 2>$null | Out-Null
    if($LASTEXITCODE -ne 0){throw ("sc.exe config falhou para {0} (Start={1}, ExitCode={2})" -f $Name,$Start,$LASTEXITCODE)}
    $verify=Get-SOServiceStart $Name
    if($null -eq $verify -or [int]$verify -ne $Start){throw ("StartupType não confirmou restauração de {0}. Esperado={1}; Atual={2}" -f $Name,$Start,$verify)}
}

function Restore-SOServices {
    param([string[]]$Names=@())
    foreach($f in @(Get-ChildItem (Get-SOSvcDir) -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $state=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if(-not $state.PSObject.Properties['Name'] -or -not $state.PSObject.Properties['Start']){throw 'Backup sem Name/Start.'}
            if($Names.Count -gt 0 -and $Names -notcontains [string]$state.Name){continue}
            if($script:DryRun){Write-SOLog "Restauraria serviço $($state.Name) Start=$($state.Start)" 'PLAN';continue}
            $rp="HKLM:\SYSTEM\CurrentControlSet\Services\$($state.Name)"
            if(-not(Test-Path -LiteralPath $rp)){Write-SOLog ("Serviço não existe mais: {0}" -f $state.Name) 'WARN';continue}
            # Não escreva Start/DelayedAutoStart diretamente no Registry: alguns serviços
            # protegidos (ex.: TrkWks) permitem restauração via Service Control Manager,
            # mas negam Set-ItemProperty mesmo em processo elevado.
            Set-SOServiceStartupFromBackup -Name ([string]$state.Name) -Start ([int]$state.Start) -DelayedAutoStart $state.DelayedAutoStart
            if([bool]$state.WasRunning){Start-Service ([string]$state.Name) -ErrorAction SilentlyContinue}
            else{Stop-Service ([string]$state.Name) -Force -ErrorAction SilentlyContinue}
            Write-SOLog ("Serviço restaurado: {0}" -f $state.Name) 'OK'
        } catch {Write-SOLog ("Falha restaurando serviço {0}: {1}" -f $f.BaseName,$_.Exception.Message) 'WARN'}
    }
}

function Backup-SOTask {
    param([string]$TaskPath,[string]$TaskName)
    $file=Join-Path (Get-SOTaskDir) ((Get-SOHash "$TaskPath|$TaskName")+'.json')
    if(Test-Path -LiteralPath $file){
        try{
            $existing=Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            if([string]$existing.TaskPath -eq $TaskPath -and [string]$existing.TaskName -eq $TaskName -and $existing.PSObject.Properties['Enabled']){return $true}
        }catch{}
        Write-SOLog ("Backup de tarefa inválido: {0}" -f $file) 'WARN';return $false
    }
    $task=Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if(-not $task){return $false}
    $tmp=$file+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{
        [ordered]@{TaskPath=$TaskPath;TaskName=$TaskName;Enabled=($task.State -ne 'Disabled')} | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        $verify=Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if([string]$verify.TaskPath -ne $TaskPath -or [string]$verify.TaskName -ne $TaskName -or -not $verify.PSObject.Properties['Enabled']){throw 'Backup da tarefa não passou na validação.'}
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
        return $true
    }catch{
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Write-SOLog ("Não foi possível salvar a tarefa {0}{1}: {2}" -f $TaskPath,$TaskName,$_.Exception.Message) 'WARN';return $false
    }
}

function Disable-SOTask {
    param([string]$TaskPath,[string]$TaskName)
    $t=Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if(-not $t){return}
    if($script:DryRun){Write-SOLog "Task OFF: $TaskPath$TaskName" 'PLAN';return}
    if(-not(Backup-SOTask $TaskPath $TaskName)){Write-SOLog ("Tarefa não alterada porque o backup original não pôde ser garantido: {0}{1}" -f $TaskPath,$TaskName) 'WARN';return}
    try{
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        $after=Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if($after -and $after.State -ne 'Disabled'){Write-SOLog ("Tarefa não confirmou estado Disabled: {0}{1}" -f $TaskPath,$TaskName) 'WARN'}
        else{Write-SOLog ("Tarefa desativada: {0}{1}" -f $TaskPath,$TaskName) 'OK'}
    }catch{Write-SOLog ("Falha desativando tarefa {0}{1}: {2}" -f $TaskPath,$TaskName,$_.Exception.Message) 'WARN'}
}

function Restore-SOTasks {
    foreach($f in (Get-ChildItem (Get-SOTaskDir) -Filter '*.json' -ErrorAction SilentlyContinue)){
        try{
            $state=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if($script:DryRun){Write-SOLog "Restauraria tarefa $($state.TaskPath)$($state.TaskName)" 'PLAN';continue}
            $task=Get-ScheduledTask -TaskPath $state.TaskPath -TaskName $state.TaskName -ErrorAction SilentlyContinue
            if(-not $task){Write-SOLog ("Tarefa não existe mais: {0}{1}" -f $state.TaskPath,$state.TaskName) 'WARN';continue}
            if([bool]$state.Enabled){Enable-ScheduledTask -TaskPath $state.TaskPath -TaskName $state.TaskName -ErrorAction Stop|Out-Null}
            else{Disable-ScheduledTask -TaskPath $state.TaskPath -TaskName $state.TaskName -ErrorAction Stop|Out-Null}
            $after=Get-ScheduledTask -TaskPath $state.TaskPath -TaskName $state.TaskName -ErrorAction SilentlyContinue
            $enabledNow=($after -and $after.State -ne 'Disabled')
            if($enabledNow -ne [bool]$state.Enabled){Write-SOLog ("Tarefa não confirmou estado original: {0}{1}" -f $state.TaskPath,$state.TaskName) 'WARN'}
            else{Write-SOLog ("Tarefa restaurada: {0}{1}" -f $state.TaskPath,$state.TaskName) 'OK'}
        }catch{Write-SOLog "Falha restaurando tarefa: $($_.Exception.Message)" 'WARN'}
    }
}

function Save-SOSetting {
    param([string]$Name,$Object)
    $p=Join-Path (Get-SOSettingsDir) ($Name+'.json')
    $tmp=$p+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{
        $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        [void](Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop
        return $true
    }catch{
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-SOLog ("Não foi possível salvar State/{0}: {1}" -f $Name,$_.Exception.Message) 'WARN'
        return $false
    }
}

function Get-SOSetting {
    param([string]$Name)
    $p=Join-Path (Get-SOSettingsDir) ($Name+'.json')
    if(-not(Test-Path -LiteralPath $p)){return $null}
    try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop}
    catch{Write-SOLog ("State inválido em {0}: {1}" -f $p,$_.Exception.Message) 'WARN';return $null}
}

function Backup-SOHibernation {
    $path=Join-Path (Get-SOSettingsDir) 'hibernation.json'
    if(Test-Path -LiteralPath $path){
        $existing=Get-SOSetting 'hibernation'
        if(-not $existing){return $false}
        if(-not $existing.PSObject.Properties['Exists']){Write-SOLog 'Backup de hibernação sem campo Exists; ajuste ignorado.' 'WARN';return $false}
        if(-not [bool]$existing.Exists){
            Write-SOLog 'Backup antigo de hibernação não contém um valor HibernateEnabled original; por segurança a hibernação não será alterada.' 'WARN'
            return $false
        }
        if(-not $existing.PSObject.Properties['Enabled']){Write-SOLog 'Backup de hibernação sem campo Enabled; ajuste ignorado.' 'WARN';return $false}
        return $true
    }
    try{
        $rp='HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        $key=Get-Item -LiteralPath $rp -ErrorAction Stop
        $exists=$key.GetValueNames() -contains 'HibernateEnabled'
        if(-not $exists){
            Write-SOLog 'HibernateEnabled não existe nesta instalação; não é possível garantir rollback exato. Ajuste de hibernação ignorado.' 'WARN'
            return $false
        }
        $value=$key.GetValue('HibernateEnabled')
        return (Save-SOSetting 'hibernation' ([ordered]@{Exists=$true;Enabled=$value}))
    }catch{
        Write-SOLog ("Não foi possível salvar o estado da hibernação: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Disable-SOHibernation {
    if($script:DryRun){Write-SOLog 'Hibernação OFF' 'PLAN';return $true}
    if(-not(Backup-SOHibernation)){
        Write-SOLog 'Hibernação não foi alterada porque o estado original não pôde ser salvo.' 'WARN'
        return $false
    }
    if(-not(Invoke-SOPowerCfg -Arguments @('/hibernate','off') -Label 'desativar hibernação' -Optional)){
        return $false
    }
    Write-SOLog 'Hibernação desativada' 'OK'
    return $true
}

function Restore-SOHibernation {
    $path=Join-Path (Get-SOSettingsDir) 'hibernation.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    $s=Get-SOSetting 'hibernation'
    if(-not $s){Write-SOLog 'Backup de hibernação inválido; restauração ignorada.' 'WARN';return}
    if(-not $s.PSObject.Properties['Exists']){Write-SOLog 'Backup de hibernação sem campo Exists; restauração ignorada.' 'WARN';return}
    if(-not [bool]$s.Exists){
        Write-SOLog 'Backup de hibernação não possui um valor original explícito; restauração automática ignorada para evitar adivinhação.' 'WARN'
        return
    }
    if(-not $s.PSObject.Properties['Enabled']){Write-SOLog 'Backup de hibernação sem campo Enabled; restauração ignorada.' 'WARN';return}
    if($script:DryRun){Write-SOLog 'Restauraria hibernação' 'PLAN';return}
    try{
        $enabled=([int]$s.Enabled -eq 1)
        $mode=if($enabled){'on'}else{'off'}
        if(-not(Invoke-SOPowerCfg -Arguments @('/hibernate',$mode) -Label 'restaurar hibernação' -Optional)){throw 'powercfg não restaurou a hibernação.'}
        Write-SOLog 'Hibernação restaurada' 'OK'
    }catch{Write-SOLog ("Falha restaurando hibernação: {0}" -f $_.Exception.Message) 'WARN'}
}

function Invoke-SOPowerCfgRaw {
    param([string[]]$Arguments)
    $oldEap=$ErrorActionPreference;$output=@();$code=-1
    try{
        $ErrorActionPreference='Continue'
        $output=@(& powercfg.exe @Arguments 2>&1)
        $code=$LASTEXITCODE
    }catch{
        $output=@($_.Exception.Message)
        if($null -ne $LASTEXITCODE){$code=$LASTEXITCODE}
    }finally{
        $ErrorActionPreference=$oldEap
    }
    return [pscustomobject]@{ExitCode=[int]$code;Output=[object[]]$output}
}
function Get-SOActivePowerGuid {
    $r=Invoke-SOPowerCfgRaw -Arguments @('/getactivescheme')
    if($r.ExitCode -ne 0){return $null}
    $txt=@($r.Output)-join "`n"
    if($txt -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'){return $matches[1]}
    return $null
}
function Get-SOActivePowerName {
    try{
        $r=Invoke-SOPowerCfgRaw -Arguments @('/getactivescheme')
        if($r.ExitCode -ne 0){return $null}
        $txt=@($r.Output)-join "`n"
        if($txt -match '\(([^\r\n]+)\)\s*$'){return $matches[1].Trim()}
    }catch{}
    return $null
}
function Invoke-SOPowerCfg {
    param([string[]]$Arguments,[string]$Label,[switch]$Optional)
    if($script:DryRun){Write-SOLog ("powercfg {0}" -f ($Arguments -join ' ')) 'PLAN';return $true}

    # $ErrorActionPreference='Stop' não pode transformar stderr nativo em falha
    # prematura. Invoke-SOPowerCfgRaw captura saída e ExitCode de forma uniforme.
    $r=Invoke-SOPowerCfgRaw -Arguments $Arguments
    if($r.ExitCode -eq 0){return $true}

    $detail=''
    foreach($line in @($r.Output)){
        $txt=([string]$line).Trim()
        if($txt){$detail=$txt;break}
    }
    $msg=("powercfg falhou em {0} (código {1})" -f $Label,$r.ExitCode)
    if($detail){$msg += (" :: {0}" -f $detail)}
    if($Optional){Write-SOLog $msg 'WARN';return $false}
    throw $msg
}

function Enable-SOGamingPower {
    if($script:DryRun){Write-SOLog 'Criaria/ativaria plano Super Optimizer Gaming (AC)' 'PLAN';return}
    $statePath=Join-Path (Get-SOSettingsDir) 'powerplan.json'
    $state=$null
    if(Test-Path -LiteralPath $statePath){
        $state=Get-SOSetting 'powerplan'
        if(-not $state -or -not $state.PSObject.Properties['Original'] -or [string]::IsNullOrWhiteSpace([string]$state.Original)){
            Write-SOLog 'Plano Gaming não foi alterado porque o backup de energia está inválido ou incompleto.' 'WARN';return
        }
    }else{
        $orig=Get-SOActivePowerGuid
        if(-not $orig){Write-SOLog 'Não foi possível identificar o plano de energia original; ajuste ignorado.' 'WARN';return}
        $state=[pscustomobject]@{Original=$orig;Gaming=$null}
        if(-not(Save-SOSetting 'powerplan' $state)){Write-SOLog 'Plano Gaming não foi alterado porque o estado original não pôde ser salvo.' 'WARN';return}
    }

    $orig=[string]$state.Original
    $gaming=if($state.PSObject.Properties['Gaming']){[string]$state.Gaming}else{$null}
    $listResult=Invoke-SOPowerCfgRaw -Arguments @('/list')
    $known=if($listResult.ExitCode -eq 0){@($listResult.Output)-join "`n"}else{''}
    if($gaming -and $known -and $known -notmatch [regex]::Escape($gaming)){$gaming=$null}

    if(-not $gaming){
        $base=Get-SOActivePowerGuid
        if(-not $base){Write-SOLog 'Não foi possível identificar o plano de energia atual para duplicação.' 'WARN';return $false}
        $dupResult=Invoke-SOPowerCfgRaw -Arguments @('/duplicatescheme',$base)
        $dup=@($dupResult.Output)-join "`n"
        if($dupResult.ExitCode -ne 0 -or $dup -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'){
            Write-SOLog 'Não foi possível duplicar o plano de energia atual.' 'WARN';return $false
        }
        $gaming=$matches[1]
        $newState=[ordered]@{Original=$orig;Gaming=$gaming}
        if(-not(Save-SOSetting 'powerplan' $newState)){
            [void](Invoke-SOPowerCfg -Arguments @('/delete',$gaming) -Label 'remover plano sem backup' -Optional)
            Write-SOLog 'Plano duplicado foi removido porque não foi possível salvar o estado para rollback.' 'WARN'
            return
        }
    }

    [void](Invoke-SOPowerCfg -Arguments @('/changename',$gaming,'Super Optimizer Gaming') -Label 'renomear plano' -Optional)

    # GUIDs oficiais em vez de aliases: SUB_USB/USBSELECTIVE não está disponível
    # de forma consistente em todas as instalações do Windows 11.
    $subProcessor='54533251-82be-4824-96c1-47b60b740d00'
    $procMax='bc5038f7-23e0-4960-96da-33abaf5935ec'
    $subUsb='2a737441-1930-4402-8d77-b2bebba308a3'
    $usbSelective='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    $subPci='501a4d13-42af-4429-9fd1-a8218c268e20'
    $aspm='ee12f906-d277-404b-b6da-e5fa1a576df5'

    [void](Invoke-SOPowerCfg -Arguments @('/setacvalueindex',$gaming,$subProcessor,$procMax,'100') -Label 'CPU máximo em AC' -Optional)
    [void](Invoke-SOPowerCfg -Arguments @('/setacvalueindex',$gaming,$subUsb,$usbSelective,'0') -Label 'USB selective suspend em AC' -Optional)
    [void](Invoke-SOPowerCfg -Arguments @('/setacvalueindex',$gaming,$subPci,$aspm,'0') -Label 'PCIe ASPM em AC' -Optional)
    $activated=Invoke-SOPowerCfg -Arguments @('/setactive',$gaming) -Label 'ativar plano' -Optional
    if($activated){
        $active=Get-SOActivePowerGuid
        if($active -and $active -ieq $gaming){Write-SOLog 'Plano Super Optimizer Gaming ativado e verificado' 'OK';return $true}
        Write-SOLog 'O powercfg retornou sucesso, mas o plano ativo não pôde ser confirmado. O perfil continuará sem tratar energia como fatal.' 'WARN'
        return $false
    }
    Write-SOLog 'Plano Gaming não pôde ser ativado; os demais ajustes do perfil continuarão e o estado salvo permanece disponível para rollback.' 'WARN'
    return $false
}

function Restore-SOPower {
    $path=Join-Path (Get-SOSettingsDir) 'powerplan.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    $state=Get-SOSetting 'powerplan'
    if(-not $state -or -not $state.PSObject.Properties['Original'] -or [string]::IsNullOrWhiteSpace([string]$state.Original)){
        Write-SOLog 'Backup do plano de energia inválido ou incompleto; restauração ignorada.' 'WARN';return
    }
    if($script:DryRun){Write-SOLog 'Restauraria plano de energia original' 'PLAN';return}

    $restored=$false
    try{
        $restored=Invoke-SOPowerCfg -Arguments @('/setactive',[string]$state.Original) -Label 'restaurar plano original' -Optional
        if($restored){
            $active=Get-SOActivePowerGuid
            if(-not $active -or $active -ine [string]$state.Original){$restored=$false;Write-SOLog 'Plano original não pôde ser confirmado como ativo.' 'WARN'}
        }
        if($state.PSObject.Properties['Gaming'] -and $state.Gaming -and $state.Gaming -ne $state.Original){
            if($restored){[void](Invoke-SOPowerCfg -Arguments @('/delete',[string]$state.Gaming) -Label 'remover plano Super Optimizer' -Optional)}
            else{Write-SOLog 'Plano Gaming preservado porque o plano original não pôde ser reativado.' 'WARN'}
        }
    }catch{Write-SOLog ("Falha restaurando plano de energia: {0}" -f $_.Exception.Message) 'WARN'}
}

function Backup-SODefender {
    $path=Join-Path (Get-SOSettingsDir) 'defender.json'
    if(Test-Path -LiteralPath $path){
        $s=Get-SOSetting 'defender'
        return ($null -ne $s -and $s.PSObject.Properties['ScanAvgCPULoadFactor'])
    }
    try{
        $m=Get-MpPreference -ErrorAction Stop
        return (Save-SOSetting 'defender' ([ordered]@{ScanAvgCPULoadFactor=$m.ScanAvgCPULoadFactor}))
    }catch{
        Write-SOLog ("Não foi possível salvar a preferência do Defender: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Set-SODefenderGaming {
    if($script:DryRun){Write-SOLog 'Defender: ScanAvgCPULoadFactor=20' 'PLAN';return}
    if(-not(Backup-SODefender)){Write-SOLog 'Defender não foi alterado porque o valor original não pôde ser salvo.' 'WARN';return}
    try{
        Set-MpPreference -ScanAvgCPULoadFactor 20 -ErrorAction Stop
        $m=Get-MpPreference -ErrorAction Stop
        if([int]$m.ScanAvgCPULoadFactor -ne 20){throw 'O valor de ScanAvgCPULoadFactor não confirmou 20.'}
        Write-SOLog 'Defender: limite médio de scan ajustado para 20% e verificado' 'OK'
    }catch{Write-SOLog ("Defender não aceitou ajuste de scan: {0}" -f $_.Exception.Message) 'WARN'}
}

function Restore-SODefender {
    $path=Join-Path (Get-SOSettingsDir) 'defender.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    $s=Get-SOSetting 'defender';if(-not $s){Write-SOLog 'Backup do Defender inválido; restauração ignorada.' 'WARN';return}
    if($script:DryRun){Write-SOLog 'Restauraria preferência do Defender' 'PLAN';return}
    try{
        Set-MpPreference -ScanAvgCPULoadFactor ([int]$s.ScanAvgCPULoadFactor) -ErrorAction Stop
        $m=Get-MpPreference -ErrorAction Stop
        if([int]$m.ScanAvgCPULoadFactor -ne [int]$s.ScanAvgCPULoadFactor){throw 'Valor restaurado não pôde ser confirmado.'}
        Write-SOLog 'Preferência do Defender restaurada e verificada' 'OK'
    }catch{Write-SOLog ("Falha restaurando Defender: {0}" -f $_.Exception.Message) 'WARN'}
}

function Get-SOHypervisorLaunchType {
    $oldEap=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        $output=& bcdedit.exe /enum '{current}' 2>&1
        $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$oldEap}
    if($code -ne 0){throw ("bcdedit /enum falhou com código {0}" -f $code)}
    $txt=($output|ForEach-Object {[string]$_}) -join "`n"
    if($txt -match '(?im)^\s*hypervisorlaunchtype\s+(\S+)'){return [string]$matches[1]}
    return 'DEFAULT'
}

function Backup-SOHypervisor {
    $path=Join-Path (Get-SOSettingsDir) 'hypervisor.json'
    if(Test-Path -LiteralPath $path){
        $s=Get-SOSetting 'hypervisor'
        return ($null -ne $s -and $s.PSObject.Properties['HypervisorLaunchType'] -and -not [string]::IsNullOrWhiteSpace([string]$s.HypervisorLaunchType))
    }
    try{
        $v=Get-SOHypervisorLaunchType
        return (Save-SOSetting 'hypervisor' ([ordered]@{HypervisorLaunchType=$v}))
    }catch{
        Write-SOLog ("Não foi possível salvar hypervisorlaunchtype: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Disable-SOHypervisor {
    if($script:DryRun){Write-SOLog 'BCD hypervisorlaunchtype off' 'PLAN';return}
    if(-not(Backup-SOHypervisor)){throw 'Hypervisor não foi alterado porque o estado original do BCD não pôde ser salvo.'}
    & bcdedit.exe /set hypervisorlaunchtype off | Out-Null
    if($LASTEXITCODE -ne 0){throw "bcdedit hypervisorlaunchtype off falhou com código $LASTEXITCODE"}
    try{
        $now=Get-SOHypervisorLaunchType
        if($now -ine 'Off'){throw ("Estado atual={0}" -f $now)}
        Write-SOLog 'Hypervisor do Windows configurado como OFF e verificado' 'OK'
    }catch{throw ("Não foi possível confirmar hypervisorlaunchtype=Off: {0}" -f $_.Exception.Message)}
}

function Restore-SOHypervisor {
    $path=Join-Path (Get-SOSettingsDir) 'hypervisor.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    $s=Get-SOSetting 'hypervisor';if(-not $s){Write-SOLog 'Backup do hypervisor inválido; restauração ignorada.' 'WARN';return}
    if($script:DryRun){Write-SOLog 'Restauraria hypervisorlaunchtype' 'PLAN';return}
    try{
        $wanted=[string]$s.HypervisorLaunchType
        if($wanted -eq 'DEFAULT'){
            & bcdedit.exe /deletevalue hypervisorlaunchtype 2>$null | Out-Null
            # /deletevalue pode retornar erro se o valor já não existir; a verificação abaixo é a fonte da verdade.
        } else {
            & bcdedit.exe /set hypervisorlaunchtype $wanted | Out-Null
            if($LASTEXITCODE -ne 0){throw "bcdedit retornou código $LASTEXITCODE"}
        }
        $now=Get-SOHypervisorLaunchType
        if($wanted -eq 'DEFAULT'){
            if($now -ne 'DEFAULT'){throw ("Esperado DEFAULT; atual={0}" -f $now)}
        }elseif($now -ine $wanted){throw ("Esperado {0}; atual={1}" -f $wanted,$now)}
        Write-SOLog 'hypervisorlaunchtype restaurado e verificado' 'OK'
    }catch{Write-SOLog ("Falha restaurando hypervisorlaunchtype: {0}" -f $_.Exception.Message) 'WARN'}
}

function New-SORestorePoint {
    param([string]$Description='Super Optimizer - Antes das alterações')
    if($script:DryRun){Write-SOLog "Criaria ponto de restauração: $Description" 'PLAN';return $true}
    try{Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop;Write-SOLog 'Ponto de restauração criado' 'OK';return $true}
    catch{Write-SOLog "Ponto de restauração indisponível: $($_.Exception.Message)" 'WARN';return $false}
}

function Set-SOGameMode {
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' DWord 1 'Gaming')
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' DWord 1 'Gaming')
}
function Set-SOGameDVROff {
    [void](Set-SORegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' DWord 0 'Gaming')
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' DWord 0 'Gaming')
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' DWord 0 'Gaming')
}
function Set-SOMMCSS {
    $g='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    [void](Set-SORegistryValue $g 'GPU Priority' DWord 8 'Gaming')
    [void](Set-SORegistryValue $g 'Priority' DWord 6 'Gaming')
    [void](Set-SORegistryValue $g 'Scheduling Category' String 'High' 'Gaming')
    [void](Set-SORegistryValue $g 'SFIO Priority' String 'High' 'Gaming')
}
function Set-SOForeground {
    [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' DWord 38 'Gaming')
}
function Set-SOMouseAccelOff {
    [void](Set-SORegistryValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' String '0' 'Gaming')
    [void](Set-SORegistryValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' String '0' 'Gaming')
    [void](Set-SORegistryValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' String '0' 'Gaming')
}
function Set-SOPowerThrottlingOff {
    param([string]$Category='Power')
    [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' DWord 1 $Category)
}
function Set-SOVisualsReduced {
    param([string]$Category='Privacy')
    # Curado e deliberadamente neutro ao tema: NÃO usa VisualFXSetting=2
    # ("Ajustar para melhor desempenho"), pois esse modo é amplo e pode provocar
    # alterações visuais fora do escopo desejado em algumas builds do Windows.
    # Também nunca escreve AppsUseLightTheme/SystemUsesLightTheme.
    [void](Set-SORegistryValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' String '0' $Category -Optional)
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' DWord 0 $Category -Optional)
}
function Set-SOBackgroundReduced {
    param([string]$Category='Privacy',[bool]$IncludeVisuals=$true,[bool]$PreserveOneDrive=$false)
    # Políticas de background variam entre builds/edições do Windows. No Studio,
    # cada módulo usa categoria própria para rollback independente e previsível.
    [void](Set-SORegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' DWord 1 $Category -Optional)
    if(-not $PreserveOneDrive){
        [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' DWord 1 $Category -Optional)
    }else{
        Write-SOLog 'OneDrive preservado pelo perfil personalizado; política DisableFileSyncNGSC não será aplicada.' 'INFO'
    }
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' DWord 1 $Category -Optional)
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' DWord 0 $Category -Optional)
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' DWord 0 $Category -Optional)
    if($IncludeVisuals){Set-SOVisualsReduced -Category $Category}
}
function Set-SOTelemetryReduced {
    param([string]$Category='Privacy')
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' DWord 0 $Category -Optional)
    foreach($t in (Get-SOConfig).telemetryTasks){Disable-SOTask $t.path $t.name}
    Set-SOServiceMode 'DiagTrack' Disabled 'Telemetria'
    Set-SOServiceMode 'WerSvc' Disabled 'Windows Error Reporting'
}
function Set-SOServicesProfile {
    param([string[]]$ExcludeNames=@())
    $all=@((Get-SOConfig).services)
    $items=@($all|Where-Object {$ExcludeNames -notcontains [string]$_.name})
    if($ExcludeNames.Count -gt 0){Write-SOLog ('Serviços preservados pelo perfil personalizado: '+(($ExcludeNames|Sort-Object -Unique) -join ', ')) 'INFO'}
    $i=0
    foreach($s in $items){$i++;Write-SOProgress (35+[int](30*$i/[Math]::Max(1,$items.Count))) "Serviço $i/$($items.Count): $($s.name)";Set-SOServiceMode $s.name $s.mode $s.label}
}
function Test-SOVBSBackupReady {
    $a=Backup-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 'VBS'
    $b=Backup-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 'VBS'
    $c=Backup-SOHypervisor
    return ($a -and $b -and $c)
}

function Set-SOVBSOff {
    if(-not $script:DryRun -and -not(Test-SOVBSBackupReady)){
        throw 'VBS/HVCI/Hypervisor não foram alterados porque o backup completo da camada de virtualização não pôde ser garantido.'
    }
    [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' DWord 0 'VBS')
    [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' DWord 0 'VBS')
    Disable-SOHypervisor
}

function Test-SORegistryBackupCategory {
    param([string]$Category)
    foreach($f in @(Get-ChildItem (Get-SORegDir) -Filter '*.json' -ErrorAction SilentlyContinue)){
        try{$b=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$b.Category -eq $Category){return $true}}catch{}
    }
    return $false
}

function Reset-SOToUniversalLayer {
    # Perfil Universal é um estado desejado, não apenas uma soma de tweaks.
    # Restaura camadas mais agressivas salvas pelo próprio Super Optimizer e
    # reaplica somente o núcleo Universal.
    $vbsTouched=(Test-SORegistryBackupCategory 'VBS') -or ($null -ne (Get-SOSetting 'hypervisor'))
    Restore-SORegistry 'Gaming'
    Restore-SORegistry 'Privacy'
    Restore-SOTasks
    Restore-SOServices
    Restore-SORegistry 'Power'
    Restore-SOHibernation
    Restore-SOPower
    Restore-SODefender
    Restore-SORegistry 'VBS'
    Restore-SOHypervisor
    return $vbsTouched
}

function Reset-SOExtremeLayerForAggressive {
    $vbsTouched=(Test-SORegistryBackupCategory 'VBS') -or ($null -ne (Get-SOSetting 'hypervisor'))
    Restore-SORegistry 'VBS'
    Restore-SOHypervisor
    return $vbsTouched
}

function Confirm-SOProfileResult {
    param([ValidateSet('UNIVERSAL','AGRESSIVO','EXTREMO')][string]$Expected)
    $detected=Get-SOProfileMatch
    if($detected -ne $Expected){Write-SOLog ("Perfil solicitado={0}, estado detectado após aplicação={1}. Consulte avisos/log." -f $Expected,$detected) 'WARN'}
    else{Write-SOLog ("Estado verificado após aplicação: {0}" -f $detected) 'OK'}
    return $detected
}

# V3.8.1: perfil Gamer + Navegador personalizável.
# O perfil parte do estado original salvo, aplica um núcleo gamer conservador e
# permite preservar recursos domésticos/produtivos sem criar um segundo sistema
# de rollback. Impressão é preservada por padrão, mas pode ser desativada explicitamente neste perfil; os demais recursos essenciais continuam fora dos alvos.
function Clear-SOGamerBrowserMarker {
    if($script:DryRun){return}
    $p=Join-Path (Get-SOSettingsDir) 'gamer_browser_profile.json'
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
}

function Get-SOGamerBrowserServiceExclusions {
    param($Options)
    $x=New-Object System.Collections.Generic.List[string]
    if([bool]$Options.PreserveSearch){[void]$x.Add('WSearch')}
    if([bool]$Options.PreserveRdp){foreach($n in @('TermService','SessionEnv','UmRdpService')){[void]$x.Add($n)}}
    if([bool]$Options.PreserveVpn){foreach($n in @('RasAuto','RasMan','RemoteAccess')){[void]$x.Add($n)}}
    if([bool]$Options.PreserveHotspot){foreach($n in @('icssvc','SharedAccess')){[void]$x.Add($n)}}
    if([bool]$Options.PreserveBiometrics){[void]$x.Add('WbioSrvc')}
    if([bool]$Options.PreserveNetworkDiscovery){foreach($n in @('FDResPub','fdPHost','SSDPSRV','upnphost')){[void]$x.Add($n)}}
    return [string[]]@($x|Sort-Object -Unique)
}

function Get-SOGamerBrowserVerification {
    param($Options=$null)
    $m=$Options
    if($null -eq $m){$m=Get-SOSetting 'gamer_browser_profile'}
    $reasons=@()
    if(-not $m){
        $reasons += 'marcador/configuração do perfil não encontrado no State'
        return [pscustomobject]@{Match=$false;Reasons=@($reasons);ServiceRatio=0;ServicesSeen=0;ServicesMatched=0}
    }

    try{
        $gm=Get-SORegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
        $fg=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation'
        $prio=Get-SORegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority'
        $gpu=Get-SORegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority'
        $dvr=Get-SORegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
        $pt=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
        $mouse=Get-SORegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed'
        $powerName=Get-SOActivePowerName

        if($gm -ne 1){$reasons += "Game Mode esperado=1 atual=$gm"}
        if($fg -ne 38){$reasons += "Win32PrioritySeparation esperado=38 atual=$fg"}
        if($prio -ne 6){$reasons += "Games/Priority esperado=6 atual=$prio"}
        if($gpu -ne 8){$reasons += "Games/GPU Priority esperado=8 atual=$gpu"}
        if($dvr -ne 0){$reasons += "GameDVR esperado=0 atual=$dvr"}
        if($pt -ne 1){$reasons += "PowerThrottlingOff esperado=1 atual=$pt"}
        if([string]$mouse -ne '0'){$reasons += "MouseSpeed esperado=0 atual=$mouse"}
        if($powerName -ne 'Super Optimizer Gaming'){$reasons += "Plano esperado='Super Optimizer Gaming' atual='$powerName'"}

        if($m.PSObject.Properties['PreserveOneDrive'] -and -not [bool]$m.PreserveOneDrive){
            $od=Get-SORegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC'
            if($od -ne 1){$reasons += "OneDrive deveria estar reduzido (DisableFileSyncNGSC=1); atual=$od"}
        }
        if($m.PSObject.Properties['PreserveHibernation'] -and -not [bool]$m.PreserveHibernation){
            $hib=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
            if($hib -ne 0){$reasons += "Hibernação deveria estar OFF; HibernateEnabled=$hib"}
        }
        if($m.PSObject.Properties['PreserveVirtualization'] -and -not [bool]$m.PreserveVirtualization){
            $vbs=Get-SOVBSState
            if($vbs -ne 'OFF / EXTREMO'){$reasons += "Virtualização deveria estar reduzida; estado VBS='$vbs'"}
        }
        if($m.PSObject.Properties['PreservePrinter'] -and -not [bool]$m.PreservePrinter){
            $sp=Get-SOServiceStart 'Spooler'
            if($sp -ne 4){$reasons += "Print Spooler deveria estar Disabled (Start=4); atual=$sp"}
        }

        $exclude=@(Get-SOGamerBrowserServiceExclusions $m)
        $seen=0;$matched=0
        foreach($svc in @((Get-SOConfig).services|Where-Object {$exclude -notcontains [string]$_.name})){
            $start=Get-SOServiceStart ([string]$svc.name)
            if($null -eq $start){continue}
            $seen++
            if(($svc.mode -eq 'Disabled' -and $start -eq 4)-or($svc.mode -eq 'Manual' -and $start -eq 3)){$matched++}
        }
        $ratio=if($seen -gt 0){$matched/[double]$seen}else{1}
        if($ratio -lt 0.70){$reasons += ("Serviços curados abaixo do limiar: {0}/{1} ({2:P0})" -f $matched,$seen,$ratio)}

        return [pscustomobject]@{
            Match=($reasons.Count -eq 0)
            Reasons=@($reasons)
            ServiceRatio=$ratio
            ServicesSeen=$seen
            ServicesMatched=$matched
        }
    }catch{
        $reasons += ('erro durante verificação: '+$_.Exception.Message)
        return [pscustomobject]@{Match=$false;Reasons=@($reasons);ServiceRatio=0;ServicesSeen=0;ServicesMatched=0}
    }
}

function Test-SOGamerBrowserMatch {
    param($Options=$null,[switch]$LogMismatch)
    $v=Get-SOGamerBrowserVerification -Options $Options
    if($LogMismatch -and -not [bool]$v.Match){
        foreach($reason in @($v.Reasons)){Write-SOLog ('Gamer + Navegador — verificação: '+[string]$reason) 'WARN'}
    }
    return [bool]$v.Match
}

function Invoke-SOGamerBrowserProfile {
    param($Options)
    Write-SOProgress 3 'Restaurando camadas anteriores para aplicar perfil personalizado com base limpa'
    $script:ProfileTransitionNeedsReboot=Reset-SOToUniversalLayer

    Write-SOProgress 12 'Aplicando núcleo gamer compatível'
    Invoke-SOUniversalCore
    Set-SOGameDVROff
    Set-SOMouseAccelOff

    Write-SOProgress 25 'Reduzindo background e telemetria conforme preferências'
    Set-SOBackgroundReduced -PreserveOneDrive ([bool]$Options.PreserveOneDrive)
    Set-SOTelemetryReduced

    Write-SOProgress 38 'Aplicando energia para jogos'
    Set-SOPowerThrottlingOff
    if(-not [bool]$Options.PreserveHibernation){[void](Disable-SOHibernation)}else{Write-SOLog 'Hibernação preservada pelo perfil Gamer + Navegador.' 'INFO'}
    [void](Enable-SOGamingPower)

    Write-SOProgress 50 'Aplicando serviços curados com exceções escolhidas'
    $exclude=@(Get-SOGamerBrowserServiceExclusions $Options)
    Set-SOServicesProfile -ExcludeNames $exclude

    if(-not [bool]$Options.PreservePrinter){
        Write-SOProgress 76 'Impressão não preservada: desativando Print Spooler'
        Set-SOServiceMode 'Spooler' Disabled 'Impressão / Print Spooler'
    }else{
        Write-SOLog 'Impressão preservada: Print Spooler permanece no estado original restaurado.' 'INFO'
    }

    Write-SOProgress 82 'Ajustando Defender sem desativá-lo'
    Set-SODefenderGaming

    if(-not [bool]$Options.PreserveVirtualization){
        Write-SOProgress 90 'Virtualização não preservada: desativando VBS / HVCI / hypervisor do Windows'
        Set-SOVBSOff
        $script:ProfileTransitionNeedsReboot=$true
    }else{
        Write-SOLog 'Virtualização preservada: VBS/HVCI/Hypervisor não serão desativados por este perfil.' 'INFO'
    }

    if(-not $script:DryRun){
        $marker=[ordered]@{
            PreserveSearch=[bool]$Options.PreserveSearch
            PreserveOneDrive=[bool]$Options.PreserveOneDrive
            PreserveRdp=[bool]$Options.PreserveRdp
            PreserveVpn=[bool]$Options.PreserveVpn
            PreserveHotspot=[bool]$Options.PreserveHotspot
            PreserveBiometrics=[bool]$Options.PreserveBiometrics
            PreserveNetworkDiscovery=[bool]$Options.PreserveNetworkDiscovery
            PreserveHibernation=[bool]$Options.PreserveHibernation
            PreserveVirtualization=[bool]$Options.PreserveVirtualization
            PreservePrinter=[bool]$Options.PreservePrinter
            AppliedAt=(Get-Date).ToString('o')
        }
        if(-not(Save-SOSetting 'gamer_browser_profile' $marker)){
            Write-SOLog 'O perfil foi aplicado, mas o marcador Gamer + Navegador não pôde ser salvo no State; a detecção futura pode aparecer como perfil base até o State voltar a ser gravável.' 'WARN'
        }
    }
    Write-SOProgress 100 'Perfil Gamer + Navegador concluído'
}

function Invoke-SOUniversalCore {
    Set-SOGameMode
    Set-SOMMCSS
    Set-SOForeground
}
function Invoke-SOAggressiveCore {
    Write-SOProgress 8 'Aplicando nucleo gaming conservador'
    Invoke-SOUniversalCore
    Write-SOProgress 18 'Desativando captura em segundo plano e aceleracao do mouse'
    Set-SOGameDVROff
    Set-SOMouseAccelOff
    Write-SOProgress 28 'Reduzindo tarefas de background e telemetria'
    Set-SOBackgroundReduced
    Set-SOTelemetryReduced
    Write-SOProgress 34 'Aplicando energia para jogos'
    Set-SOPowerThrottlingOff
    [void](Disable-SOHibernation)
    Enable-SOGamingPower
    Set-SOServicesProfile
    Write-SOProgress 82 'Ajustando Defender para menor impacto de scan'
    Set-SODefenderGaming
}
function Invoke-SOUniversalProfile {
    Clear-SOGamerBrowserMarker
    Write-SOProgress 5 'Restaurando camadas acima do Perfil Universal'
    $script:ProfileTransitionNeedsReboot=Reset-SOToUniversalLayer
    Write-SOProgress 25 'Ativando Game Mode'
    Set-SOGameMode
    Write-SOProgress 50 'Ajustando MMCSS Games'
    Set-SOMMCSS
    Write-SOProgress 75 'Ajustando prioridade de foreground'
    Set-SOForeground
    Write-SOProgress 100 'Perfil Universal concluído'
}
function Invoke-SOAggressiveProfile {
    Clear-SOGamerBrowserMarker
    Write-SOProgress 4 'Restaurando camada Extrema, se houver'
    [void](Reset-SOExtremeLayerForAggressive)
    Invoke-SOAggressiveCore
    Write-SOProgress 100 'Perfil Agressivo concluído'
}
function Invoke-SOExtremeProfile {
    Clear-SOGamerBrowserMarker
    Invoke-SOAggressiveCore
    Write-SOProgress 90 'Desativando VBS / HVCI / hypervisor do Windows'
    Set-SOVBSOff
    Write-SOProgress 100 'Perfil Extremo concluído - reinício necessário'
}

function Test-SOCleanupPathSafe {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    try{
        $candidate=[IO.Path]::GetFullPath($Path).TrimEnd('\')

        # A própria raiz de limpeza nunca pode ser junction/symlink.
        if(Test-Path -LiteralPath $candidate){
            $rootItem=Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if(($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $false}
        }

        $allowed=New-Object System.Collections.Generic.List[string]
        $userTemp=$null
        if(-not [string]::IsNullOrWhiteSpace($env:TEMP)){
            try{
                $userTemp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
                $leaf=[IO.Path]::GetFileName($userTemp)
                if($leaf -in @('Temp','TEMP','temp','Tmp','TMP','tmp')){[void]$allowed.Add($userTemp)}
            }catch{}
        }
        foreach($p in @(
            $(if($env:WINDIR){Join-Path $env:WINDIR 'Temp'}else{$null}),
            $(if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'D3DSCache'}else{$null}),
            $(if($env:WINDIR){Join-Path $env:WINDIR 'SoftwareDistribution\Download'}else{$null}),
            $(if($env:ProgramData){Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'}else{$null}),
            $(if($env:ProgramData){Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'}else{$null})
        )){
            if([string]::IsNullOrWhiteSpace([string]$p)){continue}
            try{[void]$allowed.Add([IO.Path]::GetFullPath([string]$p).TrimEnd('\'))}catch{}
        }

        $highRisk=New-Object System.Collections.Generic.List[string]
        foreach($p in @($env:USERPROFILE,$env:WINDIR,$env:LOCALAPPDATA,$env:APPDATA,$env:ProgramData,$env:ProgramFiles,${env:ProgramFiles(x86)},$script:AppRoot,$script:StateRoot)){
            if([string]::IsNullOrWhiteSpace([string]$p)){continue}
            try{[void]$highRisk.Add([IO.Path]::GetFullPath([string]$p).TrimEnd('\'))}catch{}
        }
        try{[void]$highRisk.Add([IO.Path]::GetPathRoot($candidate).TrimEnd('\'))}catch{}

        if($highRisk -contains $candidate){return $false}
        return ($allowed -contains $candidate)
    }catch{return $false}
}

function Remove-SOFolderChildrenSafe {
    param([string]$Path,[switch]$CollectStats,[switch]$LogIgnoredItems)
    $stats=[ordered]@{Path=$Path;Removed=0;Ignored=0;ReparsePoints=0}
    if([string]::IsNullOrWhiteSpace($Path)){if($CollectStats){return $stats}else{return}}
    if(-not(Test-SOCleanupPathSafe $Path)){throw ("Caminho de limpeza recusado pelo fail-safe: {0}" -f $Path)}
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){if($CollectStats){return $stats}else{return}}
    if($script:DryRun){Write-SOLog "Limparia conteúdo seguro de $Path" 'PLAN';if($CollectStats){return $stats}else{return}}
    foreach($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)){
        try{
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                $stats.ReparsePoints++
                if($LogIgnoredItems){Write-SOLog ("Reparse point ignorado por segurança: {0}" -f $item.FullName) 'INFO'}
                continue
            }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $stats.Removed++
        }catch{
            $stats.Ignored++
            if($LogIgnoredItems){Write-SOLog ("Item temporário ignorado: {0}" -f $item.FullName) 'INFO'}
        }
    }
    if($CollectStats){return $stats}
}
function Set-SOMaintenanceStamp([string]$Name){
    if($script:DryRun){return $true}
    $file=Get-SOMaintenanceFile;$state=[ordered]@{}
    if(Test-Path -LiteralPath $file){
        try{$o=Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;foreach($p in $o.PSObject.Properties){$state[$p.Name]=$p.Value}}
        catch{Write-SOLog ("Histórico de manutenção inválido; carimbo não foi sobrescrito: {0}" -f $_.Exception.Message) 'WARN';return $false}
    }
    $state[$Name]=(Get-Date).ToString('o')
    $tmp=$file+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{
        $state|ConvertTo-Json|Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        [void](Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop)
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
        return $true
    }catch{
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-SOLog ("Não foi possível atualizar o histórico de manutenção: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Clear-SOUserTemp {
    Write-SOProgress 20 'Limpando temporários do usuário'
    Remove-SOFolderChildrenSafe $env:TEMP
    [void](Set-SOMaintenanceStamp 'UserTemp')
    Write-SOProgress 100 'Temporários do usuário concluídos'
}
function Clear-SOWindowsTemp {
    Write-SOProgress 20 'Limpando Windows Temp (arquivos bloqueados são ignorados)'
    Remove-SOFolderChildrenSafe (Join-Path $env:WINDIR 'Temp')
    [void](Set-SOMaintenanceStamp 'WindowsTemp')
    Write-SOProgress 100 'Windows Temp concluído'
}
function Clear-SODirectXShaderCache {
    $path=Join-Path $env:LOCALAPPDATA 'D3DSCache'
    Write-SOProgress 20 'Limpando cache de shaders DirectX'
    Remove-SOFolderChildrenSafe $path
    [void](Set-SOMaintenanceStamp 'ShaderCache')
    Write-SOProgress 100 'Cache DirectX limpo. Jogos podem recompilar shaders no próximo início.'
}
function Invoke-SODiskScan {
    Write-SOProgress 5 ('CHKDSK /scan em '+$env:SystemDrive)
    $code=Invoke-SOExternal 'chkdsk.exe' @($env:SystemDrive,'/scan') 'CHKDSK Scan' 5 93
    # CHKDSK: 0 = sem erro; 1 pode indicar erro encontrado/corrigido. Outros códigos são falha operacional.
    if($code -eq 1){Write-SOLog 'CHKDSK encontrou/corrigiu inconsistência. Consulte o log; reinício pode ser recomendado pelo próprio Windows.' 'WARN'}
    elseif($code -ne 0){throw "CHKDSK /scan terminou com código $code. Consulte o log."}
    [void](Set-SOMaintenanceStamp 'DiskScan')
    Write-SOProgress 100 'Verificação online do disco concluída'
}

function Invoke-SOComponentAnalyze {
    Write-SOProgress 5 'Analisando Component Store (WinSxS)'
    $code=Invoke-SOExternal 'DISM.exe' @('/Online','/Cleanup-Image','/AnalyzeComponentStore') 'DISM AnalyzeComponentStore' 5 93
    if($code -ne 0){throw "AnalyzeComponentStore terminou com código $code. Consulte o log."}
    [void](Set-SOMaintenanceStamp 'ComponentAnalyze')
    Write-SOLog 'Análise do Component Store concluída' 'OK'; Write-SOProgress 100 'Análise do Component Store concluída' -NoLog
}

function Invoke-SOComponentCleanup {
    Write-SOProgress 5 'Limpando componentes substituídos do Windows'
    $code=Invoke-SOExternal 'DISM.exe' @('/Online','/Cleanup-Image','/StartComponentCleanup') 'DISM StartComponentCleanup' 5 93
    if($code -ne 0){throw "StartComponentCleanup terminou com código $code. Consulte o log."}
    [void](Set-SOMaintenanceStamp 'ComponentCleanup')
    Write-SOLog 'Limpeza do Component Store concluída' 'OK'; Write-SOProgress 100 'Limpeza do Component Store concluída' -NoLog
}

function Get-SOSystemDriveFreeGB {
    try{
        $name=([string]$env:SystemDrive).TrimEnd('\\').TrimEnd(':')
        $drive=Get-PSDrive -Name $name -ErrorAction Stop
        if($null -eq $drive.Free){return $null}
        return [math]::Round(([double]$drive.Free/1GB),2)
    }catch{return $null}
}

function Get-SOSystemDriveFreeBytes {
    try{
        $name=([string]$env:SystemDrive).TrimEnd('\\').TrimEnd(':')
        $drive=Get-PSDrive -Name $name -ErrorAction Stop
        if($null -eq $drive.Free){return $null}
        return [int64]$drive.Free
    }catch{return $null}
}
function Format-SOByteDelta {
    param([Nullable[Int64]]$Bytes)
    if($null -eq $Bytes){return 'não mensurável'}
    $v=[math]::Max(0,[double]$Bytes)
    if($v -ge 1GB){return ('{0:N2} GB' -f ($v/1GB))}
    if($v -ge 1MB){return ('{0:N1} MB' -f ($v/1MB))}
    if($v -ge 1KB){return ('{0:N1} KB' -f ($v/1KB))}
    return ('{0} bytes' -f [int64]$v)
}

function Invoke-SOFullPCCleanup {
    param([switch]$Nested)
    $beforeBytes=Get-SOSystemDriveFreeBytes
    Write-SOLog 'Limpeza completa segura iniciada: TEMP usuário + Windows Temp + DirectX Shader Cache + Windows Update Download Cache + Lixeira + DNS.' 'INFO'
    Write-SOLog 'Proteções mantidas: Downloads, Recent/Acesso Rápido, Prefetch, Event Logs, WinSxS, Windows.old e caches de navegador não são apagados.' 'INFO'

    if(-not $Nested){Write-SOProgress 5 'Limpando temporários do usuário'}
    $userStats=Remove-SOFolderChildrenSafe $env:TEMP -CollectStats
    Write-SOLog ("TEMP do usuário: {0} removido(s); {1} ignorado(s)/em uso." -f $userStats.Removed,$userStats.Ignored) 'OK'

    if(-not $Nested){Write-SOProgress 20 'Limpando Windows Temp'}
    $winStats=Remove-SOFolderChildrenSafe (Join-Path $env:WINDIR 'Temp') -CollectStats
    Write-SOLog ("Windows Temp: {0} removido(s); {1} ignorado(s)/em uso." -f $winStats.Removed,$winStats.Ignored) 'OK'

    if(-not $Nested){Write-SOProgress 35 'Limpando cache de shaders DirectX'}
    $shaderStats=Remove-SOFolderChildrenSafe (Join-Path $env:LOCALAPPDATA 'D3DSCache') -CollectStats
    Write-SOLog ("Shader DirectX: {0} removido(s); {1} ignorado(s)/em uso." -f $shaderStats.Removed,$shaderStats.Ignored) 'OK'

    if(-not $Nested){Write-SOProgress 50 'Limpando cache baixado do Windows Update'}
    [void](Clear-SOUpdateCache -SuppressProgress)

    if(-not $Nested){Write-SOProgress 78 'Esvaziando Lixeira'}
    $recycle='Ignorada'
    if($script:DryRun){
        Write-SOLog 'Clear-RecycleBin -Force' 'PLAN';$recycle='DRY-RUN'
    }else{
        $cmd=Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue
        if(-not $cmd){Write-SOLog 'Clear-RecycleBin não disponível; Lixeira foi ignorada.' 'WARN';$recycle='Indisponível'}
        else{
            try{Clear-RecycleBin -Force -ErrorAction Stop;Write-SOLog 'Lixeira esvaziada' 'OK';$recycle='Esvaziada'}
            catch{Write-SOLog ("Não foi possível esvaziar toda a Lixeira: {0}" -f $_.Exception.Message) 'WARN';$recycle='Parcial/erro'}
        }
    }

    if(-not $Nested){Write-SOProgress 90 'Limpando cache DNS'}
    $dns=Invoke-SOExternal 'ipconfig.exe' @('/flushdns') 'Flush DNS' 90 8
    if($dns -ne 0){Write-SOLog ("Limpeza completa: ipconfig /flushdns retornou código {0}" -f $dns) 'WARN'}

    [void](Set-SOMaintenanceStamp 'FullClean')
    [void](Set-SOMaintenanceStamp 'WeeklySafe')
    $afterBytes=Get-SOSystemDriveFreeBytes
    $freedBytes=$null
    if($null -ne $beforeBytes -and $null -ne $afterBytes){$freedBytes=[int64][math]::Max(0,([double]$afterBytes-[double]$beforeBytes))}
    $freedGB=if($null -ne $freedBytes){[math]::Round(([double]$freedBytes/1GB),3)}else{$null}
    if(-not $Nested){Write-SOProgress 100 'Limpeza completa segura concluída' -NoLog}
    $msg=if($script:DryRun){'DRY-RUN: limpeza completa segura planejada'}elseif($null -ne $freedBytes){("Limpeza completa concluída. Espaço liberado medido: {0}" -f (Format-SOByteDelta $freedBytes))}else{'Limpeza completa concluída'}
    Write-SOLog $msg 'OK'
    return [ordered]@{
        Executed=(-not $script:DryRun);DryRun=[bool]$script:DryRun;FreedApproxGB=$freedGB;FreedApproxBytes=$freedBytes
        UserTemp=[pscustomobject]$userStats;WindowsTemp=[pscustomobject]$winStats;ShaderCache=[pscustomobject]$shaderStats
        RecycleBin=$recycle;DnsExitCode=[int]$dns
        Included=@('TEMP do usuário','Windows Temp','DirectX Shader Cache','Windows Update Download Cache','Lixeira','DNS')
        Preserved=@('Downloads','Recent/Acesso Rápido','Prefetch','Event Logs','WinSxS','Windows.old','Caches de navegador');Message=$msg
    }
}
function Measure-SOSafeFolder {
    param([string]$Path,[int]$TimeoutSeconds=4,[int]$MaxItems=150000)
    $result=[ordered]@{Path=$Path;Bytes=[int64]0;ItemsScanned=0;Partial=$false;ElapsedMs=0;Reason=$null}
    if([string]::IsNullOrWhiteSpace($Path)){return $result}
    if(-not(Test-SOCleanupPathSafe $Path)){$result.Reason='Caminho recusado pelo fail-safe';return $result}
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){$result.Reason='Pasta ausente';return $result}

    $sw=[Diagnostics.Stopwatch]::StartNew()
    $stack=New-Object System.Collections.Generic.Stack[string]
    try{$stack.Push([IO.Path]::GetFullPath($Path))}catch{$result.Reason=$_.Exception.Message;return $result}
    while($stack.Count -gt 0){
        if($sw.Elapsed.TotalSeconds -ge [math]::Max(1,$TimeoutSeconds)){$result.Partial=$true;$result.Reason='Limite de tempo atingido';break}
        if($result.ItemsScanned -ge [math]::Max(1000,$MaxItems)){$result.Partial=$true;$result.Reason='Limite de itens atingido';break}
        $dir=$stack.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)){
            $result.ItemsScanned++
            if($sw.Elapsed.TotalSeconds -ge [math]::Max(1,$TimeoutSeconds) -or $result.ItemsScanned -ge [math]::Max(1000,$MaxItems)){$result.Partial=$true;$result.Reason='Limite de análise atingido';break}
            try{
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
                if($item.PSIsContainer){$stack.Push($item.FullName)}else{$result.Bytes += [int64]$item.Length}
            }catch{}
        }
        if($result.Partial){break}
    }
    $sw.Stop();$result.ElapsedMs=[math]::Round($sw.Elapsed.TotalMilliseconds,0)
    return $result
}

function Get-SOSafeFolderBytes {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return [int64]0}
    if(-not(Test-SOCleanupPathSafe $Path)){return [int64]0}
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){return [int64]0}
    [int64]$sum=0
    $stack=New-Object System.Collections.Generic.Stack[string]
    $stack.Push([IO.Path]::GetFullPath($Path))
    while($stack.Count -gt 0){
        $dir=$stack.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)){
            try{
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
                if($item.PSIsContainer){$stack.Push($item.FullName)}else{$sum += [int64]$item.Length}
            }catch{}
        }
    }
    return $sum
}

function Get-SOCleanupAnalysis {
    param([switch]$NoStamp,[int]$TimeoutSecondsPerArea=4)
    $items=@()
    $paths=@(
        [pscustomobject]@{Name='TEMP do usuário';Path=$env:TEMP},
        [pscustomobject]@{Name='Windows Temp';Path=(Join-Path $env:WINDIR 'Temp')},
        [pscustomobject]@{Name='Shader DirectX';Path=(Join-Path $env:LOCALAPPDATA 'D3DSCache')},
        [pscustomobject]@{Name='Cache Windows Update';Path=(Join-Path $env:WINDIR 'SoftwareDistribution\Download')},
        [pscustomobject]@{Name='WER - fila de relatórios';Path=(Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')},
        [pscustomobject]@{Name='WER - relatórios arquivados';Path=(Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')}
    )
    [int64]$total=0;$partialCount=0
    foreach($entry in $paths){
        $m=Measure-SOSafeFolder -Path ([string]$entry.Path) -TimeoutSeconds $TimeoutSecondsPerArea
        $bytes=[int64]$m.Bytes;$total += $bytes
        if([bool]$m.Partial){$partialCount++}
        $items += [pscustomobject]@{
            Area=[string]$entry.Name;SizeMB=[math]::Round(([double]$bytes/1MB),1);Path=[string]$entry.Path
            Partial=[bool]$m.Partial;ItemsScanned=[int]$m.ItemsScanned;ElapsedMs=[int]$m.ElapsedMs;Reason=[string]$m.Reason
        }
    }
    $driveTotal=0.0;$driveFree=0.0;$driveUsedPercent=0.0;$driveFreePercent=0.0
    try{
        $dev=[string]$env:SystemDrive
        $disk=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $dev) -OperationTimeoutSec 5 -ErrorAction Stop
        $driveTotal=[math]::Round(([double]$disk.Size/1GB),2);$driveFree=[math]::Round(([double]$disk.FreeSpace/1GB),2)
        if($driveTotal -gt 0){$driveFreePercent=[math]::Round(($driveFree/$driveTotal)*100,1);$driveUsedPercent=[math]::Round(100-$driveFreePercent,1)}
    }catch{}
    $note=if($partialCount -gt 0){("Estimativa parcial: {0} área(s) atingiram o limite de análise para não travar a interface. Os valores exibidos são mínimos encontrados até o limite." -f $partialCount)}else{'Estimativa das áreas seguras mensuráveis. Lixeira, Delivery Optimization e Component Store (WinSxS) não entram na soma porque usam APIs/estimativas diferentes.'}
    $analysis=[ordered]@{
        Drive=[string]$env:SystemDrive;DriveTotalGB=$driveTotal;DriveFreeGB=$driveFree;DriveFreePercent=$driveFreePercent;DriveUsedPercent=$driveUsedPercent
        TotalMB=[math]::Round(([double]$total/1MB),1);TotalGB=[math]::Round(([double]$total/1GB),2);Items=[object[]]$items
        PartialAreas=$partialCount;Note=$note;AnalyzedAt=(Get-Date).ToString('o')
    }
    if(-not $NoStamp){
        [void](Set-SOMaintenanceStamp 'CleanupAnalyze')
        if(-not $script:DryRun){[void](Save-SOSetting 'cleanup_analysis_last' $analysis)}
    }
    return $analysis
}

function Clear-SOWerReports {
    Write-SOProgress 10 'Limpando relatórios de erro antigos do Windows'
    foreach($p in @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
    )){
        if(Test-Path -LiteralPath $p){Remove-SOFolderChildrenSafe $p}
    }
    [void](Set-SOMaintenanceStamp 'WERCleanup')
    Write-SOProgress 100 'Relatórios WER limpos'
}

function Clear-SODeliveryOptimizationCache {
    Write-SOProgress 10 'Limpando cache de Otimização de Entrega'
    if($script:DryRun){Write-SOLog 'Delete-DeliveryOptimizationCache -Force' 'PLAN';return $true}
    $cmd=Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue
    if(-not $cmd){Write-SOLog 'Delete-DeliveryOptimizationCache não está disponível nesta edição/build; etapa ignorada.' 'WARN';return $false}
    try{
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Write-SOLog 'Cache de Otimização de Entrega limpo' 'OK'
        return $true
    }catch{Write-SOLog ("Falha limpando Delivery Optimization: {0}" -f $_.Exception.Message) 'WARN';return $false}
}

function Invoke-SODeepPCCleanup {
    $before=Get-SOSystemDriveFreeGB
    Write-SOLog 'LIMPEZA FINAL/PROFUNDA iniciada. Inclui a Limpeza Completa + Delivery Optimization + WER + Component Store; Standby RAM só é limpa se o uso estiver alto.' 'WARN'
    Write-SOLog 'Proteções absolutas: Downloads, documentos pessoais, Recent/Acesso Rápido, Prefetch, Event Logs, Windows.old e perfis/caches de navegadores não são apagados.' 'INFO'

    Write-SOProgress 3 'Executando base da Limpeza Completa'
    [void](Invoke-SOFullPCCleanup -Nested)

    Write-SOProgress 63 'Limpando Otimização de Entrega'
    [void](Clear-SODeliveryOptimizationCache)

    Write-SOProgress 70 'Limpando relatórios WER arquivados/fila'
    [void](Clear-SOWerReports)

    Write-SOProgress 78 'Limpando Component Store substituído (WinSxS)'
    try{[void](Invoke-SOComponentCleanup)}catch{Write-SOLog ("Component Store não pôde ser limpo: {0}" -f $_.Exception.Message) 'WARN'}

    Write-SOProgress 92 'Avaliando pressão de RAM'
    try{
        $ram=Get-SORamInfo
        if([double]$ram.UsedPercent -ge 85){
            Write-SOLog ("RAM em {0}%; a Limpeza Final fará somente Standby RAM, não a limpeza agressiva de working sets." -f $ram.UsedPercent) 'INFO'
            [void](Invoke-SORamStandbyClean -Force $true)
        }else{Write-SOLog ("RAM em {0}%; limpeza de RAM ignorada por não ser necessária." -f $ram.UsedPercent) 'INFO'}
    }catch{Write-SOLog ("Não foi possível avaliar RAM durante a Limpeza Final: {0}" -f $_.Exception.Message) 'WARN'}

    [void](Set-SOMaintenanceStamp 'DeepClean')
    [void](Set-SOMaintenanceStamp 'FullClean')
    [void](Set-SOMaintenanceStamp 'WeeklySafe')
    $after=Get-SOSystemDriveFreeGB
    $freed=$null
    if($null -ne $before -and $null -ne $after){$freed=[math]::Max(0,[math]::Round(([double]$after-[double]$before),2))}
    Write-SOProgress 100 'Limpeza Final concluída'
    $msg=if($script:DryRun){'DRY-RUN: Limpeza Final planejada'}elseif($null -ne $freed){("Limpeza Final concluída. Espaço liberado estimado: {0} GB" -f $freed)}else{'Limpeza Final concluída'}
    return [ordered]@{
        Executed=(-not $script:DryRun);FreedApproxGB=$freed;Message=$msg
        Included=@('Limpeza Completa','Delivery Optimization','WER ReportQueue/Archive','DISM StartComponentCleanup','Standby RAM apenas se >=85%')
        Preserved=@('Downloads','Documentos pessoais','Recent/Acesso Rápido','Prefetch','Event Logs','Windows.old','Caches/perfis de navegador')
    }
}

function Get-SOWingetPath {
    try{
        $cmd=Get-Command winget.exe -ErrorAction Stop
        if($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)){return [string]$cmd.Source}
    }catch{}
    try{
        $alias=Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if(Test-Path -LiteralPath $alias -PathType Leaf){return $alias}
    }catch{}
    try{
        $pkg=Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if($pkg -and $pkg.InstallLocation){
            $candidate=Join-Path ([string]$pkg.InstallLocation) 'winget.exe'
            if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
        }
    }catch{}
    return $null
}

function Test-SOWingetAvailable { return (-not [string]::IsNullOrWhiteSpace((Get-SOWingetPath))) }

function Read-SOTextFileSmart {
    param([string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
    try{
        $bytes=[IO.File]::ReadAllBytes($Path)
        if($bytes.Length -eq 0){return ''}
        $text=$null
        if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){
            $text=[Text.Encoding]::UTF8.GetString($bytes,3,$bytes.Length-3)
        }elseif($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE){
            $text=[Text.Encoding]::Unicode.GetString($bytes,2,$bytes.Length-2)
        }elseif($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF){
            $text=[Text.Encoding]::BigEndianUnicode.GetString($bytes,2,$bytes.Length-2)
        }else{
            $nul=0;foreach($b in $bytes){if($b -eq 0){$nul++}}
            if($bytes.Length -gt 8 -and ($nul/[double]$bytes.Length) -gt 0.15){
                $text=[Text.Encoding]::Unicode.GetString($bytes)
            }else{
                try{$utf8=New-Object System.Text.UTF8Encoding($false,$true);$text=$utf8.GetString($bytes)}
                catch{$text=[Text.Encoding]::Default.GetString($bytes)}
            }
        }
        if($null -eq $text){return ''}
        # Remove ANSI/VT sequences and NULs that can leak from console tools.
        $text=$text -replace "`0",''
        $text=[regex]::Replace($text,"`e\[[0-?]*[ -/]*[@-~]",'')
        return $text
    }catch{return ''}
}

function Invoke-SOWingetProcess {
    param([string[]]$Arguments,[int]$TimeoutSeconds=900)
    $exe=Get-SOWingetPath
    if(-not $exe){throw 'WinGet (winget.exe) não foi encontrado. Ele normalmente é fornecido pelo App Installer da Microsoft Store.'}
    if($script:DryRun){Write-SOLog ("winget {0}" -f ($Arguments -join ' ')) 'PLAN';return [ordered]@{ExitCode=0;Output='DRY-RUN';TimedOut=$false}}
    $tmpOut=Join-Path $script:RuntimeRoot ('winget_'+[guid]::NewGuid().ToString('N')+'.out.txt');$tmpErr=Join-Path $script:RuntimeRoot ('winget_'+[guid]::NewGuid().ToString('N')+'.err.txt')
    try{
        $p=Start-Process -FilePath $exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};throw ("WinGet excedeu o timeout de {0} segundos e foi interrompido." -f $TimeoutSeconds)}
        try{$p.WaitForExit()}catch{};try{$p.Refresh()}catch{}
        $exitCode=$null;try{$exitCode=[int]$p.ExitCode}catch{}
        if($null -eq $exitCode){Write-SOLog 'WinGet terminou, mas o ExitCode não pôde ser lido; tratando como aviso.' 'WARN';$exitCode=-1}
        $out=Read-SOTextFileSmart $tmpOut;$err=Read-SOTextFileSmart $tmpErr
        $combined=($out+$(if($err){"`r`n"+$err}else{''})).Trim()
        Write-SOLog ("WinGet exit={0}`r`n{1}" -f $exitCode,$combined) $(if($exitCode -eq 0){'OK'}else{'WARN'})
        return [ordered]@{ExitCode=$exitCode;Output=$combined;TimedOut=$false}
    }finally{Remove-Item -LiteralPath $tmpOut,$tmpErr -Force -ErrorAction SilentlyContinue}
}


function Invoke-SOWingetScan {
    param([bool]$IncludeUnknown=$false)
    Write-SOProgress 10 'Consultando atualizações pelo WinGet'
    $args=@('upgrade','--accept-source-agreements','--disable-interactivity');if($IncludeUnknown){$args += '--include-unknown'}
    $r=Invoke-SOWingetProcess -Arguments $args -TimeoutSeconds 180
    if([int]$r.ExitCode -eq 0){[void](Set-SOMaintenanceStamp 'WingetScan')}
    else{Write-SOLog 'A data de verificação de apps não foi atualizada porque o WinGet terminou com erro/aviso.' 'WARN'}
    Write-SOProgress 100 'Consulta WinGet concluída'
    return [ordered]@{Available=$true;ExitCode=$r.ExitCode;Output=$r.Output;IncludeUnknown=$IncludeUnknown;Executable=(Get-SOWingetPath);Note='O WinGet só lista/atualiza aplicativos reconhecidos por suas fontes. Alguns programas continuam usando atualizadores próprios.'}
}

function Invoke-SOWingetUpgradeAll {
    param([bool]$IncludeUnknown=$false)
    Write-SOProgress 5 'Atualizando aplicativos reconhecidos pelo WinGet'
    $args=@('upgrade','--all','--accept-source-agreements','--accept-package-agreements','--disable-interactivity');if($IncludeUnknown){$args += '--include-unknown'}
    $r=Invoke-SOWingetProcess -Arguments $args -TimeoutSeconds 3600
    if([int]$r.ExitCode -eq 0){[void](Set-SOMaintenanceStamp 'WingetUpgrade');[void](Set-SOMaintenanceStamp 'WingetScan')}
    else{Write-SOLog 'Histórico WinGet não foi marcado como concluído porque o processo retornou código diferente de zero.' 'WARN'}
    Write-SOProgress 100 'Atualização de aplicativos concluída'
    return [ordered]@{ExitCode=$r.ExitCode;Output=$r.Output;IncludeUnknown=$IncludeUnknown;Executable=(Get-SOWingetPath);Note='Pacotes fixados ou não gerenciados pelo WinGet podem permanecer sem atualização. --include-unknown só é usado quando você marca essa opção.'}
}

function Set-SODnsReviewStamp {
    [void](Set-SOMaintenanceStamp 'DnsReview')
    return [ordered]@{Recorded=$true;At=(Get-Date).ToString('o')}
}

function Test-SORebootPending {
    try{
        if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){return $true}
        if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){return $true}
        $v=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if($null -ne $v){return $true}
    }catch{}
    return $false
}

function Invoke-SOWeeklyMaintenance {
    $beforeBytes=Get-SOSystemDriveFreeBytes
    Write-SOProgress 10 'Limpando temporários do usuário'
    $userStats=Remove-SOFolderChildrenSafe $env:TEMP -CollectStats
    Write-SOLog ("TEMP do usuário: {0} item(ns) removido(s); {1} ignorado(s)/em uso." -f $userStats.Removed,$userStats.Ignored) 'OK'
    Write-SOProgress 45 'Limpando Windows Temp'
    $winStats=Remove-SOFolderChildrenSafe (Join-Path $env:WINDIR 'Temp') -CollectStats
    Write-SOLog ("Windows Temp: {0} item(ns) removido(s); {1} ignorado(s)/em uso." -f $winStats.Removed,$winStats.Ignored) 'OK'
    Write-SOProgress 75 'Limpando cache DNS'
    $dns=Invoke-SOExternal 'ipconfig.exe' @('/flushdns') 'Flush DNS' 75 20
    if($dns -ne 0){Write-SOLog ("Manutenção semanal: ipconfig /flushdns retornou código {0}" -f $dns) 'WARN'}
    [void](Set-SOMaintenanceStamp 'WeeklySafe')
    $afterBytes=Get-SOSystemDriveFreeBytes
    $freedBytes=$null
    if($null -ne $beforeBytes -and $null -ne $afterBytes){$freedBytes=[int64][math]::Max(0,([double]$afterBytes-[double]$beforeBytes))}
    $freedGB=if($null -ne $freedBytes){[math]::Round(([double]$freedBytes/1GB),3)}else{$null}
    $msg='Manutenção Semanal concluída'
    if($null -ne $freedBytes -and $freedBytes -gt 0){$msg += (' • '+(Format-SOByteDelta $freedBytes)+' liberado(s)')}
    Write-SOLog ($msg+'. Acesso Rápido, Prefetch, Event Logs e Lixeira preservados.') 'OK'
    Write-SOProgress 100 $msg -NoLog
    return [ordered]@{UserTempRemoved=[int]$userStats.Removed;UserTempIgnored=[int]$userStats.Ignored;WindowsTempRemoved=[int]$winStats.Removed;WindowsTempIgnored=[int]$winStats.Ignored;DnsExitCode=[int]$dns;FreedApproxGB=$freedGB;FreedApproxBytes=$freedBytes;Preserved=@('Acesso Rápido','Prefetch','Event Logs','Lixeira');Message=$msg}
}
function Clear-SORecycleBin {
    Write-SOProgress 20 'Esvaziando Lixeira'
    if($script:DryRun){Write-SOLog 'Clear-RecycleBin -Force' 'PLAN';Write-SOProgress 100 'Lixeira esvaziada';return}
    $cmd=Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue
    if(-not $cmd){throw 'Clear-RecycleBin não está disponível nesta instalação do PowerShell.'}
    try{Clear-RecycleBin -Force -ErrorAction Stop;Write-SOLog 'Lixeira esvaziada' 'OK'}
    catch{Write-SOLog ("Não foi possível esvaziar toda a Lixeira: {0}" -f $_.Exception.Message) 'WARN'}
    Write-SOProgress 100 'Operação da Lixeira concluída' -NoLog
}
function Read-SOUpdateSessionSnapshot {
    $file=Get-SOUpdateSessionFile
    if(-not(Test-Path -LiteralPath $file)){return $null}
    try{
        $items=@(Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        if($items.Count -eq 0){throw 'Snapshot vazio.'}
        $seen=New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        foreach($item in $items){
            if(-not $item.PSObject.Properties['Name'] -or -not $item.PSObject.Properties['WasRunning']){throw 'Entrada sem Name/WasRunning.'}
            $name=[string]$item.Name
            if($name -notin @('wuauserv','BITS','DoSvc')){throw ('Serviço inesperado no snapshot: '+$name)}
            if(-not $seen.Add($name)){throw ('Serviço duplicado no snapshot: '+$name)}
        }
        return $items
    }catch{
        Write-SOLog ("Snapshot do Windows Update inválido: {0}" -f $_.Exception.Message) 'WARN'
        return $null
    }
}

function Stop-SOUpdateSession {
    $names=@('wuauserv','BITS','DoSvc')
    if($script:DryRun){
        Write-SOLog 'Salvaria o estado de wuauserv/BITS/DoSvc e pararia os serviços nesta sessão' 'PLAN'
        return [ordered]@{Success=$true;Message='DRY-RUN: pausa temporária do Windows Update planejada';Snapshot='DRY-RUN'}
    }

    $snapshot=Get-SOUpdateSessionFile
    $items=$null
    if(Test-Path -LiteralPath $snapshot){
        $items=Read-SOUpdateSessionSnapshot
        if($null -eq $items){
            $msg='Existe um snapshot inválido da sessão do Windows Update. Nada foi alterado para não perder o estado original.'
            Write-SOLog $msg 'WARN'
            return [ordered]@{Success=$false;Message=$msg;Snapshot=$snapshot}
        }
        Write-SOLog 'Windows Update já possui snapshot de sessão; o estado original será preservado.' 'INFO'
    }else{
        $list=New-Object System.Collections.Generic.List[object]
        foreach($n in $names){
            $svc=Get-Service $n -ErrorAction SilentlyContinue
            if($svc){[void]$list.Add([pscustomobject]@{Name=$n;WasRunning=($svc.Status -eq 'Running')})}
        }
        if($list.Count -eq 0){
            $msg='Nenhum serviço principal do Windows Update foi encontrado.'
            Write-SOLog $msg 'WARN'
            return [ordered]@{Success=$false;Message=$msg;Snapshot=$null}
        }
        $tmp=$snapshot+'.tmp.'+[guid]::NewGuid().ToString('N')
        try{
            $list | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
            [void](Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop)
            Move-Item -LiteralPath $tmp -Destination $snapshot -Force -ErrorAction Stop
            $items=Read-SOUpdateSessionSnapshot
            if($null -eq $items){throw 'Snapshot gravado não passou na validação.'}
        }catch{
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue
            throw ("Falha criando snapshot seguro do Windows Update: {0}" -f $_.Exception.Message)
        }
    }

    $failed=0
    foreach($item in @($items)){
        $name=[string]$item.Name
        try{
            Stop-Service $name -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 150
            $sv=Get-Service $name -ErrorAction SilentlyContinue
            if($sv -and $sv.Status -eq 'Running'){throw 'serviço continuou Running'}
            Write-SOLog ("Update sessão: {0} parado" -f $name) 'OK'
        }catch{
            $failed++
            Write-SOLog ("Não foi possível parar {0}: {1}" -f $name,$_.Exception.Message) 'WARN'
        }
    }

    if($failed -gt 0){
        Write-SOLog 'Pausa do Windows Update ficou parcial; tentando desfazer automaticamente para voltar ao estado anterior.' 'WARN'
        $rollback=Restore-SOUpdateSession
        if([bool]$rollback.Success){
            return [ordered]@{Success=$false;Message=("Pausa cancelada: {0} serviço(s) não puderam ser parados e o estado anterior foi restaurado automaticamente." -f $failed);Snapshot=$snapshot;Failures=$failed;RolledBack=$true}
        }
        return [ordered]@{Success=$false;Message=("Pausa parcial: {0} serviço(s) não puderam ser parados e a restauração automática também ficou parcial. Use Reativar Update; snapshot preservado." -f $failed);Snapshot=$snapshot;Failures=$failed;RolledBack=$false}
    }
    return [ordered]@{Success=$true;Message='Serviços principais do Windows Update foram parados nesta sessão. O Windows ainda pode reativá-los por Trigger Start.';Snapshot=$snapshot;Failures=0;RolledBack=$false}
}

function Restore-SOUpdateSession {
    $file=Get-SOUpdateSessionFile
    if($script:DryRun){
        Write-SOLog 'Restauraria o estado anterior dos serviços de Windows Update' 'PLAN'
        return [ordered]@{Success=$true;Message='DRY-RUN: restauração da sessão do Windows Update planejada';HadSnapshot=(Test-Path -LiteralPath $file)}
    }

    if(Test-Path -LiteralPath $file){
        $items=Read-SOUpdateSessionSnapshot
        if($null -eq $items){
            $msg='Snapshot do Windows Update inválido; nada foi alterado.'
            Write-SOLog $msg 'WARN'
            return [ordered]@{Success=$false;Message=$msg;HadSnapshot=$true}
        }

        $failed=0
        foreach($item in @($items)){
            $name=[string]$item.Name
            if([bool]$item.WasRunning){
                try{
                    Start-Service $name -ErrorAction Stop
                    $sv=Get-Service $name -ErrorAction SilentlyContinue
                    if(-not $sv -or $sv.Status -ne 'Running'){throw 'serviço não confirmou estado Running'}
                    Write-SOLog ("Update sessão: {0} restaurado para Running" -f $name) 'OK'
                }catch{$failed++;Write-SOLog ("Não foi possível reativar {0}: {1}" -f $name,$_.Exception.Message) 'WARN'}
            }else{
                try{
                    Stop-Service $name -Force -ErrorAction SilentlyContinue
                    $sv=Get-Service $name -ErrorAction SilentlyContinue
                    if($sv -and $sv.Status -eq 'Running'){throw 'serviço continuou Running'}
                    Write-SOLog ("Update sessão: {0} restaurado para Stopped" -f $name) 'OK'
                }catch{$failed++;Write-SOLog ("Falha restaurando {0} para Stopped: {1}" -f $name,$_.Exception.Message) 'WARN'}
            }
        }

        if($failed -eq 0){
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            return [ordered]@{Success=$true;Message='Estado anterior dos serviços do Windows Update restaurado.';HadSnapshot=$true;Failures=0}
        }
        Write-SOLog 'Snapshot do Windows Update preservado para permitir nova tentativa de restauração.' 'WARN'
        return [ordered]@{Success=$false;Message=("Restauração parcial do Windows Update: {0} falha(s). Snapshot preservado." -f $failed);HadSnapshot=$true;Failures=$failed}
    }

    $failed=0;$attempted=0
    foreach($n in @('BITS','DoSvc','wuauserv')){
        $svc=Get-Service $n -ErrorAction SilentlyContinue
        if(-not $svc){continue}
        $attempted++
        try{Start-Service $n -ErrorAction Stop;Write-SOLog ("Update: solicitação de início enviada para {0}" -f $n) 'OK'}
        catch{$failed++;Write-SOLog ("Update: {0} não iniciou agora (pode usar Trigger Start): {1}" -f $n,$_.Exception.Message) 'WARN'}
    }
    if($attempted -eq 0){return [ordered]@{Success=$false;Message='Nenhum serviço principal do Windows Update foi encontrado.';HadSnapshot=$false;Failures=0}}
    if($failed -ge $attempted){return [ordered]@{Success=$false;Message='Não foi possível solicitar o início de nenhum serviço principal do Windows Update. Consulte o log.';HadSnapshot=$false;Failures=$failed}}
    return [ordered]@{Success=$true;Message=$(if($failed -eq 0){'Serviços principais do Windows Update receberam solicitação de início.'}else{"Solicitação de reativação concluída parcialmente, com $failed aviso(s); consulte o log."});HadSnapshot=$false;Failures=$failed}
}

function Get-SOUpdatePauseState {
    $file=Get-SOUpdateSessionFile
    if(-not(Test-Path -LiteralPath $file)){return 'NÃO'}
    if($null -eq (Read-SOUpdateSessionSnapshot)){return 'SNAPSHOT INVÁLIDO'}
    $names=@('wuauserv','BITS','DoSvc')
    $running=0;$seen=0
    foreach($n in $names){
        $svc=Get-Service $n -ErrorAction SilentlyContinue
        if($svc){$seen++;if($svc.Status -eq 'Running'){$running++}}
    }
    if($seen -gt 0 -and $running -eq 0){return 'SIM'}
    return 'PARCIAL'
}

function Clear-SOUpdateCache {
    param([switch]$SuppressProgress)
    $names=@('wuauserv','BITS','DoSvc')
    $running=@{}
    foreach($n in $names){
        $svc=Get-Service $n -ErrorAction SilentlyContinue
        if($svc){$running[$n]=($svc.Status -eq 'Running')}
    }

    try{
        if(-not $SuppressProgress){Write-SOProgress 15 'Parando temporariamente serviços de Update'}
        if(-not $script:DryRun){
            $stopFailed=New-Object System.Collections.Generic.List[string]
            foreach($n in $names){
                if(-not $running.ContainsKey($n)){continue}
                try{
                    Stop-Service $n -Force -ErrorAction Stop
                    Start-Sleep -Milliseconds 120
                    $sv=Get-Service $n -ErrorAction SilentlyContinue
                    if($sv -and $sv.Status -eq 'Running'){throw 'serviço continuou Running'}
                }catch{
                    [void]$stopFailed.Add($n)
                    Write-SOLog ("Cache Update: não foi possível parar {0}: {1}" -f $n,$_.Exception.Message) 'WARN'
                }
            }
            if($stopFailed.Count -gt 0){
                throw ("Cache do Windows Update não foi limpo porque estes serviços não puderam ser parados com segurança: {0}" -f ($stopFailed -join ', '))
            }
        }else{Write-SOLog 'Pararia wuauserv/BITS/DoSvc e verificaria o estado antes de apagar o cache' 'PLAN'}

        if(-not $SuppressProgress){Write-SOProgress 50 'Limpando SoftwareDistribution\\Download'}
        Remove-SOFolderChildrenSafe (Join-Path $env:WINDIR 'SoftwareDistribution\Download')
    } finally {
        if(-not $SuppressProgress){Write-SOProgress 80 'Restaurando o estado anterior dos serviços de Update'}
        if(-not $script:DryRun){
            foreach($n in $names){
                if(-not $running.ContainsKey($n)){continue}
                if([bool]$running[$n]){
                    try{
                        Start-Service $n -ErrorAction Stop
                        $sv=Get-Service $n -ErrorAction SilentlyContinue
                        if(-not $sv -or $sv.Status -ne 'Running'){throw 'serviço não confirmou Running'}
                    }catch{Write-SOLog ("Cache Update: não foi possível reativar {0}: {1}" -f $n,$_.Exception.Message) 'WARN'}
                }else{
                    try{Stop-Service $n -Force -ErrorAction SilentlyContinue}catch{}
                    $sv=Get-Service $n -ErrorAction SilentlyContinue
                    if($sv -and $sv.Status -eq 'Running'){Write-SOLog ("Cache Update: {0} deveria voltar a Stopped, mas está Running" -f $n) 'WARN'}
                }
            }
        }
    }
    [void](Set-SOMaintenanceStamp 'UpdateCache')
    if(-not $SuppressProgress){Write-SOProgress 100 'Cache do Windows Update concluído'}
}

function Invoke-SOExternal {
    param([string]$Exe,[string[]]$Arguments,[string]$Name,[int]$BasePercent=0,[int]$SpanPercent=100)
    if($script:DryRun){Write-SOLog ("Executaria: {0} {1}" -f $Exe,($Arguments -join ' ')) 'PLAN';return 0}
    if(-not(Get-Command $Exe -ErrorAction SilentlyContinue)){throw ("Executável não encontrado: {0}" -f $Exe)}
    Write-SOLog "Iniciando $Name" 'INFO'
    $global:LASTEXITCODE=0
    $code=-1
    $oldEap=$ErrorActionPreference
    $lastUiPercent=-1
    $lastLoggedMilestone=0
    try{
        $ErrorActionPreference='Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $line=[string]$_
            $hasProgress=$false
            if($line -match '(\d{1,3}(?:[\.,]\d+)?)\s*%'){
                $n=$matches[1] -replace ',','.'
                $v=0.0
                if([double]::TryParse($n,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$v)){
                    $hasProgress=$true
                    $p=$BasePercent+[int](($v/100.0)*$SpanPercent)
                    if($p -gt ($BasePercent+$SpanPercent)){$p=$BasePercent+$SpanPercent}
                    if($p -ne $lastUiPercent){Write-SOProgress $p "$Name - $($matches[1])%" -NoLog;$lastUiPercent=$p}
                    $milestone=[int]([math]::Floor($v/10.0)*10)
                    if($v -ge 100){$milestone=100}
                    if($milestone -ge 10 -and $milestone -gt $lastLoggedMilestone){
                        Write-SOLog ("{0} - {1}%" -f $Name,$milestone) 'INFO'
                        $lastLoggedMilestone=$milestone
                    }
                }
            }
            # Barras ASCII de progresso do DISM/SFC não precisam aparecer duas vezes.
            # Linhas textuais reais (resultado, avisos, versões etc.) continuam no log.
            if($line.Trim() -and -not ($hasProgress -and $line.Trim() -match '^\[.*%.*\]$')){Write-SOLog $line 'INFO'}
        }
        $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$oldEap}
    Write-SOLog "$Name terminou com código $code" $(if($code -eq 0){'OK'}else{'WARN'})
    return $code
}
function Invoke-SOHealthScan {
    Write-SOProgress 5 'DISM CheckHealth'
    $a=Invoke-SOExternal 'DISM.exe' @('/Online','/Cleanup-Image','/CheckHealth') 'DISM CheckHealth' 5 10
    Write-SOProgress 18 'DISM ScanHealth (pode demorar)'
    $b=Invoke-SOExternal 'DISM.exe' @('/Online','/Cleanup-Image','/ScanHealth') 'DISM ScanHealth' 18 57
    Write-SOProgress 78 'SFC VerifyOnly'
    $c=Invoke-SOExternal 'sfc.exe' @('/verifyonly') 'SFC VerifyOnly' 78 20
    if($a -ne 0 -or $b -ne 0 -or $c -ne 0){Write-SOLog 'A verificação encontrou erro ou comando retornou código não-zero. Consulte o log.' 'WARN'}
    [void](Set-SOMaintenanceStamp 'HealthScan')
    Write-SOProgress 100 'Verificação concluída. Nenhum reparo foi forçado automaticamente.'
}
function Invoke-SORepairWindows {
    Write-SOProgress 2 'DISM RestoreHealth iniciado. A porcentagem pode ficar parada por bastante tempo sem estar travada.'
    $a=Invoke-SOExternal 'DISM.exe' @('/Online','/Cleanup-Image','/RestoreHealth') 'DISM RestoreHealth' 2 70
    Write-SOProgress 75 'SFC ScanNow'
    $b=Invoke-SOExternal 'sfc.exe' @('/scannow') 'SFC ScanNow' 75 23
    if($a -ne 0 -or $b -ne 0){throw "Reparo terminou com código DISM=$a SFC=$b. Consulte o log."}
    [void](Set-SOMaintenanceStamp 'RepairWindows')
    Write-SOProgress 100 'Reparo do Windows concluído'
}

function Set-SOHAGS([bool]$Enabled){
    [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' DWord $(if($Enabled){2}else{1}) 'GPU')
}
function Set-SOMPOOff {
    [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' DWord 5 'GPU')
}
function Restore-SOGPU {Restore-SORegistry 'GPU'}

function Set-SOPerGamePriority {
    param([string]$ExeName)
    if([string]::IsNullOrWhiteSpace($ExeName)){throw 'Nome do executável vazio'}
    $name=[IO.Path]::GetFileName($ExeName)
    if(-not $name.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)){throw 'Selecione um arquivo .exe'}
    $path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name\PerfOptions"
    [void](Set-SORegistryValue $path 'CpuPriorityClass' DWord 3 'PerGame')
}

function Get-SOPerGamePriorities {
    $root='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $items=New-Object System.Collections.Generic.List[object]
    if(-not(Test-Path $root)){return @()}
    foreach($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)){
        $name=[string]$k.PSChildName
        $canonical="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name\PerfOptions"
        $v=$null
        try{$v=(Get-ItemProperty -LiteralPath $canonical -Name CpuPriorityClass -ErrorAction Stop).CpuPriorityClass}catch{continue}
        $label=switch([int]$v){1{'IDLE'};2{'NORMAL'};3{'HIGH'};4{'REALTIME'};5{'BELOW NORMAL'};6{'ABOVE NORMAL'};default{'VALOR '+[string]$v}}
        $backup=Join-Path (Get-SORegDir) ((Get-SOHash "$canonical|CpuPriorityClass")+'.json')
        $origin='DETECTADO'
        if(Test-Path -LiteralPath $backup){
            try{
                $b=Get-Content -LiteralPath $backup -Raw -Encoding UTF8|ConvertFrom-Json
                $originalValue=if($b.Exists){[int]$b.Data}else{$null}
                if([int]$v -eq 3 -and ((-not [bool]$b.Exists) -or $originalValue -ne 3)){$origin='SUPER OPTIMIZER'}
                elseif([bool]$b.Exists -and [int]$v -eq $originalValue){$origin='ORIGINAL / RESTAURADO'}
                elseif((-not [bool]$b.Exists) -and $null -eq $v){$origin='ORIGINAL / RESTAURADO'}
                else{$origin='ALTERADO APÓS BACKUP'}
            }catch{$origin='BACKUP INVÁLIDO'}
        }
        [void]$items.Add([pscustomobject]@{
            Executable=$name
            Priority=$label
            Value=[int]$v
            Managed=$origin
        })
    }
    return @($items | Sort-Object Executable)
}

function Restore-SOPerGameOne {
    param([string]$ExeName)
    if([string]::IsNullOrWhiteSpace($ExeName)){throw 'Selecione um jogo da lista'}
    $name=[IO.Path]::GetFileName($ExeName)
    $path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name\PerfOptions"
    $file=Join-Path (Get-SORegDir) ((Get-SOHash "$path|CpuPriorityClass")+'.json')
    if(-not(Test-Path -LiteralPath $file)){throw 'Este executável não possui backup do Super Optimizer; ele não será alterado automaticamente.'}
    try{$state=Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop}
    catch{throw ("Backup de prioridade inválido: {0}" -f $_.Exception.Message)}
    if([string]$state.Path -ne $path -or [string]$state.Name -ne 'CpuPriorityClass' -or [string]$state.Category -ne 'PerGame'){
        throw 'O backup não corresponde ao executável selecionado.'
    }
    if($script:DryRun){Write-SOLog "Restauraria prioridade de $name" 'PLAN';return}
    try{
        if([bool]$state.Exists){
            $restorePath=[string]$state.Path;$restoreName=[string]$state.Name;$kind=[string]$state.Kind
            if(-not(Test-Path -LiteralPath $restorePath)){
                New-Item -Path $restorePath -Force -ErrorAction Stop | Out-Null
            }
            $key=Get-Item -LiteralPath $restorePath -ErrorAction Stop
            if($key.GetValueNames() -contains $restoreName -and $key.GetValueKind($restoreName).ToString() -eq $kind){
                Set-ItemProperty -LiteralPath $restorePath -Name $restoreName -Value $state.Data -Force -ErrorAction Stop
            }else{
                New-ItemProperty -LiteralPath $restorePath -Name $restoreName -PropertyType $kind -Value $state.Data -Force -ErrorAction Stop | Out-Null
            }
            $actual=(Get-ItemProperty -LiteralPath $restorePath -Name $restoreName -ErrorAction Stop).CpuPriorityClass
            if([int64]$actual -ne [int64]$state.Data){throw 'O valor original não pôde ser confirmado.'}
        }else{
            Remove-ItemProperty -Path ([string]$state.Path) -Name ([string]$state.Name) -Force -ErrorAction SilentlyContinue
            $key=Get-Item -LiteralPath ([string]$state.Path) -ErrorAction SilentlyContinue
            if($key -and $key.GetValueNames() -contains [string]$state.Name){throw 'A prioridade deveria ter sido removida, mas ainda existe.'}
            $keyExisted=$true
            if($state.PSObject.Properties['KeyExisted']){$keyExisted=[bool]$state.KeyExisted}
            if(-not $keyExisted -and $key){
                $hasValues=($key.GetValueNames().Count -gt 0)
                $hasChildren=@(Get-ChildItem -LiteralPath ([string]$state.Path) -ErrorAction SilentlyContinue).Count -gt 0
                if(-not $hasValues -and -not $hasChildren){Remove-Item -LiteralPath ([string]$state.Path) -Force -ErrorAction SilentlyContinue}
            }
        }
        Write-SOLog "Prioridade restaurada para $name" 'OK'
    }catch{throw ("Falha restaurando prioridade de {0}: {1}" -f $name,$_.Exception.Message)}
}

function Restore-SOPerGame {Restore-SORegistry 'PerGame'}

function Get-SORegValue([string]$Path,[string]$Name){try{return (Get-ItemProperty $Path -Name $Name -ErrorAction Stop).$Name}catch{return $null}}
function Get-SOServiceStart([string]$Name){try{return (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -ErrorAction Stop).Start}catch{return $null}}
function Get-SOVBSState {
    $v=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity'
    $h=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
    $launch='UNKNOWN'
    try{$launch=Get-SOHypervisorLaunchType}catch{}
    $off=($launch -ieq 'Off')
    if($v -eq 0 -and $h -eq 0 -and $off){return 'OFF / EXTREMO'}
    if($h -eq 0){return 'HVCI OFF'}
    if($launch -eq 'UNKNOWN'){return 'ATIVO / BCD INDISPONÍVEL'}
    return 'ATIVO / PADRÃO'
}

function Get-SOProfileMatch {
    if(Test-SOGamerBrowserMatch){return 'GAMER + NAVEGADOR'}
    $gm=Get-SORegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $fg=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation'
    $prio=Get-SORegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority'
    $gpu=Get-SORegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority'
    $dvr=Get-SORegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    $pt=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
    $mouse=Get-SORegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed'
    $hib=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $powerName=Get-SOActivePowerName
    $vbs=Get-SOVBSState

    $universalComplete=(($gm -eq 1) -and ($fg -eq 38) -and ($prio -eq 6) -and ($gpu -eq 8))

    $svcItems=@((Get-SOConfig).services);$svcSeen=0;$svcMatched=0
    foreach($svc in $svcItems){
        $start=Get-SOServiceStart ([string]$svc.name)
        if($null -eq $start){continue}
        $svcSeen++
        if(($svc.mode -eq 'Disabled' -and $start -eq 4)-or($svc.mode -eq 'Manual' -and $start -eq 3)){$svcMatched++}
    }
    $svcRatio=if($svcSeen -gt 0){$svcMatched/$svcSeen}else{0}

    # Hibernação é best-effort porque algumas instalações não expõem HibernateEnabled com rollback seguro.
    $aggressiveComplete=$universalComplete -and ($dvr -eq 0) -and ($pt -eq 1) -and ([string]$mouse -eq '0') -and ($powerName -eq 'Super Optimizer Gaming') -and ($svcRatio -ge 0.70)

    if($aggressiveComplete -and $vbs -eq 'OFF / EXTREMO'){return 'EXTREMO'}
    if($aggressiveComplete){return 'AGRESSIVO'}
    if($universalComplete){return 'UNIVERSAL'}
    return 'PADRÃO / CUSTOM'
}

function Get-SOOptionalPropertyValue {
    param($Object,[Parameter(Mandatory=$true)][string]$Name)
    if($null -eq $Object){return $null}
    $prop=$Object.PSObject.Properties[$Name]
    if($null -eq $prop){return $null}
    return $prop.Value
}

function Get-SOStatus {
    $os=$null;$cpu=$null
    try{$os=Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 4 -ErrorAction Stop}catch{}
    try{$cpu=Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 4 -ErrorAction Stop | Select-Object -First 1}catch{}

    $totalGB=if($os){[math]::Round($os.TotalVisibleMemorySize/1MB,1)}else{0}
    $freeGB=if($os){[math]::Round($os.FreePhysicalMemory/1MB,1)}else{0}

    $services=@((Get-SOConfig).services);$matched=0;$count=0
    foreach($s in $services){
        $v=Get-SOServiceStart $s.name
        if($null -eq $v){continue}
        $count++
        if(($s.mode -eq 'Disabled' -and $v -eq 4)-or($s.mode -eq 'Manual' -and $v -eq 3)){$matched++}
    }

    $vbox=Get-Process VirtualBoxVM,VirtualBox,VBoxSVC -ErrorAction SilentlyContinue
    $maint=$null
    $mf=Get-SOMaintenanceFile
    if(Test-Path $mf){try{$maint=Get-Content $mf -Raw|ConvertFrom-Json}catch{}}

    $windowsText=$null
    if($os){$windowsText=$os.Caption+' '+$os.Version}
    else{
        try{$cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop;$windowsText=('{0} {1}.{2}' -f $cv.ProductName,$cv.CurrentBuild,$cv.UBR)}
        catch{$windowsText=[Environment]::OSVersion.VersionString}
    }

    $diskTotal=0;$diskFree=0;$diskPct=0
    try{
        $dev=[string]$env:SystemDrive
        $d=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $dev) -OperationTimeoutSec 4 -ErrorAction Stop
        $diskTotal=[math]::Round([double]$d.Size/1GB,1);$diskFree=[math]::Round([double]$d.FreeSpace/1GB,1)
        if($diskTotal -gt 0){$diskPct=[math]::Round(($diskFree/$diskTotal)*100,1)}
    }catch{}

    return [ordered]@{
        Profile=(Get-SOProfileMatch)
        GameMode=if((Get-SORegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 1){'ON'}else{'PADRÃO/OFF'}
        GameDVR=if((Get-SORegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0){'OFF'}else{'ON/PADRÃO'}
        VBS=(Get-SOVBSState)
        Services="$matched/$count"
        VirtualBox=if($vbox){'RODANDO'}else{'PARADO'}
        Windows=$windowsText
        CPU=if($cpu){$cpu.Name}elseif($env:PROCESSOR_IDENTIFIER){$env:PROCESSOR_IDENTIFIER}else{'Não identificado'}
        RAMTotalGB=$totalGB
        RAMFreeGB=$freeGB
        RAMUsedPercent=if($totalGB -gt 0){[math]::Round((($totalGB-$freeGB)/$totalGB)*100,1)}else{0}
        DiskTotalGB=$diskTotal
        DiskFreeGB=$diskFree
        DiskFreePercent=$diskPct
        PowerPlan=(Get-SOActivePowerGuid)
        PowerPlanName=if(($pn=Get-SOActivePowerName)){$pn}else{'Não identificado'}
        RamCleanerAvailable=if(Test-SORamCleanerAvailable){'SIM'}else{'NÃO'}
        RamCleanerMode=(Get-SORamCleanerMode)
        UpdatePaused=(Get-SOUpdatePauseState)
        WingetAvailable=(Test-SOWingetAvailable)
        RebootPending=(Test-SORebootPending)
        LastWeekly=(Get-SOOptionalPropertyValue $maint 'WeeklySafe')
        LastHealthScan=(Get-SOOptionalPropertyValue $maint 'HealthScan')
        LastFullClean=(Get-SOOptionalPropertyValue $maint 'FullClean')
        LastDeepClean=(Get-SOOptionalPropertyValue $maint 'DeepClean')
        LastCleanupAnalyze=(Get-SOOptionalPropertyValue $maint 'CleanupAnalyze')
        LastWingetScan=(Get-SOOptionalPropertyValue $maint 'WingetScan')
        LastWingetUpgrade=(Get-SOOptionalPropertyValue $maint 'WingetUpgrade')
        LastDnsReview=(Get-SOOptionalPropertyValue $maint 'DnsReview')
        MachineTag=(Get-SOHash $script:MachineId).Substring(0,8)
        PostReboot=(Get-SOPostRebootStatus)
        ReadAt=(Get-Date).ToString('o')
    }
}

function Restore-SOAll {
    $audit=Get-SOStateAudit
    if([int]$audit.IssuesCount -gt 0){
        Write-SOLog ("Rollback: State possui {0} problema(s) estrutural(is). Itens válidos ainda serão restaurados; consulte Diagnóstico > Verificar backups / State." -f $audit.IssuesCount) 'WARN'
    }
    Write-SOProgress 10 'Restaurando Registro'
    Restore-SORegistry 'ALL'
    Write-SOProgress 35 'Restaurando serviços e tarefas'
    Restore-SOServices
    Restore-SOTasks
    Write-SOProgress 60 'Restaurando energia / hibernação / Defender'
    Restore-SOHibernation
    Restore-SOPower
    Restore-SODefender
    Write-SOProgress 80 'Restaurando hypervisor'
    Restore-SOHypervisor
    $updateFile=Get-SOUpdateSessionFile
    if(Test-Path -LiteralPath $updateFile){
        Write-SOProgress 90 'Restaurando sessão temporária do Windows Update'
        [void](Restore-SOUpdateSession)
    }else{
        Write-SOLog 'Rollback: nenhuma sessão temporária do Windows Update foi encontrada; serviços de Update não serão iniciados por efeito colateral.' 'INFO'
    }
    Clear-SOGamerBrowserMarker
    Write-SOProgress 100 'Rollback completo concluído'
}



function Get-SOStateAudit {
    [void](Initialize-SOEnvironment)
    $issues=New-Object System.Collections.Generic.List[string]
    $checked=0
    function Add-Issue([string]$Text){[void]$issues.Add($Text)}

    foreach($f in @(Get-ChildItem (Get-SORegDir) -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        $checked++
        try{
            $o=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            if(-not $o.PSObject.Properties['Path'] -or -not $o.PSObject.Properties['Name'] -or -not $o.PSObject.Properties['Category'] -or -not $o.PSObject.Properties['Exists']){Add-Issue ("Registry/{0}: campos obrigatórios ausentes" -f $f.Name);continue}
            $expectedName=(Get-SOHash (([string]$o.Path)+'|'+([string]$o.Name)))+'.json'
            if($f.Name -ine $expectedName){Add-Issue ("Registry/{0}: nome do arquivo não corresponde ao Path/Name salvo" -f $f.Name)}
            if([bool]$o.Exists -and (-not $o.PSObject.Properties['Kind'] -or @('String','ExpandString','Binary','DWord','MultiString','QWord') -notcontains [string]$o.Kind)){Add-Issue ("Registry/{0}: Kind inválido" -f $f.Name)}
        }catch{Add-Issue ("Registry/{0}: JSON inválido - {1}" -f $f.Name,$_.Exception.Message)}
    }
    foreach($f in @(Get-ChildItem (Get-SOSvcDir) -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        $checked++
        try{
            $o=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            if(-not $o.PSObject.Properties['Name'] -or -not $o.PSObject.Properties['Start'] -or -not $o.PSObject.Properties['WasRunning']){Add-Issue ("Services/{0}: campos obrigatórios ausentes" -f $f.Name)}
            else{
                if($f.Name -ine (([string]$o.Name)+'.json')){Add-Issue ("Services/{0}: nome do arquivo não corresponde ao serviço salvo" -f $f.Name)}
                if([int]$o.Start -lt 0 -or [int]$o.Start -gt 4){Add-Issue ("Services/{0}: Start fora do intervalo 0..4" -f $f.Name)}
            }
        }catch{Add-Issue ("Services/{0}: JSON inválido - {1}" -f $f.Name,$_.Exception.Message)}
    }
    foreach($f in @(Get-ChildItem (Get-SOTaskDir) -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        $checked++
        try{
            $o=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            if(-not $o.PSObject.Properties['TaskPath'] -or -not $o.PSObject.Properties['TaskName'] -or -not $o.PSObject.Properties['Enabled']){Add-Issue ("Tasks/{0}: campos obrigatórios ausentes" -f $f.Name)}
            else{
                $expectedTask=(Get-SOHash (([string]$o.TaskPath)+'|'+([string]$o.TaskName)))+'.json'
                if($f.Name -ine $expectedTask){Add-Issue ("Tasks/{0}: nome do arquivo não corresponde à tarefa salva" -f $f.Name)}
            }
        }catch{Add-Issue ("Tasks/{0}: JSON inválido - {1}" -f $f.Name,$_.Exception.Message)}
    }
    foreach($f in @(Get-ChildItem (Get-SOSettingsDir) -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        $checked++
        try{
            $o=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            switch($f.BaseName){
                'hibernation' {
                    if(-not $o.PSObject.Properties['Exists']){Add-Issue 'Settings/hibernation.json: campo Exists ausente'}
                    elseif([bool]$o.Exists -and -not $o.PSObject.Properties['Enabled']){Add-Issue 'Settings/hibernation.json: Enabled ausente'}
                }
                'defender' {
                    if(-not $o.PSObject.Properties['ScanAvgCPULoadFactor']){Add-Issue 'Settings/defender.json: ScanAvgCPULoadFactor ausente'}
                }
                'powerplan' {
                    if(-not $o.PSObject.Properties['Original'] -or [string]::IsNullOrWhiteSpace([string]$o.Original)){Add-Issue 'Settings/powerplan.json: plano Original ausente'}
                }
                'hypervisor' {
                    if(-not $o.PSObject.Properties['HypervisorLaunchType']){Add-Issue 'Settings/hypervisor.json: HypervisorLaunchType ausente'}
                }
            }
        }catch{Add-Issue ("Settings/{0}: JSON inválido - {1}" -f $f.Name,$_.Exception.Message)}
    }
    $maintenance=Get-SOMaintenanceFile
    if(Test-Path -LiteralPath $maintenance){
        $checked++
        try{[void](Get-Content -LiteralPath $maintenance -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop)}
        catch{Add-Issue ("Maintenance/history.json: JSON inválido - {0}" -f $_.Exception.Message)}
    }
    $updateFile=Get-SOUpdateSessionFile
    if((Test-Path -LiteralPath $updateFile) -and $null -eq (Read-SOUpdateSessionSnapshot)){Add-Issue 'Settings/update_session.json: snapshot inválido'}

    return [ordered]@{
        Health=if($issues.Count -eq 0){'OK'}else{'ATENÇÃO'}
        FilesChecked=$checked
        IssuesCount=$issues.Count
        Issues=[string[]]$issues.ToArray()
        MachineTag=(Get-SOHash $script:MachineId).Substring(0,8)
    }
}

function Get-SODiagnosticQuick {
    $s=Get-SOStatus;$a=Get-SOStateAudit
    return [ordered]@{Windows=$s.Windows;CPU=$s.CPU;RAM=('{0} GB total | {1} GB livre | {2}% em uso' -f $s.RAMTotalGB,$s.RAMFreeGB,$s.RAMUsedPercent);Disk=('{0} GB livre de {1} GB | {2}% livre' -f $s.DiskFreeGB,$s.DiskTotalGB,$s.DiskFreePercent);Profile=$s.Profile;Gaming=('Game Mode={0} | Game DVR={1}' -f $s.GameMode,$s.GameDVR);VBS=$s.VBS;Services=$s.Services;PowerPlan=$s.PowerPlanName;WindowsUpdatePaused=$s.UpdatePaused;WinGet=if([bool]$s.WingetAvailable){'Disponível'}else{'Não detectado'};RebootPending=if([bool]$s.RebootPending){'SIM'}else{'NÃO'};StateHealth=$a.Health;StateFilesChecked=$a.FilesChecked;StateIssues=$a.IssuesCount;LastWeekly=if($s.LastWeekly){$s.LastWeekly}else{'Nunca'};LastHealthScan=if($s.LastHealthScan){$s.LastHealthScan}else{'Nunca'};MachineTag=$s.MachineTag;CheckedAt=(Get-Date).ToString('o')}
}

function New-SODiagnosticReport {
    if($script:DryRun){
        Write-SOLog 'Geraria relatório de diagnóstico em State\\Machines\\<MachineGuid>\\Reports' 'PLAN'
        return 'DRY-RUN'
    }

    $dir=Get-SOReportsDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $status=Get-SOStatus
    $stateAudit=Get-SOStateAudit
    $cfg=Get-SOConfig
    $path=Join-Path $dir ('SuperOptimizer_Diagnostico_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.txt')

    $lines=New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('SUPER OPTIMIZER - RELATÓRIO DE DIAGNÓSTICO')
    [void]$lines.Add(('Gerado em: {0}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')))
    [void]$lines.Add(('Versão: {0}' -f $cfg.version))
    [void]$lines.Add('Escopo de backup: máquina atual')
    [void]$lines.Add('')
    [void]$lines.Add('=== SISTEMA ===')
    [void]$lines.Add(('Windows: {0}' -f $status.Windows))
    [void]$lines.Add(('CPU: {0}' -f $status.CPU))
    [void]$lines.Add(('RAM: {0} GB total | {1} GB livres | {2}% em uso' -f $status.RAMTotalGB,$status.RAMFreeGB,$status.RAMUsedPercent))
    [void]$lines.Add(('Plano de energia: {0}' -f $status.PowerPlanName))
    [void]$lines.Add(('VirtualBox: {0}' -f $status.VirtualBox))
    [void]$lines.Add('')
    [void]$lines.Add('=== SUPER OPTIMIZER ===')
    [void]$lines.Add(('Perfil detectado: {0}' -f $status.Profile))
    [void]$lines.Add(('Game Mode: {0}' -f $status.GameMode))
    [void]$lines.Add(('Game DVR: {0}' -f $status.GameDVR))
    [void]$lines.Add(('VBS/HVCI: {0}' -f $status.VBS))
    [void]$lines.Add(('Serviços compatíveis com perfil: {0}' -f $status.Services))
    [void]$lines.Add(('RAM cleaner: {0} | método={1}' -f $status.RamCleanerAvailable,$status.RamCleanerMode))
    [void]$lines.Add(('Update pausado pelo Super Optimizer: {0}' -f $status.UpdatePaused))
    [void]$lines.Add(('Integridade do State: {0} | arquivos verificados={1} | problemas={2}' -f $stateAudit.Health,$stateAudit.FilesChecked,$stateAudit.IssuesCount))
    [void]$lines.Add(('Última manutenção semanal: {0}' -f $(if($status.LastWeekly){$status.LastWeekly}else{'Nunca'})))
    [void]$lines.Add(('Última verificação de integridade: {0}' -f $(if($status.LastHealthScan){$status.LastHealthScan}else{'Nunca'})))
    [void]$lines.Add('')
    [void]$lines.Add('=== RECURSOS PRESERVADOS PELO PERFIL ===')
    foreach($p in @($cfg.preserved)){[void]$lines.Add(('- '+[string]$p))}
    [void]$lines.Add('')
    [void]$lines.Add('=== SERVIÇOS DO PERFIL ===')
    foreach($item in @($cfg.services)){
        $svc=Get-Service ([string]$item.name) -ErrorAction SilentlyContinue
        $start=Get-SOServiceStart ([string]$item.name)
        $statusText=if($svc){[string]$svc.Status}else{'Ausente'}
        [void]$lines.Add(('{0} | alvo={1} | Start={2} | status={3} | {4}' -f $item.name,$item.mode,$start,$statusText,$item.label))
    }
    [void]$lines.Add('')
    [void]$lines.Add('=== OBSERVAÇÃO ===')
    [void]$lines.Add('Este relatório não altera o Windows e não inclui senhas ou conteúdo pessoal de arquivos.')

    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    Write-SOLog ("Relatório de diagnóstico criado: {0}" -f $path) 'OK'
    return $path
}

function Clear-SOOldLogs {
    param([int]$Days=30)
    $logRoot=Join-Path $script:StateRoot 'Logs'
    if($script:DryRun){Write-SOLog ("Removeria logs .log com mais de {0} dias" -f $Days) 'PLAN';return 0}
    if(-not(Test-Path -LiteralPath $logRoot)){return 0}
    $cut=(Get-Date).AddDays(-[math]::Abs($Days))
    $files=@(Get-ChildItem -LiteralPath $logRoot -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -lt $cut})
    $removed=0
    foreach($f in $files){
        try{Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop;$removed++}
        catch{Write-SOLog ("Log antigo não removido: {0}" -f $f.Name) 'WARN'}
    }
    Write-SOLog ("Logs antigos removidos: {0}/{1}" -f $removed,$files.Count) 'OK'
    return $removed
}

function Initialize-SORamNativeApi {
    if($script:RamNativeApiReady){return $true}
    try{
        $existing=([System.Management.Automation.PSTypeName]'SuperOptimizerNative.MemoryApi').Type
        if($null -eq $existing){
            $source=@'
using System;
using System.Runtime.InteropServices;

namespace SuperOptimizerNative {
    public static class MemoryApi {
        const UInt32 TOKEN_QUERY = 0x0008;
        const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x0020;
        const UInt32 SE_PRIVILEGE_ENABLED = 0x00000002;
        const Int32 ERROR_NOT_ALL_ASSIGNED = 1300;
        const Int32 SystemMemoryListInformation = 80;

        [StructLayout(LayoutKind.Sequential)]
        struct LUID {
            public UInt32 LowPart;
            public Int32 HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct LUID_AND_ATTRIBUTES {
            public LUID Luid;
            public UInt32 Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_PRIVILEGES {
            public UInt32 PrivilegeCount;
            public LUID_AND_ATTRIBUTES Privileges;
        }

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool CloseHandle(IntPtr hObject);

        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool OpenProcessToken(IntPtr ProcessHandle, UInt32 DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, UInt32 BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("ntdll.dll")]
        static extern Int32 NtSetSystemInformation(Int32 SystemInformationClass, ref Int32 SystemInformation, Int32 SystemInformationLength);

        public static Int32 EnableProfilePrivilege() {
            IntPtr token;
            if(!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES, out token))
                return Marshal.GetLastWin32Error();
            try {
                LUID luid;
                if(!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out luid))
                    return Marshal.GetLastWin32Error();
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Privileges = new LUID_AND_ATTRIBUTES();
                tp.Privileges.Luid = luid;
                tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
                if(!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                    return Marshal.GetLastWin32Error();
                int last = Marshal.GetLastWin32Error();
                if(last == ERROR_NOT_ALL_ASSIGNED) return last;
                return 0;
            } finally {
                CloseHandle(token);
            }
        }

        public static Int32 ExecuteMemoryListCommand(Int32 command) {
            Int32 value = command;
            return NtSetSystemInformation(SystemMemoryListInformation, ref value, sizeof(Int32));
        }
    }
}
'@
            Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        }
        $script:RamNativeApiReady=$true
        return $true
    }catch{
        $script:RamNativeApiReady=$false
        Write-SOLog ("API nativa de RAM indisponível: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}


# =============================================================================
# WINDOWS STUDIO - sessão reversível + módulos individuais
# =============================================================================
function Get-SOWindowsStudioRegistryTargets {
    return @(
        # Gaming
        [pscustomobject]@{Module='GameMode';Path='HKCU:\Software\Microsoft\GameBar';Name='AllowAutoGameMode';Type='DWord';Desired=1},
        [pscustomobject]@{Module='GameMode';Path='HKCU:\Software\Microsoft\GameBar';Name='AutoGameModeEnabled';Type='DWord';Desired=1},
        [pscustomobject]@{Module='GameDVR';Path='HKCU:\System\GameConfigStore';Name='GameDVR_Enabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='GameDVR';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR';Name='AppCaptureEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='GameDVR';Path='HKCU:\Software\Microsoft\GameBar';Name='ShowStartupPanel';Type='DWord';Desired=0},
        [pscustomobject]@{Module='MMCSS';Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';Name='GPU Priority';Type='DWord';Desired=8},
        [pscustomobject]@{Module='MMCSS';Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';Name='Priority';Type='DWord';Desired=6},
        [pscustomobject]@{Module='MMCSS';Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';Name='Scheduling Category';Type='String';Desired='High'},
        [pscustomobject]@{Module='MMCSS';Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';Name='SFIO Priority';Type='String';Desired='High'},
        [pscustomobject]@{Module='Foreground';Path='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl';Name='Win32PrioritySeparation';Type='DWord';Desired=38},
        [pscustomobject]@{Module='MouseAccel';Path='HKCU:\Control Panel\Mouse';Name='MouseSpeed';Type='String';Desired='0'},
        [pscustomobject]@{Module='MouseAccel';Path='HKCU:\Control Panel\Mouse';Name='MouseThreshold1';Type='String';Desired='0'},
        [pscustomobject]@{Module='MouseAccel';Path='HKCU:\Control Panel\Mouse';Name='MouseThreshold2';Type='String';Desired='0'},

        # Power / interface
        [pscustomobject]@{Module='PowerThrottle';Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling';Name='PowerThrottlingOff';Type='DWord';Desired=1},
        [pscustomobject]@{Module='Visuals';Path='HKCU:\Control Panel\Desktop\WindowMetrics';Name='MinAnimate';Type='String';Desired='0'},
        [pscustomobject]@{Module='Visuals';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';Name='TaskbarAnimations';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Transparency';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';Name='EnableTransparency';Type='DWord';Desired=0},
        [pscustomobject]@{Module='StartupDelay';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize';Name='StartupDelayInMSec';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Notifications';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications';Name='ToastEnabled';Type='DWord';Desired=0},

        # Background/privacy granular
        [pscustomobject]@{Module='SearchSuggestions';Path='HKCU:\Software\Policies\Microsoft\Windows\Explorer';Name='DisableSearchBoxSuggestions';Type='DWord';Desired=1},
        [pscustomobject]@{Module='OneDriveSync';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive';Name='DisableFileSyncNGSC';Type='DWord';Desired=1},
        [pscustomobject]@{Module='Copilot';Path='HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot';Name='TurnOffWindowsCopilot';Type='DWord';Desired=1},
        [pscustomobject]@{Module='NewsInterests';Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';Name='AllowNewsAndInterests';Type='DWord';Desired=0},
        [pscustomobject]@{Module='SuggestedContent';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';Name='SilentInstalledAppsEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='SuggestedContent';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';Name='SystemPaneSuggestionsEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='SuggestedContent';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';Name='SoftLandingEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='ActivityHistory';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='EnableActivityFeed';Type='DWord';Desired=0},
        [pscustomobject]@{Module='ActivityHistory';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='PublishUserActivities';Type='DWord';Desired=0},
        [pscustomobject]@{Module='ActivityHistory';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='UploadUserActivities';Type='DWord';Desired=0},
        [pscustomobject]@{Module='EdgeStartup';Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';Name='StartupBoostEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='EdgeBackground';Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';Name='BackgroundModeEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='ChromeBackground';Path='HKLM:\SOFTWARE\Policies\Google\Chrome';Name='BackgroundModeEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='DeliveryOptimization';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization';Name='DODownloadMode';Type='DWord';Desired=0},

        # Telemetry + experimental GPU
        [pscustomobject]@{Module='TelemetryPolicy';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';Name='AllowTelemetry';Type='DWord';Desired=0},
        [pscustomobject]@{Module='HAGSOn';Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';Name='HwSchMode';Type='DWord';Desired=2},
        [pscustomobject]@{Module='MPOOff';Path='HKLM:\SOFTWARE\Microsoft\Windows\Dwm';Name='OverlayTestMode';Type='DWord';Desired=5},

        # Legacy bundle targets kept for old RC8/RC9 snapshots.
        [pscustomobject]@{Module='Background';Path='HKCU:\Software\Policies\Microsoft\Windows\Explorer';Name='DisableSearchBoxSuggestions';Type='DWord';Desired=1},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive';Name='DisableFileSyncNGSC';Type='DWord';Desired=1},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';Name='AllowNewsAndInterests';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot';Name='TurnOffWindowsCopilot';Type='DWord';Desired=1},
        [pscustomobject]@{Module='Background';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';Name='SilentInstalledAppsEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';Name='SystemPaneSuggestionsEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';Name='SoftLandingEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='EnableActivityFeed';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='PublishUserActivities';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='UploadUserActivities';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';Name='StartupBoostEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';Name='BackgroundModeEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Google\Chrome';Name='BackgroundModeEnabled';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Background';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization';Name='DODownloadMode';Type='DWord';Desired=0},
        [pscustomobject]@{Module='Telemetry';Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';Name='AllowTelemetry';Type='DWord';Desired=0}
    )
}

function Get-SORegistrySnapshotValue {
    param([string]$Path,[string]$Name)
    $keyExisted=Test-Path -LiteralPath $Path
    $exists=$false;$kind=$null;$data=$null
    if($keyExisted){
        try{
            $key=Get-Item -LiteralPath $Path -ErrorAction Stop
            if($key.GetValueNames() -contains $Name){
                $exists=$true
                $kind=$key.GetValueKind($Name).ToString()
                $data=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }catch{}
    }
    return [ordered]@{Path=$Path;Name=$Name;KeyExisted=$keyExisted;Exists=$exists;Kind=$kind;Data=$data}
}

function Restore-SORegistrySnapshotValue {
    param($State)
    if($script:DryRun){Write-SOLog ("Restauraria sessão: {0} / {1}" -f $State.Path,$State.Name) 'PLAN';return $true}
    try{
        $path=[string]$State.Path;$name=[string]$State.Name
        if([bool]$State.Exists){
            # Não recrie uma chave que já existe. New-Item -Force sobre chaves HKCU
            # populadas pode gerar UnauthorizedAccessException no Registry Provider.
            if(-not(Test-Path -LiteralPath $path)){
                New-Item -Path $path -Force -ErrorAction Stop|Out-Null
            }
            $kind=[string]$State.Kind;$value=$State.Data
            if($kind -eq 'Binary'){$value=[byte[]]@($State.Data|ForEach-Object {[byte]$_})}
            elseif($kind -eq 'MultiString'){$value=[string[]]@($State.Data)}

            # Set-ItemProperty é menos invasivo para uma chave existente. Se o valor
            # tiver desaparecido durante a sessão, New-ItemProperty faz o fallback.
            $setOk=$false;$lastError=$null
            for($attempt=1;$attempt -le 2 -and -not $setOk;$attempt++){
                try{
                    $key=Get-Item -LiteralPath $path -ErrorAction Stop
                    if($key.GetValueNames() -contains $name){
                        Set-ItemProperty -LiteralPath $path -Name $name -Type $kind -Value $value -Force -ErrorAction Stop
                    }else{
                        New-ItemProperty -LiteralPath $path -Name $name -PropertyType $kind -Value $value -Force -ErrorAction Stop|Out-Null
                    }
                    $setOk=$true
                }catch{
                    $lastError=$_
                    if($attempt -lt 2){Start-Sleep -Milliseconds 120}
                }
            }
            if(-not $setOk){throw $lastError}

            $key=Get-Item -LiteralPath $path -ErrorAction Stop
            $actual=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if(-not(Test-SORegistryDataEqual $kind $actual $value)){throw 'O valor restaurado não pôde ser confirmado.'}
        }else{
            # Remoção é idempotente: shell/serviços podem apagar a chave ou o valor
            # entre a captura do snapshot e o rollback. O estado final é a autoridade.
            if(Test-Path -LiteralPath $path){
                try{Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction Stop}
                catch{
                    $afterRemove=Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                    if($afterRemove -and $afterRemove.GetValueNames() -contains $name){throw}
                }
            }
            $key=Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if($key -and $key.GetValueNames() -contains $name){throw 'O valor deveria ter sido removido, mas ainda existe.'}

            $keyExisted=$true;if($State.PSObject.Properties['KeyExisted']){$keyExisted=[bool]$State.KeyExisted}
            if(-not $keyExisted -and $key){
                $hasValues=($key.GetValueNames().Count -gt 0)
                $hasChildren=@(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue).Count -gt 0
                if(-not $hasValues -and -not $hasChildren){
                    try{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
                    catch{
                        # Corrida benignA: se outra parte do Windows já removeu a chave,
                        # o rollback exato foi atingido apesar da exceção do provider.
                        if(Test-Path -LiteralPath $path){
                            $still=Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                            $stillValues=if($still){$still.GetValueNames().Count}else{0}
                            $stillChildren=if($still){@(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue).Count}else{0}
                            if($still -and $stillValues -eq 0 -and $stillChildren -eq 0){
                                # Uma chave vazia residual não altera comportamento, mas tentamos
                                # uma segunda remoção curta antes de considerar falha real.
                                Start-Sleep -Milliseconds 120
                                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                            }
                            if(Test-Path -LiteralPath $path){throw}
                        }
                    }
                }
            }
        }
        return $true
    }catch{Write-SOLog ("Falha restaurando valor da sessão: {0}/{1} :: {2}" -f $State.Path,$State.Name,$_.Exception.Message) 'WARN';return $false}
}

function Get-SOServiceSessionState {
    param([string]$Name)
    try{
        $svc=Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'","''")) -OperationTimeoutSec 5 -ErrorAction Stop
        $rp="HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
        $reg=Get-ItemProperty -LiteralPath $rp -ErrorAction Stop
        $delayed=$null;if($reg.PSObject.Properties['DelayedAutoStart']){$delayed=[int]$reg.DelayedAutoStart}
        return [ordered]@{Name=$Name;Exists=$true;Start=[int]$reg.Start;DelayedAutoStart=$delayed;StartMode=[string]$svc.StartMode;State=[string]$svc.State}
    }catch{return [ordered]@{Name=$Name;Exists=$false;Start=$null;DelayedAutoStart=$null;StartMode=$null;State=$null}}
}

function Restore-SOServiceSessionState {
    param($State)
    if(-not [bool]$State.Exists){return $true}
    if($script:DryRun){Write-SOLog ("Restauraria serviço da sessão: {0}" -f $State.Name) 'PLAN';return $true}
    try{
        $name=[string]$State.Name;$start=if($State.PSObject.Properties['Start'] -and $null -ne $State.Start){[int]$State.Start}else{switch([string]$State.StartMode){'Auto'{2}'Automatic'{2}'Manual'{3}'Disabled'{4}default{3}}}
        $delayed=if($State.PSObject.Properties['DelayedAutoStart']){$State.DelayedAutoStart}else{$null}
        Set-SOServiceStartupFromBackup -Name $name -Start $start -DelayedAutoStart $delayed
        if([string]$State.State -eq 'Running'){Start-Service -Name $name -ErrorAction SilentlyContinue}else{Stop-Service -Name $name -Force -ErrorAction SilentlyContinue}
        return $true
    }catch{Write-SOLog ("Falha restaurando serviço da sessão {0}: {1}" -f $State.Name,$_.Exception.Message) 'WARN';return $false}
}

function Get-SOTaskSessionState {
    param([string]$Path,[string]$Name)
    try{$t=Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop;return [ordered]@{Path=$Path;Name=$Name;Exists=$true;Enabled=($t.State -ne 'Disabled')}}
    catch{return [ordered]@{Path=$Path;Name=$Name;Exists=$false;Enabled=$false}}
}
function Restore-SOTaskSessionState {
    param($State)
    if(-not [bool]$State.Exists){return $true}
    if($script:DryRun){Write-SOLog ("Restauraria tarefa da sessão: {0}{1}" -f $State.Path,$State.Name) 'PLAN';return $true}
    try{
        if([bool]$State.Enabled){Enable-ScheduledTask -TaskPath ([string]$State.Path) -TaskName ([string]$State.Name) -ErrorAction Stop|Out-Null}
        else{Disable-ScheduledTask -TaskPath ([string]$State.Path) -TaskName ([string]$State.Name) -ErrorAction Stop|Out-Null}
        return $true
    }catch{Write-SOLog ("Falha restaurando tarefa da sessão: {0}" -f $_.Exception.Message) 'WARN';return $false}
}

function Get-SOWindowsStudioServiceNames {
    param([object[]]$Modules)
    $mods=@(Normalize-SOWindowsStudioModules $Modules);$names=@()
    if($mods -contains 'Telemetry' -or $mods -contains 'DiagTrack'){$names += 'DiagTrack'}
    if($mods -contains 'Telemetry' -or $mods -contains 'WerSvc'){$names += 'WerSvc'}
    if($mods -contains 'Indexing'){$names += 'WSearch'}
    if($mods -contains 'SysMainOff'){$names += 'SysMain'}
    return [string[]]@($names|Select-Object -Unique)
}
function Test-SOWindowsStudioUsesTelemetryTasks {
    param([object[]]$Modules);$mods=@(Normalize-SOWindowsStudioModules $Modules);return ($mods -contains 'Telemetry' -or $mods -contains 'TelemetryTasks')
}
function Backup-SOMemoryCompression {
    if($null -ne (Get-SOSetting 'memory_compression')){return $true}
    try{$m=Get-MMAgent -ErrorAction Stop;return (Save-SOSetting 'memory_compression' ([ordered]@{Enabled=[bool]$m.MemoryCompression}))}
    catch{Write-SOLog ("Não foi possível salvar MemoryCompression: {0}" -f $_.Exception.Message) 'WARN';return $false}
}
function Set-SOMemoryCompressionOff {
    if($script:DryRun){Write-SOLog 'MemoryCompression OFF [experimental]' 'PLAN';return $true}
    if(-not(Backup-SOMemoryCompression)){Write-SOLog 'MemoryCompression não foi alterado porque o estado original não pôde ser salvo.' 'WARN';return $false}
    try{Disable-MMAgent -MemoryCompression -ErrorAction Stop;$m=Get-MMAgent -ErrorAction Stop;if([bool]$m.MemoryCompression){throw 'MemoryCompression ainda está ativo.'};Write-SOLog 'MemoryCompression desativado e verificado' 'OK';return $true}
    catch{Write-SOLog ("Falha alterando MemoryCompression: {0}" -f $_.Exception.Message) 'WARN';return $false}
}
function Restore-SOMemoryCompression {
    $s=Get-SOSetting 'memory_compression';if(-not $s){return}
    if($script:DryRun){Write-SOLog 'Restauraria MemoryCompression' 'PLAN';return}
    try{if([bool]$s.Enabled){Enable-MMAgent -MemoryCompression -ErrorAction Stop}else{Disable-MMAgent -MemoryCompression -ErrorAction Stop};Write-SOLog 'MemoryCompression restaurado' 'OK'}
    catch{Write-SOLog ("Falha restaurando MemoryCompression: {0}" -f $_.Exception.Message) 'WARN'}
}
function Get-SOWindowsStudioCatalog {
    return @(
        [pscustomobject]@{Id='GameMode';Name='Modo de Jogo ON';Group='Gaming';Risk='BAIXO';Recommended=$true;Target='Game Mode automático ativado'},
        [pscustomobject]@{Id='GameDVR';Name='Capturas / Game DVR OFF';Group='Gaming';Risk='BAIXO';Recommended=$true;Target='Captura em segundo plano desativada'},
        [pscustomobject]@{Id='MMCSS';Name='Prioridade MMCSS Games';Group='Gaming';Risk='MÉDIO';Recommended=$true;Target='GPU Priority 8 / Priority 6 / High'},
        [pscustomobject]@{Id='Foreground';Name='Prioridade de foreground';Group='Gaming';Risk='MÉDIO';Recommended=$true;Target='Win32PrioritySeparation=0x26'},
        [pscustomobject]@{Id='MouseAccel';Name='Aceleração do mouse OFF';Group='Gaming';Risk='BAIXO';Recommended=$true;Target='MouseSpeed/Thresholds=0'},
        [pscustomobject]@{Id='DefenderScan';Name='Defender: scan médio 20%';Group='Gaming';Risk='MÉDIO';Recommended=$false;Target='ScanAvgCPULoadFactor=20; Defender continua ativo'},

        [pscustomobject]@{Id='Energy';Name='Plano Energia Gaming';Group='Energia';Risk='BAIXO';Recommended=$true;Target='Plano dedicado para uso na tomada'},
        [pscustomobject]@{Id='PowerThrottle';Name='Power Throttling OFF';Group='Energia';Risk='BAIXO';Recommended=$true;Target='PowerThrottlingOff=1'},
        [pscustomobject]@{Id='Hibernation';Name='Hibernação OFF';Group='Energia';Risk='MÉDIO';Recommended=$false;Target='powercfg /hibernate off com rollback'},

        [pscustomobject]@{Id='Visuals';Name='Efeitos visuais reduzidos';Group='Interface';Risk='BAIXO';Recommended=$true;Target='MinAnimate=0 + TaskbarAnimations=0; tema claro/escuro preservado'},
        [pscustomobject]@{Id='Transparency';Name='Transparência OFF';Group='Interface';Risk='BAIXO';Recommended=$false;Target='EnableTransparency=0'},
        [pscustomobject]@{Id='StartupDelay';Name='Atraso de inicialização OFF';Group='Interface';Risk='MÉDIO';Recommended=$false;Target='StartupDelayInMSec=0'},
        [pscustomobject]@{Id='Notifications';Name='Notificações Toast OFF';Group='Interface';Risk='MÉDIO';Recommended=$false;Target='ToastEnabled=0'},

        [pscustomobject]@{Id='SearchSuggestions';Name='Sugestões da Pesquisa OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='DisableSearchBoxSuggestions=1'},
        [pscustomobject]@{Id='OneDriveSync';Name='OneDrive Sync por política OFF';Group='Background / Privacidade';Risk='MÉDIO';Recommended=$true;Target='DisableFileSyncNGSC=1'},
        [pscustomobject]@{Id='Copilot';Name='Copilot OFF por política';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='TurnOffWindowsCopilot=1'},
        [pscustomobject]@{Id='NewsInterests';Name='News / Interests OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='AllowNewsAndInterests=0'},
        [pscustomobject]@{Id='SuggestedContent';Name='Conteúdo sugerido OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='Apps silenciosos / sugestões / SoftLanding OFF'},
        [pscustomobject]@{Id='ActivityHistory';Name='Histórico de atividade OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='Activity Feed / Publish / Upload OFF'},
        [pscustomobject]@{Id='EdgeStartup';Name='Edge Startup Boost OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='StartupBoostEnabled=0'},
        [pscustomobject]@{Id='EdgeBackground';Name='Edge em background OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='BackgroundModeEnabled=0'},
        [pscustomobject]@{Id='ChromeBackground';Name='Chrome em background OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='BackgroundModeEnabled=0'},
        [pscustomobject]@{Id='DeliveryOptimization';Name='Delivery Optimization P2P OFF';Group='Background / Privacidade';Risk='BAIXO';Recommended=$true;Target='DODownloadMode=0'},

        [pscustomobject]@{Id='TelemetryPolicy';Name='Política de telemetria mínima';Group='Telemetria / Serviços';Risk='MÉDIO';Recommended=$true;Target='AllowTelemetry=0 quando suportado'},
        [pscustomobject]@{Id='DiagTrack';Name='DiagTrack OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Recommended=$true;Target='Connected User Experiences = Disabled'},
        [pscustomobject]@{Id='WerSvc';Name='Windows Error Reporting OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Recommended=$true;Target='WerSvc=Disabled'},
        [pscustomobject]@{Id='TelemetryTasks';Name='Tarefas de telemetria OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Recommended=$true;Target='Somente lista curada de tarefas'},
        [pscustomobject]@{Id='Indexing';Name='Windows Search Indexing OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Recommended=$false;Target='WSearch=Disabled'},
        [pscustomobject]@{Id='SysMainOff';Name='SysMain OFF';Group='Telemetria / Serviços';Risk='EXPERIMENTAL';Recommended=$false;Target='SysMain=Disabled; não altera Prefetch'},

        [pscustomobject]@{Id='MemoryCompressionOff';Name='Memory Compression OFF';Group='Experimental';Risk='EXPERIMENTAL';Recommended=$false;Target='Disable-MMAgent -MemoryCompression'},
        [pscustomobject]@{Id='HAGSOn';Name='HAGS ON (teste A/B)';Group='Experimental';Risk='EXPERIMENTAL';Recommended=$false;Target='HwSchMode=2; requer reinício'},
        [pscustomobject]@{Id='MPOOff';Name='MPO OFF (troubleshooting)';Group='Experimental';Risk='EXPERIMENTAL';Recommended=$false;Target='OverlayTestMode=5; somente para teste de flicker/stutter'}
    )
}

function New-SOWindowsStudioSnapshot {
    param([object[]]$Modules=(Get-SOWindowsStudioModuleIds))
    $selected=@(Normalize-SOWindowsStudioModules $Modules)
    $regs=@()
    foreach($r in @(Get-SOWindowsStudioRegistryTargets|Where-Object {$selected -contains [string]$_.Module})){$regs += (Get-SORegistrySnapshotValue $r.Path $r.Name)}
    $svcNames=@(Get-SOWindowsStudioServiceNames $selected);$svcs=@();foreach($n in $svcNames){$svcs += (Get-SOServiceSessionState $n)}
    $tasks=@();$taskCapture=Test-SOWindowsStudioUsesTelemetryTasks $selected
    if($taskCapture){foreach($t in @((Get-SOConfig).telemetryTasks)){$tasks += (Get-SOTaskSessionState ([string]$t.path) ([string]$t.name))}}
    $hib=[ordered]@{Captured=($selected -contains 'Hibernation');Exists=$false;Enabled=$null}
    if($hib.Captured){try{$k=Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop;if($k.GetValueNames() -contains 'HibernateEnabled'){$hib.Exists=$true;$hib.Enabled=[int]$k.GetValue('HibernateEnabled')}}catch{}}
    $energyCaptured=($selected -contains 'Energy');$powerState=if($energyCaptured){Get-SOSetting 'powerplan'}else{$null};$activeGuid=if($energyCaptured){Get-SOActivePowerGuid}else{$null}
    $def=[ordered]@{Captured=($selected -contains 'DefenderScan');Valid=$false;ScanAvgCPULoadFactor=$null}
    if($def.Captured){try{$mp=Get-MpPreference -ErrorAction Stop;$def.Valid=$true;$def.ScanAvgCPULoadFactor=[int]$mp.ScanAvgCPULoadFactor}catch{}}
    $mem=[ordered]@{Captured=($selected -contains 'MemoryCompressionOff');Valid=$false;Enabled=$null}
    if($mem.Captured){try{$ma=Get-MMAgent -ErrorAction Stop;$mem.Valid=$true;$mem.Enabled=[bool]$ma.MemoryCompression}catch{}}
    return [ordered]@{Version=4;Created=(Get-Date).ToString('o');SelectedModules=[string[]]$selected;Registry=[object[]]$regs;Services=[object[]]$svcs;Tasks=[object[]]$tasks;TelemetryTasksCaptured=$taskCapture;Hibernation=$hib;EnergyCaptured=$energyCaptured;ActivePowerGuid=$activeGuid;PowerPlanState=$powerState;Defender=$def;MemoryCompression=$mem}
}

function Save-SOWindowsStudioSnapshot {
    param([object[]]$Modules=(Get-SOWindowsStudioModuleIds));$selected=@(Normalize-SOWindowsStudioModules $Modules)
    if($script:DryRun){Write-SOLog ("Criaria snapshot reversível ESCOPADO da sessão Windows Studio: {0}" -f ($selected -join ', ')) 'PLAN';return $true}
    if($selected.Count -eq 0){Write-SOLog 'Snapshot Windows Studio recusado: nenhum módulo selecionado.' 'WARN';return $false}
    $snap=New-SOWindowsStudioSnapshot -Modules $selected
    $expectedRegs=@(Get-SOWindowsStudioRegistryTargets|Where-Object {$selected -contains [string]$_.Module}).Count
    if(@($snap.Registry).Count -ne $expectedRegs){Write-SOLog ("Snapshot do Windows Studio incompleto: Registry {0}/{1}." -f @($snap.Registry).Count,$expectedRegs) 'WARN';return $false}
    $svcNames=@(Get-SOWindowsStudioServiceNames $selected)
    if(@($snap.Services).Count -ne $svcNames.Count){Write-SOLog ("Snapshot do Windows Studio incompleto: Services {0}/{1}." -f @($snap.Services).Count,$svcNames.Count) 'WARN';return $false}
    if((Test-SOWindowsStudioUsesTelemetryTasks $selected) -and @($snap.Tasks).Count -ne @((Get-SOConfig).telemetryTasks).Count){Write-SOLog 'Snapshot do Windows Studio incompleto: tarefas de telemetria.' 'WARN';return $false}
    if($selected -contains 'Energy' -and [string]::IsNullOrWhiteSpace([string]$snap.ActivePowerGuid)){Write-SOLog 'Snapshot do Windows Studio incompleto: plano de energia atual não identificado.' 'WARN';return $false}
    if($selected -contains 'DefenderScan' -and -not [bool]$snap.Defender.Valid){Write-SOLog 'Snapshot do Windows Studio incompleto: preferência do Defender não pôde ser lida.' 'WARN';return $false}
    if($selected -contains 'MemoryCompressionOff' -and -not [bool]$snap.MemoryCompression.Valid){Write-SOLog 'Snapshot do Windows Studio incompleto: MemoryCompression não pôde ser lido.' 'WARN';return $false}
    return (Save-SOSetting 'windows_studio_session' $snap)
}

function Get-SOWindowsStudioModuleIds {
    # Background/Telemetry são IDs legados aceitos para snapshots de versões anteriores.
    return @('GameMode','GameDVR','MMCSS','Foreground','MouseAccel','DefenderScan','Energy','PowerThrottle','Hibernation','Visuals','Transparency','StartupDelay','Notifications','SearchSuggestions','OneDriveSync','Copilot','NewsInterests','SuggestedContent','ActivityHistory','EdgeStartup','EdgeBackground','ChromeBackground','DeliveryOptimization','TelemetryPolicy','DiagTrack','WerSvc','TelemetryTasks','Indexing','SysMainOff','MemoryCompressionOff','HAGSOn','MPOOff','Background','Telemetry')
}

function Get-SOWindowsStudioNonExperimentalModuleIds {
    # Rota legada "Aplicar Tudo": deliberadamente exclui qualquer item EXPERIMENTAL.
    # Os experimentais continuam disponíveis apenas por seleção explícita no Optimization Lab.
    $ids=@()
    foreach($d in @(Get-SOWindowsStudioCatalog)){
        if([string]$d.Risk -ne 'EXPERIMENTAL'){$ids += [string]$d.Id}
    }
    return [string[]]$ids
}

function Normalize-SOWindowsStudioModules {
    param([object[]]$Modules);$allowed=@(Get-SOWindowsStudioModuleIds);$result=@()
    foreach($m in @($Modules)){$id=[string]$m;if($allowed -contains $id -and $result -notcontains $id){$result += $id}}
    return [string[]]$result
}
function Invoke-SOWindowsStudioModule {
    param([Parameter(Mandatory=$true)][string]$Module)
    switch($Module){
        'GameMode' { [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' DWord 1 'StudioGameMode');[void](Set-SORegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' DWord 1 'StudioGameMode') }
        'GameDVR' { [void](Set-SORegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' DWord 0 'StudioGameDVR');[void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' DWord 0 'StudioGameDVR');[void](Set-SORegistryValue 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' DWord 0 'StudioGameDVR') }
        'MMCSS' { $g='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';[void](Set-SORegistryValue $g 'GPU Priority' DWord 8 'StudioMMCSS');[void](Set-SORegistryValue $g 'Priority' DWord 6 'StudioMMCSS');[void](Set-SORegistryValue $g 'Scheduling Category' String 'High' 'StudioMMCSS');[void](Set-SORegistryValue $g 'SFIO Priority' String 'High' 'StudioMMCSS') }
        'Foreground' { [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' DWord 38 'StudioForeground') }
        'MouseAccel' { [void](Set-SORegistryValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' String '0' 'StudioMouseAccel');[void](Set-SORegistryValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' String '0' 'StudioMouseAccel');[void](Set-SORegistryValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' String '0' 'StudioMouseAccel') }
        'DefenderScan' { Set-SODefenderGaming }
        'Energy' { [void](Enable-SOGamingPower) }
        'PowerThrottle' { [void](Set-SOPowerThrottlingOff -Category 'StudioPowerThrottle') }
        'Hibernation' { [void](Disable-SOHibernation) }
        'Visuals' { [void](Set-SOVisualsReduced -Category 'StudioVisuals') }
        'Transparency' { [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' DWord 0 'StudioTransparency' -Optional) }
        'StartupDelay' { [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' DWord 0 'StudioStartupDelay' -Optional) }
        'Notifications' { [void](Set-SORegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' DWord 0 'StudioNotifications' -Optional) }
        'SearchSuggestions' { [void](Set-SORegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' DWord 1 'StudioSearchSuggestions' -Optional) }
        'OneDriveSync' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' DWord 1 'StudioOneDriveSync' -Optional) }
        'Copilot' { [void](Set-SORegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' DWord 1 'StudioCopilot' -Optional) }
        'NewsInterests' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' DWord 0 'StudioNewsInterests' -Optional) }
        'SuggestedContent' { $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';[void](Set-SORegistryValue $p 'SilentInstalledAppsEnabled' DWord 0 'StudioSuggestedContent' -Optional);[void](Set-SORegistryValue $p 'SystemPaneSuggestionsEnabled' DWord 0 'StudioSuggestedContent' -Optional);[void](Set-SORegistryValue $p 'SoftLandingEnabled' DWord 0 'StudioSuggestedContent' -Optional) }
        'ActivityHistory' { $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';[void](Set-SORegistryValue $p 'EnableActivityFeed' DWord 0 'StudioActivityHistory' -Optional);[void](Set-SORegistryValue $p 'PublishUserActivities' DWord 0 'StudioActivityHistory' -Optional);[void](Set-SORegistryValue $p 'UploadUserActivities' DWord 0 'StudioActivityHistory' -Optional) }
        'EdgeStartup' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' DWord 0 'StudioEdgeStartup' -Optional) }
        'EdgeBackground' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' DWord 0 'StudioEdgeBackground' -Optional) }
        'ChromeBackground' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' DWord 0 'StudioChromeBackground' -Optional) }
        'DeliveryOptimization' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' DWord 0 'StudioDeliveryOptimization' -Optional) }
        'TelemetryPolicy' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' DWord 0 'StudioTelemetryPolicy' -Optional) }
        'DiagTrack' { Set-SOServiceMode 'DiagTrack' Disabled 'Telemetria' }
        'WerSvc' { Set-SOServiceMode 'WerSvc' Disabled 'Windows Error Reporting' }
        'TelemetryTasks' { foreach($t in @((Get-SOConfig).telemetryTasks)){Disable-SOTask ([string]$t.path) ([string]$t.name)} }
        'Indexing' { Set-SOServiceMode 'WSearch' Disabled 'Indexação de pesquisa' }
        'SysMainOff' { Set-SOServiceMode 'SysMain' Disabled 'SysMain [experimental]' }
        'MemoryCompressionOff' { [void](Set-SOMemoryCompressionOff) }
        'HAGSOn' { [void](Set-SORegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' DWord 2 'StudioHAGSOn' -Optional) }
        'MPOOff' { [void](Set-SORegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' DWord 5 'StudioMPOOff' -Optional) }
        'Background' { [void](Set-SOBackgroundReduced -Category 'StudioBackground' -IncludeVisuals $false) }
        'Telemetry' { [void](Set-SOTelemetryReduced -Category 'StudioTelemetry') }
        default { throw ("Módulo Windows Studio inválido: {0}" -f $Module) }
    }
}

function Restore-SOWindowsStudioSelectedOriginal {
    param([object[]]$Modules);$selected=@(Normalize-SOWindowsStudioModules $Modules);if($selected.Count -eq 0){throw 'Selecione pelo menos um módulo para restaurar.'}
    $catMap=@{GameMode='StudioGameMode';GameDVR='StudioGameDVR';MMCSS='StudioMMCSS';Foreground='StudioForeground';MouseAccel='StudioMouseAccel';PowerThrottle='StudioPowerThrottle';Visuals='StudioVisuals';Transparency='StudioTransparency';StartupDelay='StudioStartupDelay';Notifications='StudioNotifications';SearchSuggestions='StudioSearchSuggestions';OneDriveSync='StudioOneDriveSync';Copilot='StudioCopilot';NewsInterests='StudioNewsInterests';SuggestedContent='StudioSuggestedContent';ActivityHistory='StudioActivityHistory';EdgeStartup='StudioEdgeStartup';EdgeBackground='StudioEdgeBackground';ChromeBackground='StudioChromeBackground';DeliveryOptimization='StudioDeliveryOptimization';TelemetryPolicy='StudioTelemetryPolicy';HAGSOn='StudioHAGSOn';MPOOff='StudioMPOOff';Background='StudioBackground';Telemetry='StudioTelemetry'}
    $step=0
    foreach($m in $selected){$step++;Write-SOProgress ([math]::Min(95,[int](($step/[double]$selected.Count)*95))) ("Restaurando módulo: {0}" -f $m)
        if($catMap.ContainsKey($m)){Restore-SORegistry ([string]$catMap[$m])}
        switch($m){
            'Energy'{Restore-SOPower}
            'Hibernation'{Restore-SOHibernation}
            'DefenderScan'{Restore-SODefender}
            'DiagTrack'{Restore-SOServices -Names @('DiagTrack')}
            'WerSvc'{Restore-SOServices -Names @('WerSvc')}
            'TelemetryTasks'{Restore-SOTasks}
            'Indexing'{Restore-SOServices -Names @('WSearch')}
            'SysMainOff'{Restore-SOServices -Names @('SysMain')}
            'MemoryCompressionOff'{Restore-SOMemoryCompression}
            'Telemetry'{Restore-SOTasks;Restore-SOServices -Names @('DiagTrack','WerSvc')}
        }
    }
    Write-SOProgress 100 'Módulos selecionados restaurados';$s=Get-SOWindowsStudioStatus;$s['RestoredModules']=[string[]]$selected;return $s
}


function Get-SOModuleOriginalState {
    param([string]$Id)
    $targets=@(Get-SOWindowsStudioRegistryTargets|Where-Object {$_.Module -eq $Id})
    if($targets.Count -gt 0){
        $known=0;$same=0
        foreach($t in $targets){
            $file=Join-Path (Get-SORegDir) ((Get-SOHash (([string]$t.Path)+'|'+([string]$t.Name)))+'.json')
            if(-not(Test-Path -LiteralPath $file)){continue}
            try{$b=Get-Content $file -Raw -Encoding UTF8|ConvertFrom-Json;$known++;$cur=Get-SORegValue ([string]$t.Path) ([string]$t.Name);if([bool]$b.Exists){if(Test-SORegistryDataEqual ([string]$b.Kind) $cur $b.Data){$same++}}else{if($null -eq $cur){$same++}}}catch{}
        }
        if($known -eq 0){return $null}
        return ($known -eq $targets.Count -and $same -eq $targets.Count)
    }
    $svcMap=@{DiagTrack='DiagTrack';WerSvc='WerSvc';Indexing='WSearch';SysMainOff='SysMain'}
    if($svcMap.ContainsKey($Id)){
        $name=[string]$svcMap[$Id];$file=Join-Path (Get-SOSvcDir) ($name+'.json')
        if(-not(Test-Path -LiteralPath $file)){return $null}
        try{$b=Get-Content $file -Raw -Encoding UTF8|ConvertFrom-Json;$cur=Get-SOServiceStart $name;return ($null -ne $cur -and [int]$cur -eq [int]$b.Start)}catch{return $false}
    }
    if($Id -eq 'Hibernation'){
        $b=Get-SOSetting 'hibernation';if(-not $b){return $null};$cur=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled';try{return ([int]$cur -eq [int]$b.Enabled)}catch{return $false}
    }
    if($Id -eq 'Energy'){
        $b=Get-SOSetting 'powerplan';if(-not $b -or -not $b.PSObject.Properties['Original']){return $null};$cur=Get-SOActivePowerGuid;return ($cur -and $cur -ieq [string]$b.Original)
    }
    if($Id -eq 'DefenderScan'){
        $b=Get-SOSetting 'defender';if(-not $b){return $null};try{$cur=[int](Get-MpPreference -ErrorAction Stop).ScanAvgCPULoadFactor;return ($cur -eq [int]$b.ScanAvgCPULoadFactor)}catch{return $false}
    }
    return $null
}

function Get-SOWindowsStudioStatus {
    $session=Get-SOSetting 'windows_studio_session';$powerName=Get-SOActivePowerName;$hib=Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $rows=@()
    foreach($d in @(Get-SOWindowsStudioCatalog)){
        $id=[string]$d.Id;$applied=$false;$current='Padrão / não confirmado'
        $targets=@(Get-SOWindowsStudioRegistryTargets|Where-Object {$_.Module -eq $id})
        if($targets.Count -gt 0){$ok=0;foreach($t in $targets){$v=Get-SORegValue ([string]$t.Path) ([string]$t.Name);if(Test-SORegistryDataEqual ([string]$t.Type) $v $t.Desired){$ok++}};$applied=($ok -eq $targets.Count);$current=('{0}/{1} valor(es) no alvo' -f $ok,$targets.Count)}
        switch($id){
            'Energy'{$applied=([string]$powerName -like 'Super Optimizer Gaming*');$current=[string]$powerName}
            'DefenderScan'{try{$mp=Get-MpPreference -ErrorAction Stop;$current=('Scan CPU={0}%' -f [int]$mp.ScanAvgCPULoadFactor);$applied=([int]$mp.ScanAvgCPULoadFactor -eq 20)}catch{$current='Indisponível'}}
            'DiagTrack'{$v=Get-SOServiceStart 'DiagTrack';$applied=($v -eq 4);$current=('Start={0}' -f $v)}
            'WerSvc'{$v=Get-SOServiceStart 'WerSvc';$applied=($v -eq 4);$current=('Start={0}' -f $v)}
            'Indexing'{$v=Get-SOServiceStart 'WSearch';$applied=($v -eq 4);$current=('Start={0}' -f $v)}
            'SysMainOff'{$v=Get-SOServiceStart 'SysMain';$applied=($v -eq 4);$current=('Start={0}' -f $v)}
            'Hibernation'{$applied=($null -ne $hib -and [int]$hib -eq 0);$current=$(if($applied){'OFF'}else{'ON / padrão'})}
            'MemoryCompressionOff'{try{$ma=Get-MMAgent -ErrorAction Stop;$applied=(-not [bool]$ma.MemoryCompression);$current=$(if($applied){'OFF'}else{'ON'})}catch{$current='Indisponível'}}
            'TelemetryTasks'{$all=@((Get-SOConfig).telemetryTasks);$off=0;foreach($t in $all){try{$x=Get-ScheduledTask -TaskPath ([string]$t.path) -TaskName ([string]$t.name) -ErrorAction Stop;if($x.State -eq 'Disabled'){$off++}}catch{$off++}};$applied=($off -eq $all.Count);$current=('{0}/{1} desativadas/ausentes' -f $off,$all.Count)}
        }
        $origState=Get-SOModuleOriginalState $id;$state=if($applied){'ATIVO'}elseif($current -eq 'Indisponível' -or $current -like '*não presente*'){'NÃO SUPORTADO'}elseif($null -eq $origState -or [bool]$origState){'PADRÃO'}else{'DIFERENTE'};$rows += [pscustomobject]@{Id=$id;Name=[string]$d.Name;Group=[string]$d.Group;Risk=[string]$d.Risk;Applied=$applied;State=$state;Current=$current;Target=[string]$d.Target}
    }
    return [ordered]@{SessionUndoAvailable=($null -ne $session);SessionCreated=if($session -and $session.PSObject.Properties['Created']){[string]$session.Created}else{$null};SessionModules=if($session -and $session.PSObject.Properties['SelectedModules']){[string[]]@($session.SelectedModules)}else{[string[]]@()};SessionSnapshotVersion=if($session -and $session.PSObject.Properties['Version']){[int]$session.Version}else{$null};SessionScoped=if($session -and $session.PSObject.Properties['Version']){([int]$session.Version -ge 3)}else{$false};PowerPlan=$powerName;Modules=[object[]]$rows;Note='32 módulos granulares. VBS/HVCI e Hypervisor continuam na aba Virtualização; DNS continua separado.'}
}

function Invoke-SOWindowsStudioApplySelection {
    param([object[]]$Modules,[bool]$AutoRestorePoint=$true);$selected=@(Normalize-SOWindowsStudioModules $Modules);if($selected.Count -eq 0){throw 'Selecione pelo menos um módulo do Windows Studio.'}
    Write-SOProgress 3 'Preparando snapshot reversível da seleção'
    if($script:DryRun){[void](Save-SOWindowsStudioSnapshot -Modules $selected)}else{if($AutoRestorePoint -and -not(New-SORestorePoint 'Super Optimizer - Windows Studio')){throw 'Otimização cancelada porque o ponto de restauração solicitado não pôde ser criado.'};if(-not(Save-SOWindowsStudioSnapshot -Modules $selected)){throw 'Otimização cancelada: não foi possível salvar o snapshot da sessão para desfazer alterações.'}}
    for($i=0;$i -lt $selected.Count;$i++){$m=$selected[$i];$pct=10+[int]((($i+1)/[double]$selected.Count)*85);Write-SOProgress $pct ("Aplicando módulo: {0}" -f $m);Invoke-SOWindowsStudioModule -Module $m}
    Write-SOProgress 100 'Windows Studio concluído';$s=Get-SOWindowsStudioStatus;$s['AppliedModules']=[string[]]$selected;return $s
}

function Invoke-SOWindowsStudioApplyAll {
    param([bool]$AutoRestorePoint=$true)
    return (Invoke-SOWindowsStudioApplySelection -Modules (Get-SOWindowsStudioNonExperimentalModuleIds) -AutoRestorePoint $AutoRestorePoint)
}


function Restore-SOWindowsStudioSession {
    if($script:DryRun){Write-SOLog 'Desfaria a última sessão Windows Studio exatamente para o estado anterior' 'PLAN';return [ordered]@{Restored=$true;DryRun=$true;Errors=0}}
    $snap=Get-SOSetting 'windows_studio_session';if(-not $snap){throw 'Não existe uma sessão Windows Studio salva para desfazer.'};$errors=0
    Write-SOProgress 10 'Restaurando Registro da sessão';foreach($r in @($(if($snap.PSObject.Properties['Registry']){$snap.Registry}else{@()}))){if(-not(Restore-SORegistrySnapshotValue $r)){$errors++}}
    Write-SOProgress 35 'Restaurando serviços da sessão';foreach($s in @($(if($snap.PSObject.Properties['Services']){$snap.Services}else{@()}))){if(-not(Restore-SOServiceSessionState $s)){$errors++}}
    Write-SOProgress 50 'Restaurando tarefas da sessão';foreach($t in @($(if($snap.PSObject.Properties['Tasks']){$snap.Tasks}else{@()}))){if(-not(Restore-SOTaskSessionState $t)){$errors++}}
    if($snap.PSObject.Properties['Defender'] -and $snap.Defender -and [bool]$snap.Defender.Captured -and [bool]$snap.Defender.Valid){try{Set-MpPreference -ScanAvgCPULoadFactor ([int]$snap.Defender.ScanAvgCPULoadFactor) -ErrorAction Stop}catch{$errors++;Write-SOLog 'Falha restaurando Defender da sessão' 'WARN'}}
    if($snap.PSObject.Properties['MemoryCompression'] -and $snap.MemoryCompression -and [bool]$snap.MemoryCompression.Captured -and [bool]$snap.MemoryCompression.Valid){try{if([bool]$snap.MemoryCompression.Enabled){Enable-MMAgent -MemoryCompression -ErrorAction Stop}else{Disable-MMAgent -MemoryCompression -ErrorAction Stop}}catch{$errors++;Write-SOLog 'Falha restaurando MemoryCompression da sessão' 'WARN'}}
    $hibCaptured=$false;if($snap.PSObject.Properties['Hibernation'] -and $snap.Hibernation){$hibCaptured=if($snap.Hibernation.PSObject.Properties['Captured']){[bool]$snap.Hibernation.Captured}else{$true}}
    if($hibCaptured){Write-SOProgress 70 'Restaurando hibernação da sessão';try{if([bool]$snap.Hibernation.Exists){$mode=if([int]$snap.Hibernation.Enabled -eq 1){'on'}else{'off'};if(-not(Invoke-SOPowerCfg -Arguments @('/hibernate',$mode) -Label 'restaurar hibernação da sessão' -Optional)){$errors++}}}catch{$errors++}}
    $energyCaptured=if($snap.PSObject.Properties['EnergyCaptured']){[bool]$snap.EnergyCaptured}else{$true}
    if($energyCaptured){Write-SOProgress 88 'Restaurando plano de energia ativo e estado do plano Gaming';try{if($snap.ActivePowerGuid){if(-not(Invoke-SOPowerCfg -Arguments @('/setactive',[string]$snap.ActivePowerGuid) -Label 'reativar plano anterior da sessão' -Optional)){throw 'Não foi possível reativar o plano anterior.'}};$afterPower=Get-SOSetting 'powerplan';$beforePower=if($snap.PSObject.Properties['PowerPlanState']){$snap.PowerPlanState}else{$null};$afterGaming=if($afterPower -and $afterPower.PSObject.Properties['Gaming']){[string]$afterPower.Gaming}else{$null};$beforeGaming=if($beforePower -and $beforePower.PSObject.Properties['Gaming']){[string]$beforePower.Gaming}else{$null};if($afterGaming -and $afterGaming -ne $beforeGaming){$active=Get-SOActivePowerGuid;if(-not $active -or $active -ine $afterGaming){[void](Invoke-SOPowerCfg -Arguments @('/delete',$afterGaming) -Label 'remover plano criado na sessão' -Optional)}};$powerFile=Join-Path (Get-SOSettingsDir) 'powerplan.json';if($null -ne $beforePower){if(-not(Save-SOSetting 'powerplan' $beforePower)){$errors++}}else{Remove-Item -LiteralPath $powerFile -Force -ErrorAction SilentlyContinue}}catch{$errors++;Write-SOLog ("Falha restaurando estado de energia da sessão: {0}" -f $_.Exception.Message) 'WARN'}}
    if($errors -eq 0){Remove-Item -LiteralPath (Join-Path (Get-SOSettingsDir) 'windows_studio_session.json') -Force -ErrorAction SilentlyContinue}
    Write-SOProgress 100 'Desfazer sessão concluído';if($errors -gt 0){Write-SOLog ("A sessão foi restaurada com {0} aviso(s). Snapshot foi preservado para nova tentativa." -f $errors) 'WARN'}
    return [ordered]@{Restored=($errors -eq 0);Errors=$errors;SnapshotPreserved=($errors -gt 0);Modules=if($snap.PSObject.Properties['SelectedModules']){[string[]]@($snap.SelectedModules)}else{[string[]]@()}}
}

function Restore-SOWindowsStudioOriginal {
    foreach($cat in @('StudioGameMode','StudioGameDVR','StudioMMCSS','StudioForeground','StudioMouseAccel','StudioPowerThrottle','StudioVisuals','StudioTransparency','StudioStartupDelay','StudioNotifications','StudioSearchSuggestions','StudioOneDriveSync','StudioCopilot','StudioNewsInterests','StudioSuggestedContent','StudioActivityHistory','StudioEdgeStartup','StudioEdgeBackground','StudioChromeBackground','StudioDeliveryOptimization','StudioTelemetryPolicy','StudioHAGSOn','StudioMPOOff','StudioBackground','StudioTelemetry')){Restore-SORegistry $cat}
    Restore-SOTasks;Restore-SOServices -Names @('DiagTrack','WerSvc','WSearch','SysMain');Restore-SOHibernation;Restore-SOPower;Restore-SODefender;Restore-SOMemoryCompression
    return (Get-SOWindowsStudioStatus)
}

# =============================================================================
# DNS LATENCY LAB - benchmark nativo, aplicação e restauração exata
# =============================================================================
function Get-SODnsProviders {
    return @(
        [pscustomobject]@{Name='Cloudflare';Primary='1.1.1.1';Secondary='1.0.0.1'},
        [pscustomobject]@{Name='Google';Primary='8.8.8.8';Secondary='8.8.4.4'},
        [pscustomobject]@{Name='Quad9';Primary='9.9.9.9';Secondary='149.112.112.112'},
        [pscustomobject]@{Name='AdGuard Unfiltered';Primary='94.140.14.140';Secondary='94.140.14.141'}
    )
}

function Get-SOActiveDnsAdapters {
    # Arrays simples: evita o binder error de Generic.List + @() observado no Windows PowerShell 5.1.
    $rows=@()
    try{
        $cfgs=@(Get-NetIPConfiguration -ErrorAction Stop|Where-Object {$_.IPv4DefaultGateway -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up'})
        $physical=@($cfgs|Where-Object {try{(Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction Stop).HardwareInterface}catch{$false}})
        if($physical.Count -gt 0){$cfgs=$physical}
        foreach($c in $cfgs){
            try{
                $a=Get-NetAdapter -InterfaceIndex $c.InterfaceIndex -ErrorAction Stop
                $dns=@((Get-DnsClientServerAddress -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
                $rows += [pscustomobject]@{Alias=[string]$a.Name;InterfaceIndex=[int]$a.InterfaceIndex;InterfaceGuid=[string]$a.InterfaceGuid;Servers=[string[]]$dns}
            }catch{}
        }
    }catch{}
    return [object[]]$rows
}

function Get-SODnsStatus {
    $adapters=@(Get-SOActiveDnsAdapters)
    return [ordered]@{Adapters=@($adapters|ForEach-Object {[ordered]@{Alias=$_.Alias;InterfaceIndex=$_.InterfaceIndex;Servers=@($_.Servers)}});OriginalBackupAvailable=($null -ne (Get-SOSetting 'dns_original'));LastBenchmark=(Get-SOSetting 'dns_last_benchmark')}
}

function Backup-SODnsOriginal {
    if($null -ne (Get-SOSetting 'dns_original')){return $true}
    $items=@()
    foreach($a in @(Get-SOActiveDnsAdapters)){
        $auto=$true
        try{
            $guid=([guid]$a.InterfaceGuid).ToString('B')
            $rp="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
            $ns=(Get-ItemProperty -LiteralPath $rp -Name NameServer -ErrorAction SilentlyContinue).NameServer
            $auto=[string]::IsNullOrWhiteSpace([string]$ns)
        }catch{}
        $items += [pscustomobject]@{Alias=[string]$a.Alias;InterfaceGuid=[string]$a.InterfaceGuid;Automatic=[bool]$auto;Servers=[string[]]@($a.Servers)}
    }
    if($items.Count -eq 0){Write-SOLog 'Nenhum adaptador ativo com gateway foi encontrado para backup de DNS.' 'WARN';return $false}
    return (Save-SOSetting 'dns_original' ([ordered]@{Created=(Get-Date).ToString('o');Adapters=[object[]]$items}))
}

function New-SODnsQueryPacket {
    param([string]$Domain,[UInt16]$Id)
    $bytes=New-Object System.Collections.Generic.List[byte]
    $bytes.Add([byte](($Id -shr 8) -band 0xFF));$bytes.Add([byte]($Id -band 0xFF))
    foreach($b in @(0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00)){$bytes.Add([byte]$b)}
    foreach($label in $Domain.Trim('.').Split('.')){
        $raw=[Text.Encoding]::ASCII.GetBytes($label);$bytes.Add([byte]$raw.Length);foreach($b in $raw){$bytes.Add($b)}
    }
    foreach($b in @(0x00,0x00,0x01,0x00,0x01)){$bytes.Add([byte]$b)}
    return $bytes.ToArray()
}

function Invoke-SODnsProbe {
    param([string]$Server,[string]$Domain,[int]$TimeoutMs=1000)
    $client=$null
    try{
        $id=[UInt16](Get-Random -Minimum 1 -Maximum 65534)
        $packet=New-SODnsQueryPacket -Domain $Domain -Id $id
        $client=New-Object System.Net.Sockets.UdpClient
        $client.Client.ReceiveTimeout=$TimeoutMs;$client.Client.SendTimeout=$TimeoutMs
        $endpoint=[System.Net.IPEndPoint]::new([Net.IPAddress]::Parse($Server),53)
        $client.Connect($endpoint)
        $sw=[Diagnostics.Stopwatch]::StartNew();[void]$client.Send($packet,$packet.Length)
        $remote=New-Object System.Net.IPEndPoint ([Net.IPAddress]::Any),0
        $resp=$client.Receive([ref]$remote);$sw.Stop()
        if($resp.Length -lt 12){throw 'Resposta DNS curta'}
        $rid=[UInt16](($resp[0] -shl 8) -bor $resp[1]);if($rid -ne $id){throw 'ID da resposta DNS não confere'}
        $rcode=$resp[3] -band 0x0F;if($rcode -ne 0){throw ("DNS RCODE={0}" -f $rcode)}
        return [ordered]@{Success=$true;Ms=[math]::Round($sw.Elapsed.TotalMilliseconds,1)}
    }catch{return [ordered]@{Success=$false;Ms=$null;Error=$_.Exception.Message}}
    finally{if($client){$client.Close();$client.Dispose()}}
}

function Get-SOMedian {
    param([double[]]$Values)
    $v=@($Values|Sort-Object);if($v.Count -eq 0){return $null};$mid=[int][math]::Floor($v.Count/2)
    if(($v.Count % 2)-eq 1){return [math]::Round([double]$v[$mid],1)}
    return [math]::Round(([double]$v[$mid-1]+[double]$v[$mid])/2,1)
}

function Invoke-SODnsBenchmark {
    $providers=@(Get-SODnsProviders)
    if($script:DryRun){
        $rows=@($providers|ForEach-Object {[ordered]@{Provider=$_.Name;Server=$_.Primary;MedianMs=0;AverageMs=0;Success='DRY-RUN';ReliabilityPercent=100;Eligible=$true}})
        return [ordered]@{BestProvider='Cloudflare';BestMedianMs=0;Results=$rows;Note='DRY-RUN: nenhuma consulta DNS foi enviada.'}
    }
    $tests=@('microsoft.com','github.com','cloudflare.com','google.com','steampowered.com','xbox.com')
    $targets=New-Object System.Collections.Generic.List[object]
    $current=@(Get-SOActiveDnsAdapters|Select-Object -First 1)
    if($current.Count -and @($current[0].Servers).Count){
        $ip=[string]$current[0].Servers[0]
        if($ip){[void]$targets.Add([pscustomobject]@{Name='DNS atual';Primary=$ip;Secondary='';Eligible=$false})}
    }
    foreach($p in $providers){if(-not(@($targets|Where-Object {$_.Primary -eq $p.Primary}).Count)){[void]$targets.Add([pscustomobject]@{Name=$p.Name;Primary=$p.Primary;Secondary=$p.Secondary;Eligible=$true})}}
    $rows=New-Object System.Collections.Generic.List[object]
    $idx=0
    foreach($p in $targets){
        $idx++;Write-SOProgress ([int](5+85*$idx/[Math]::Max(1,$targets.Count))) ("Testando DNS: {0}" -f $p.Name)
        $times=New-Object System.Collections.Generic.List[double];$attempts=0
        foreach($domain in $tests){$attempts++;$r=Invoke-SODnsProbe -Server $p.Primary -Domain $domain -TimeoutMs 1100;if([bool]$r.Success){[void]$times.Add([double]$r.Ms)}}
        $reliability=[math]::Round(100*$times.Count/[math]::Max(1,$attempts),0)
        $median=if($times.Count){Get-SOMedian ([double[]]$times.ToArray())}else{$null}
        $avg=if($times.Count){[math]::Round((($times|Measure-Object -Average).Average),1)}else{$null}
        [void]$rows.Add([ordered]@{Provider=$p.Name;Server=$p.Primary;MedianMs=$median;AverageMs=$avg;Success=("{0}/{1}" -f $times.Count,$attempts);ReliabilityPercent=$reliability;Eligible=([bool]$p.Eligible -and $reliability -ge 70)})
    }
    $best=@($rows|Where-Object {$_.Eligible -and $null -ne $_.MedianMs}|Sort-Object {[double]$_.MedianMs}|Select-Object -First 1)
    $bestName=if($best.Count){[string]$best[0].Provider}else{$null};$bestMs=if($best.Count){$best[0].MedianMs}else{$null}
    $result=[ordered]@{TestedAt=(Get-Date).ToString('o');BestProvider=$bestName;BestMedianMs=$bestMs;Results=@($rows);Note='Mede tempo de resolução DNS. Não mede nem promete reduzir o ping do servidor do jogo depois da conexão estabelecida.'}
    [void](Save-SOSetting 'dns_last_benchmark' $result)
    Write-SOProgress 100 'Benchmark DNS concluído'
    return $result
}

function Set-SODnsProvider {
    param([Parameter(Mandatory=$true)][string]$Provider)
    $p=@(Get-SODnsProviders|Where-Object {$_.Name -eq $Provider}|Select-Object -First 1)
    if($p.Count -eq 0){throw ("Provedor DNS desconhecido: {0}" -f $Provider)}
    if($script:DryRun){Write-SOLog ("Aplicaria DNS {0}: {1}, {2}" -f $Provider,$p[0].Primary,$p[0].Secondary) 'PLAN';return [ordered]@{Provider=$Provider;Changed=0;DryRun=$true}}
    if(-not(Backup-SODnsOriginal)){throw 'DNS não foi alterado porque o estado original não pôde ser salvo.'}
    $changed=0
    foreach($a in @(Get-SOActiveDnsAdapters)){
        Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses @($p[0].Primary,$p[0].Secondary) -ErrorAction Stop
        $now=@((Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
        if($now.Count -lt 1 -or [string]$now[0] -ne [string]$p[0].Primary){throw ("DNS não pôde ser confirmado em {0}" -f $a.Alias)}
        $changed++
    }
    if($changed -eq 0){throw 'Nenhum adaptador de rede ativo pôde ser configurado.'}
    $code=Invoke-SOExternal 'ipconfig.exe' @('/flushdns') 'Flush DNS após troca' 90 5
    if($code -ne 0){Write-SOLog 'DNS foi aplicado, mas o cache DNS não pôde ser limpo.' 'WARN'}
    return [ordered]@{Provider=$Provider;Primary=$p[0].Primary;Secondary=$p[0].Secondary;ChangedAdapters=$changed}
}

function Restore-SODnsOriginal {
    if($script:DryRun){Write-SOLog 'Restauraria DNS original por adaptador' 'PLAN';return [ordered]@{RestoredAdapters=0;Errors=0;DryRun=$true;BackupPreserved=$false}}
    $state=Get-SOSetting 'dns_original'
    if(-not $state){throw 'Não existe backup de DNS original para restaurar.'}
    $restored=0;$errors=0
    foreach($s in @($state.Adapters)){
        try{
            $adapter=@(Get-NetAdapter -ErrorAction Stop|Where-Object {[string]$_.InterfaceGuid -eq [string]$s.InterfaceGuid}|Select-Object -First 1)
            if($adapter.Count -eq 0){$errors++;Write-SOLog ("Adaptador do backup não está presente: {0}. Backup DNS será preservado." -f $s.Alias) 'WARN';continue}
            if([bool]$s.Automatic -or @($s.Servers).Count -eq 0){Set-DnsClientServerAddress -InterfaceIndex $adapter[0].InterfaceIndex -ResetServerAddresses -ErrorAction Stop}
            else{Set-DnsClientServerAddress -InterfaceIndex $adapter[0].InterfaceIndex -ServerAddresses @($s.Servers) -ErrorAction Stop}
            $restored++
        }catch{$errors++;Write-SOLog ("Falha restaurando DNS em {0}: {1}" -f $s.Alias,$_.Exception.Message) 'WARN'}
    }
    [void](Invoke-SOExternal 'ipconfig.exe' @('/flushdns') 'Flush DNS após restauração' 90 5)
    if($errors -eq 0){Remove-Item -LiteralPath (Join-Path (Get-SOSettingsDir) 'dns_original.json') -Force -ErrorAction SilentlyContinue}
    return [ordered]@{RestoredAdapters=$restored;Errors=$errors;BackupPreserved=($errors -gt 0)}
}

function Invoke-SODnsApplyBest {
    $bench=Invoke-SODnsBenchmark
    if(-not $bench.BestProvider){throw 'Nenhum provedor público atingiu confiabilidade suficiente no benchmark.'}
    $applied=Set-SODnsProvider -Provider ([string]$bench.BestProvider)
    return [ordered]@{BestProvider=$bench.BestProvider;BestMedianMs=$bench.BestMedianMs;Applied=$applied;Results=$bench.Results;Note=$bench.Note}
}

function Test-SORamNativeApiAvailable {
    try{return [bool](Initialize-SORamNativeApi)}catch{return $false}
}

function Get-SORamCleanerPath {
    return (Join-Path $script:AppRoot 'Tools\EmptyStandbyList.exe')
}

function Get-SORamCleanerValidation {
    $tool=Get-SORamCleanerPath
    if(-not(Test-Path -LiteralPath $tool -PathType Leaf)){
        return [ordered]@{Available=$false;Valid=$false;Path=$tool;Hash=$null;Signature='Absent';Reason='Arquivo não encontrado'}
    }
    try{
        $fs=[IO.File]::Open($tool,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            if($fs.Length -lt 2){throw 'Arquivo curto demais para ser um executável PE.'}
            $b1=$fs.ReadByte();$b2=$fs.ReadByte()
        }finally{$fs.Dispose()}
        if($b1 -ne 0x4D -or $b2 -ne 0x5A){throw 'Cabeçalho MZ ausente; o arquivo não parece ser um executável Windows válido.'}
        $hash=(Get-FileHash -LiteralPath $tool -Algorithm SHA256 -ErrorAction Stop).Hash
        $sig=Get-AuthenticodeSignature -LiteralPath $tool -ErrorAction Stop
        if([string]$sig.Status -eq 'HashMismatch'){throw 'A assinatura Authenticode indica HashMismatch.'}
        return [ordered]@{Available=$true;Valid=$true;Path=$tool;Hash=$hash;Signature=[string]$sig.Status;Reason='OK'}
    }catch{
        return [ordered]@{Available=$true;Valid=$false;Path=$tool;Hash=$null;Signature='Invalid';Reason=$_.Exception.Message}
    }
}

function Test-SORamExternalFallbackAvailable {
    $v=Get-SORamCleanerValidation
    return ([bool]$v.Valid)
}

function Get-SORamCleanerMode {
    if(Test-SORamNativeApiAvailable){return 'NATIVO'}
    if(Test-SORamExternalFallbackAvailable){return 'EXTERNO (FALLBACK)'}
    return 'INDISPONÍVEL'
}

function Test-SORamCleanerAvailable {
    return ((Get-SORamCleanerMode) -ne 'INDISPONÍVEL')
}

function Write-SORamCleanerIdentity {
    $v=Get-SORamCleanerValidation
    if(-not [bool]$v.Available){return}
    if(-not [bool]$v.Valid){Write-SOLog ("Fallback externo de RAM inválido: {0}" -f $v.Reason) 'WARN';return}
    Write-SOLog ("Fallback externo de RAM: {0} | SHA-256={1}" -f $v.Path,$v.Hash) 'INFO'
    if([string]$v.Signature -eq 'Valid'){Write-SOLog 'Assinatura do fallback externo de RAM: Valid' 'OK'}
    else{Write-SOLog ("Assinatura do fallback externo de RAM: {0}. Confirme a origem antes de usar." -f $v.Signature) 'WARN'}
}

function Invoke-SORamNativeCommand {
    param([Parameter(Mandatory=$true)][ValidateSet('workingsets','modifiedpagelist','standbylist')][string]$Command)

    $map=@{workingsets=2;modifiedpagelist=3;standbylist=4}
    if($script:DryRun){
        Write-SOLog ("RAM nativa / SystemMemoryListInformation: {0} (comando {1})" -f $Command,$map[$Command]) 'PLAN'
        return
    }

    if(-not(Initialize-SORamNativeApi)){throw 'A API nativa de gerenciamento de listas de memória não pôde ser carregada.'}
    $priv=[SuperOptimizerNative.MemoryApi]::EnableProfilePrivilege()
    if($priv -ne 0){throw ("Não foi possível habilitar SeProfileSingleProcessPrivilege. Win32={0}" -f $priv)}
    $status=[SuperOptimizerNative.MemoryApi]::ExecuteMemoryListCommand([int]$map[$Command])
    if($status -ne 0){
        $hex=('0x{0:X8}' -f ([uint32]$status))
        throw ("NtSetSystemInformation falhou em {0}. NTSTATUS={1}" -f $Command,$hex)
    }
    Write-SOLog ("RAM nativa executada: {0}" -f $Command) 'OK'
}

function Invoke-SORamExternalFallbackCommand {
    param([Parameter(Mandatory=$true)][ValidateSet('workingsets','modifiedpagelist','standbylist')][string]$Command)

    if($script:DryRun){
        Write-SOLog ("Fallback opcional EmptyStandbyList.exe {0}" -f $Command) 'PLAN'
        return
    }

    $v=Get-SORamCleanerValidation
    if(-not [bool]$v.Available){throw 'Fallback externo EmptyStandbyList.exe não está instalado.'}
    if(-not [bool]$v.Valid){throw ("Fallback externo recusado pela validação estrutural: {0}" -f $v.Reason)}
    Write-SORamCleanerIdentity

    $proc=Start-Process -FilePath ([string]$v.Path) -ArgumentList $Command -WindowStyle Hidden -PassThru
    if(-not $proc.WaitForExit(30000)){
        try{$proc.Kill()}catch{}
        throw ("Fallback externo {0} excedeu 30 segundos e foi interrompido." -f $Command)
    }
    if($proc.ExitCode -ne 0){throw ("Fallback externo {0} terminou com código {1}" -f $Command,$proc.ExitCode)}
    Write-SOLog ("Fallback externo de RAM executado: {0}" -f $Command) 'OK'
}

function Invoke-SORamCleanerCommand {
    param([Parameter(Mandatory=$true)][ValidateSet('workingsets','modifiedpagelist','standbylist')][string]$Command)

    if($script:DryRun){
        Invoke-SORamNativeCommand $Command
        return
    }

    try{
        Invoke-SORamNativeCommand $Command
        return
    }catch{
        $nativeError=$_.Exception.Message
        $fallback=Get-SORamCleanerValidation
        if([bool]$fallback.Valid){
            Write-SOLog ("Método nativo de RAM falhou ({0}). Tentando fallback externo validado." -f $nativeError) 'WARN'
            Invoke-SORamExternalFallbackCommand $Command
            return
        }
        throw ("Falha na limpeza de RAM pelo método nativo: {0}. O fallback externo é opcional e não está disponível/validado." -f $nativeError)
    }
}

function Invoke-SORamStandbyClean {
    param([bool]$Force=$false)

    $before=Get-SORamInfo
    $freePercent=if([double]$before.TotalGB -gt 0){[math]::Round(([double]$before.FreeGB/[double]$before.TotalGB)*100,1)}else{0}

    if(-not $Force -and $freePercent -ge 25){
        $msg=("Limpeza de Standby não necessária: {0} GB livres ({1}%). O Windows pode reutilizar esse cache automaticamente." -f $before.FreeGB,$freePercent)
        Write-SOLog $msg 'INFO'
        return [ordered]@{Executed=$false;Skipped=$true;Method=(Get-SORamCleanerMode);Message=$msg;Before=$before;After=$before}
    }

    if($script:DryRun){
        Invoke-SORamCleanerCommand 'standbylist'
        return [ordered]@{Executed=$true;Skipped=$false;Method='NATIVO';Message='DRY-RUN: limpeza de Standby RAM planejada';Before=$before;After=$before}
    }

    if(-not(Test-SORamCleanerAvailable)){throw 'Nenhum método de limpeza de RAM está disponível neste Windows.'}

    Write-SOProgress 20 'Preparando limpeza de Standby RAM'
    Write-SOLog ("Standby RAM manual iniciada. Método preferencial=NATIVO. RAM livre antes: {0} GB ({1}%)." -f $before.FreeGB,$freePercent) 'INFO'
    Invoke-SORamCleanerCommand 'standbylist'
    Start-Sleep -Milliseconds 700
    $after=Get-SORamInfo
    Write-SOProgress 100 'Standby RAM concluída' -NoLog
    Write-SOLog ("Standby RAM concluída. RAM livre depois: {0} GB." -f $after.FreeGB) 'OK'

    return [ordered]@{Executed=$true;Skipped=$false;Method=(Get-SORamCleanerMode);Message=("Standby RAM limpa. Livre: {0} GB -> {1} GB" -f $before.FreeGB,$after.FreeGB);Before=$before;After=$after}
}

function Invoke-SORamFullClean {
    param([bool]$Force=$false)

    if(-not $Force -and -not $script:DryRun){throw 'A limpeza completa de RAM exige confirmação explícita.'}
    $before=Get-SORamInfo

    if($script:DryRun){
        Invoke-SORamCleanerCommand 'workingsets'
        Invoke-SORamCleanerCommand 'modifiedpagelist'
        Invoke-SORamCleanerCommand 'standbylist'
        return [ordered]@{Executed=$true;Method='NATIVO';Message='DRY-RUN: limpeza completa de RAM planejada';Before=$before;After=$before}
    }

    if(-not(Test-SORamCleanerAvailable)){throw 'Nenhum método de limpeza de RAM está disponível neste Windows.'}

    Write-SOLog 'Limpeza COMPLETA de RAM iniciada manualmente pelo método nativo quando disponível. Pode causar recarregamentos ou stutter temporário.' 'WARN'
    Write-SOProgress 15 'Esvaziando working sets'
    Invoke-SORamCleanerCommand 'workingsets'
    Write-SOProgress 45 'Processando modified page list'
    Invoke-SORamCleanerCommand 'modifiedpagelist'
    Write-SOProgress 75 'Limpando Standby RAM'
    Invoke-SORamCleanerCommand 'standbylist'

    Start-Sleep -Milliseconds 900
    $after=Get-SORamInfo
    Write-SOProgress 100 'Limpeza completa de RAM concluída' -NoLog
    Write-SOLog ("Limpeza completa de RAM concluída. Livre: {0} GB -> {1} GB." -f $before.FreeGB,$after.FreeGB) 'OK'

    return [ordered]@{Executed=$true;Method=(Get-SORamCleanerMode);Message=("Limpeza completa concluída. Livre: {0} GB -> {1} GB" -f $before.FreeGB,$after.FreeGB);Before=$before;After=$after}
}

function Get-SORamInfo {
    try{$os=Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop}
    catch{throw ("Não foi possível consultar a memória do Windows: {0}" -f $_.Exception.Message)}
    $total=[math]::Round($os.TotalVisibleMemorySize/1MB,2);$free=[math]::Round($os.FreePhysicalMemory/1MB,2)
    [ordered]@{TotalGB=$total;UsedGB=[math]::Round($total-$free,2);FreeGB=$free;UsedPercent=if($total -gt 0){[math]::Round((($total-$free)/$total)*100,1)}else{0}}
}


# ======================== V3.8 — STATE INTELLIGENCE ========================
function ConvertTo-SOStateText {
    param($Value)
    if($null -eq $Value){return '<ausente>'}
    if($Value -is [System.Array]){return (@($Value)|ForEach-Object {[string]$_}) -join ','}
    return [string]$Value
}

function Get-SOChangeSnapshot {
    $reg=[ordered]@{}
    $targets=@(Get-SOWindowsStudioRegistryTargets)
    $targets += @(
        [pscustomobject]@{Path='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard';Name='EnableVirtualizationBasedSecurity'},
        [pscustomobject]@{Path='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity';Name='Enabled'}
    )
    foreach($t in $targets){
        $key=([string]$t.Path+'|'+[string]$t.Name)
        if(-not $reg.Contains($key)){$reg[$key]=ConvertTo-SOStateText (Get-SORegValue ([string]$t.Path) ([string]$t.Name))}
    }
    $services=[ordered]@{}
    $svcNames=@((Get-SOConfig).services|ForEach-Object {[string]$_.name})+@('SysMain','wuauserv','BITS','DoSvc')
    foreach($n in @($svcNames|Sort-Object -Unique)){
        $svc=Get-Service $n -ErrorAction SilentlyContinue
        if($svc){$services[$n]=('Start={0};Running={1}' -f (ConvertTo-SOStateText (Get-SOServiceStart $n)),($svc.Status -eq 'Running'))}
        else{$services[$n]='<não presente>'}
    }
    $tasks=[ordered]@{}
    foreach($t in @((Get-SOConfig).telemetryTasks)){
        $k=([string]$t.path+[string]$t.name)
        try{$x=Get-ScheduledTask -TaskPath ([string]$t.path) -TaskName ([string]$t.name) -ErrorAction Stop;$tasks[$k]=[string]$x.State}catch{$tasks[$k]='<não presente>'}
    }
    $defender='<indisponível>'
    try{$defender='ScanAvgCPU='+[string](Get-MpPreference -ErrorAction Stop).ScanAvgCPULoadFactor}catch{}
    return [ordered]@{
        Captured=(Get-Date).ToString('o')
        Profile=(Get-SOProfileMatch)
        PowerPlan=(Get-SOActivePowerName)
        Hibernation=ConvertTo-SOStateText (Get-SORegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled')
        Hypervisor=ConvertTo-SOStateText (Get-SOHypervisorLaunchType)
        Defender=$defender
        Registry=[pscustomobject]$reg
        Services=[pscustomobject]$services
        Tasks=[pscustomobject]$tasks
    }
}

function Compare-SOChangeSnapshots {
    param($Before,$After)
    $changes=New-Object System.Collections.Generic.List[object]
    foreach($p in @('Profile','PowerPlan','Hibernation','Hypervisor','Defender')){
        $a=ConvertTo-SOStateText $Before.$p;$b=ConvertTo-SOStateText $After.$p
        if($a -ne $b){[void]$changes.Add([pscustomobject]@{Category='Sistema';Item=$p;Before=$a;After=$b})}
    }
    foreach($section in @('Registry','Services','Tasks')){
        $keys=New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        if($Before.$section){foreach($p in $Before.$section.PSObject.Properties){[void]$keys.Add([string]$p.Name)}}
        if($After.$section){foreach($p in $After.$section.PSObject.Properties){[void]$keys.Add([string]$p.Name)}}
        foreach($k in $keys){
            $av='<ausente>';$bv='<ausente>'
            if($Before.$section -and $Before.$section.PSObject.Properties[$k]){$av=ConvertTo-SOStateText $Before.$section.$k}
            if($After.$section -and $After.$section.PSObject.Properties[$k]){$bv=ConvertTo-SOStateText $After.$section.$k}
            if($av -ne $bv){[void]$changes.Add([pscustomobject]@{Category=$section;Item=$k;Before=$av;After=$bv})}
        }
    }
    return [object[]]$changes.ToArray()
}

function Add-SOHistoryEntry {
    param([string]$Action,[bool]$Success,[string]$Message,[int]$Warnings,[string]$LogPath,$Comparison,[bool]$RebootRecommended=$false)
    if($script:DryRun){return}
    $file=Get-SOHistoryFile;$items=@()
    if(Test-Path -LiteralPath $file){try{$items=@(Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json)}catch{$items=@()}}
    $logRelative=$null
    try{
        $stateBase=[IO.Path]::GetFullPath($script:StateRoot).TrimEnd('\')
        $logFull=[IO.Path]::GetFullPath([string]$LogPath)
        if($logFull.StartsWith($stateBase+'\',[StringComparison]::OrdinalIgnoreCase)){$logRelative=$logFull.Substring($stateBase.Length).TrimStart('\')}
    }catch{}
    $entry=[ordered]@{Id=[guid]::NewGuid().ToString('N');Timestamp=(Get-Date).ToString('o');Action=$Action;Success=$Success;Message=$Message;Warnings=$Warnings;RebootRecommended=$RebootRecommended;LogPath=$LogPath;LogRelative=$logRelative;Changes=if($Comparison){[object[]]@($Comparison)}else{[object[]]@()}}
    $items=@($items)+[pscustomobject]$entry
    if($items.Count -gt 200){$items=@($items|Select-Object -Last 200)}
    $tmp=$file+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{$items|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop;[void](Get-Content $tmp -Raw -Encoding UTF8|ConvertFrom-Json);Move-Item $tmp $file -Force}catch{Remove-Item $tmp -Force -ErrorAction SilentlyContinue;Write-SOLog ('Histórico não pôde ser salvo: '+$_.Exception.Message) 'WARN'}
}

function Get-SOHistoryData {
    $file=Get-SOHistoryFile
    if(-not(Test-Path -LiteralPath $file)){return [object[]]@()}
    try{return [object[]]@(Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json|Sort-Object Timestamp -Descending)}catch{return [object[]]@()}
}

function Get-SOStateManager {
    $audit=Get-SOStateAudit
    $files=@(Get-ChildItem -LiteralPath $script:MachineRoot -File -Recurse -ErrorAction SilentlyContinue)
    $backupFiles=@($files|Where-Object {$_.DirectoryName -match '\\(Registry|Services|Tasks|Settings)$'})
    $first=$null;if($backupFiles.Count -gt 0){$first=($backupFiles|Sort-Object CreationTime|Select-Object -First 1).CreationTime.ToString('o')}
    $size=[int64]0;foreach($f in $files){$size += [int64]$f.Length}
    $cats=[ordered]@{}
    foreach($name in @('Registry','Services','Tasks','Settings','Maintenance','PerGame','Reports','History','Profiles')){$cats[$name]=@(Get-ChildItem -LiteralPath (Join-Path $script:MachineRoot $name) -File -Recurse -ErrorAction SilentlyContinue).Count}
    $machine=$null;try{$machine=Get-Content (Join-Path $script:MachineRoot 'machine.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
    return [ordered]@{MachineId=$script:MachineId;ComputerName=$env:COMPUTERNAME;FirstBackup=$first;TotalSizeMB=[math]::Round($size/1MB,2);Health=$audit.Health;Issues=$audit.IssuesCount;Categories=$cats;RollbackAvailable=($backupFiles.Count -gt 0);Portable=$true;PortableNote='A pasta State pode acompanhar o programa. Os backups são isolados por MachineGuid, evitando aplicar o estado de uma máquina em outra.';Machine=$machine}
}

function Save-SOPostRebootMarker {
    param([string]$Action,$Result)
    if($script:DryRun){return}
    $boot=$null;try{$boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('o')}catch{}
    $expected=$null
    try{if($Result -and $Result.Data -and $Result.Data.PSObject.Properties['DetectedProfile']){$expected=[string]$Result.Data.DetectedProfile}}catch{}
    [void](Save-SOSetting 'post_reboot_pending' ([ordered]@{Action=$Action;AppliedAt=(Get-Date).ToString('o');BootAtApply=$boot;ExpectedProfile=$expected}))
}

function Get-SOPostRebootStatus {
    $m=Get-SOSetting 'post_reboot_pending'
    if(-not $m){return [ordered]@{Pending=$false}}
    $boot=$null;try{$boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime}catch{}
    $rebooted=$false;try{$rebooted=($boot -and $boot -gt [datetime]$m.AppliedAt)}catch{}
    $current=Get-SOProfileMatch
    return [ordered]@{Pending=(-not $rebooted);RebootDetected=$rebooted;Action=[string]$m.Action;AppliedAt=[string]$m.AppliedAt;ExpectedProfile=[string]$m.ExpectedProfile;DetectedProfile=$current;PowerPlan=(Get-SOActivePowerName);Hypervisor=(Get-SOHypervisorLaunchType);Verified=($rebooted -and ([string]::IsNullOrWhiteSpace([string]$m.ExpectedProfile) -or $current -eq [string]$m.ExpectedProfile))}
}

function Get-SOHealthSummary {
    $s=Get-SOStatus;$a=Get-SOStateAudit
    $blocks=@(
        [pscustomobject]@{Name='State / backups';State=if($a.Health -eq 'OK'){'OK'}else{'ATENÇÃO'};Detail=('{0} arquivo(s), {1} problema(s)' -f $a.FilesChecked,$a.IssuesCount)},
        [pscustomobject]@{Name='Reinício pendente';State=if([bool]$s.RebootPending){'ATENÇÃO'}else{'OK'};Detail=if([bool]$s.RebootPending){'Windows solicita reinício'}else{'Nenhum reinício pendente detectado'}},
        [pscustomobject]@{Name='RAM';State=if([double]$s.RAMUsedPercent -ge 85){'ATENÇÃO'}else{'OK'};Detail=('{0}% em uso • {1} GB livre' -f $s.RAMUsedPercent,$s.RAMFreeGB)},
        [pscustomobject]@{Name='Armazenamento';State=if([double]$s.DiskFreePercent -lt 15){'ATENÇÃO'}else{'OK'};Detail=('{0}% livre • {1} GB' -f $s.DiskFreePercent,$s.DiskFreeGB)},
        [pscustomobject]@{Name='Windows Update';State=if([bool]$s.UpdatePaused){'ATENÇÃO'}else{'OK'};Detail=if([bool]$s.UpdatePaused){'Pausado nesta sessão'}else{'Não pausado pelo Super Optimizer'}},
        [pscustomobject]@{Name='Serviços do perfil';State='INFO';Detail=[string]$s.Services}
    )
    return [ordered]@{CheckedAt=(Get-Date).ToString('o');Blocks=$blocks;PostReboot=(Get-SOPostRebootStatus)}
}

function Get-SOProfileComparison {
    param([ValidateSet('UNIVERSAL','AGRESSIVO','EXTREMO')][string]$Target)
    $current=Get-SOProfileMatch
    $layers=@{
        'PADRÃO / CUSTOM'=@()
        'UNIVERSAL'=@('Game Mode','MMCSS Games','Foreground 0x26')
        'AGRESSIVO'=@('Game Mode','MMCSS Games','Foreground 0x26','Game DVR OFF','Mouse Accel OFF','Background reduzido','Telemetria reduzida','Energia Gaming','Hibernação OFF','Serviços curados','Defender scan 20%')
        'EXTREMO'=@('Game Mode','MMCSS Games','Foreground 0x26','Game DVR OFF','Mouse Accel OFF','Background reduzido','Telemetria reduzida','Energia Gaming','Hibernação OFF','Serviços curados','Defender scan 20%','VBS OFF','HVCI OFF','Hypervisor Windows OFF')
    }
    $from=if($layers.ContainsKey($current)){@($layers[$current])}else{@()};$to=@($layers[$Target])
    $add=@($to|Where-Object {$from -notcontains $_});$remove=@($from|Where-Object {$to -notcontains $_})
    return [ordered]@{Current=$current;Target=$Target;WillAdd=[string[]]$add;WillRestore=[string[]]$remove;RebootRecommended=($Target -eq 'EXTREMO' -or $current -eq 'EXTREMO')}
}

function Get-SOCustomProfiles {
    $f=Get-SOCustomProfilesFile;if(-not(Test-Path -LiteralPath $f)){return [object[]]@()}
    try{return [object[]]@(Get-Content $f -Raw -Encoding UTF8|ConvertFrom-Json)}catch{return [object[]]@()}
}
function Save-SOCustomProfile {
    param([string]$Name,[object[]]$Modules)
    if([string]::IsNullOrWhiteSpace($Name)){throw 'Nome do perfil personalizado é obrigatório.'}
    $mods=@(Normalize-SOWindowsStudioModules $Modules);if($mods.Count -eq 0){throw 'O perfil personalizado precisa de pelo menos um módulo.'}
    if($script:DryRun){Write-SOLog ("Salvaria perfil personalizado: {0} ({1} módulo(s))" -f $Name,$mods.Count) 'PLAN';return [ordered]@{Name=$Name;Modules=[string[]]$mods;DryRun=$true}}
    $items=@(Get-SOCustomProfiles|Where-Object {[string]$_.Name -ne $Name});$items += [pscustomobject]@{Name=$Name;Modules=[string[]]$mods;Updated=(Get-Date).ToString('o')}
    $f=Get-SOCustomProfilesFile;$tmp=$f+'.tmp.'+[guid]::NewGuid().ToString('N');$items|ConvertTo-Json -Depth 6|Set-Content $tmp -Encoding UTF8;[void](Get-Content $tmp -Raw -Encoding UTF8|ConvertFrom-Json);Move-Item $tmp $f -Force
    return [ordered]@{Name=$Name;Modules=[string[]]$mods}
}
function Remove-SOCustomProfile {
    param([string]$Name)
    if($script:DryRun){Write-SOLog ("Removeria perfil personalizado: {0}" -f $Name) 'PLAN';return $true}
    $f=Get-SOCustomProfilesFile;$items=@(Get-SOCustomProfiles|Where-Object {[string]$_.Name -ne $Name});$items|ConvertTo-Json -Depth 6|Set-Content $f -Encoding UTF8;return $true
}

function Export-SODiagnostic {
    param([ValidateSet('txt','json')][string]$Format='txt')
    $d=Get-SODiagnosticQuick;$h=Get-SOHealthSummary;$state=Get-SOStateManager;$post=Get-SOPostRebootStatus
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss';$path=Join-Path (Get-SOReportsDir) ("diagnostico_${stamp}.${Format}")
    $obj=[ordered]@{Diagnostic=$d;Health=$h;State=$state;PostReboot=$post}
    if($script:DryRun){Write-SOLog ("Exportaria diagnóstico {0}: {1}" -f $Format.ToUpperInvariant(),$path) 'PLAN';return [ordered]@{Path=$path;Format=$Format;DryRun=$true}}
    if($Format -eq 'json'){$obj|ConvertTo-Json -Depth 12|Set-Content $path -Encoding UTF8}
    else{
        $lines=@('SUPER OPTIMIZER — DIAGNÓSTICO EXPORTADO',('Gerado: '+(Get-Date).ToString('s')),'',('Windows: '+$d.Windows),('CPU: '+$d.CPU),('RAM: '+$d.RAM),('Disco: '+$d.Disk),('Perfil: '+$d.Profile),('Gaming: '+$d.Gaming),('VBS/HVCI: '+$d.VBS),('Plano: '+$d.PowerPlan),('State: '+$d.StateHealth),('Reboot pendente: '+$d.RebootPending),'','HEALTH')
        foreach($b in @($h.Blocks)){$lines += ('[{0}] {1}: {2}' -f $b.State,$b.Name,$b.Detail)}
        $lines += @('','STATE',('MachineId: '+$state.MachineId),('Primeiro backup: '+$state.FirstBackup),('Tamanho: '+$state.TotalSizeMB+' MB'),('Rollback disponível: '+$state.RollbackAvailable),'',('Pós-reboot: '+($post|ConvertTo-Json -Compress -Depth 5)))
        $lines|Set-Content $path -Encoding UTF8
    }
    return [ordered]@{Path=$path;Format=$Format}
}
# ====================== /V3.8 — STATE INTELLIGENCE ========================

function Invoke-SOAction {
    param([Parameter(Mandatory=$true)][string]$Action,$Data)
    [void](Initialize-SOEnvironment)
    Reset-SOWarnings
    $script:ProfileTransitionNeedsReboot=$false
    $machineTag=(Get-SOHash $script:MachineId).Substring(0,8)
    Write-SOLog "ACTION=$Action DRYRUN=$script:DryRun MACHINE_TAG=$machineTag" 'INFO'
    switch($Action){
        'Status' { return [ordered]@{Success=$true;Message='Status atualizado';Data=(Get-SOStatus)} }
        'StateAudit' { return [ordered]@{Success=$true;Message='Auditoria do State concluída';Data=(Get-SOStateAudit)} }
        'CreateRestorePoint' { $ok=New-SORestorePoint;return [ordered]@{Success=$ok;Message=if($ok){'Ponto de restauração criado'}else{'Não foi possível criar o ponto; consulte o log'}} }
        'ProfileGamerBrowser' {
            $arp=if($Data -and $Data.PSObject.Properties['AutoRestorePoint']){[bool]$Data.AutoRestorePoint}else{$true}
            if($arp -and -not(New-SORestorePoint 'Super Optimizer - Perfil Gamer + Navegador')){throw 'O perfil não foi aplicado porque o ponto de restauração solicitado não pôde ser criado.'}
            $opts=[pscustomobject]@{
                PreserveSearch=if($Data -and $Data.PSObject.Properties['PreserveSearch']){[bool]$Data.PreserveSearch}else{$true}
                PreserveOneDrive=if($Data -and $Data.PSObject.Properties['PreserveOneDrive']){[bool]$Data.PreserveOneDrive}else{$true}
                PreserveRdp=if($Data -and $Data.PSObject.Properties['PreserveRdp']){[bool]$Data.PreserveRdp}else{$false}
                PreserveVpn=if($Data -and $Data.PSObject.Properties['PreserveVpn']){[bool]$Data.PreserveVpn}else{$true}
                PreserveHotspot=if($Data -and $Data.PSObject.Properties['PreserveHotspot']){[bool]$Data.PreserveHotspot}else{$false}
                PreserveBiometrics=if($Data -and $Data.PSObject.Properties['PreserveBiometrics']){[bool]$Data.PreserveBiometrics}else{$true}
                PreserveNetworkDiscovery=if($Data -and $Data.PSObject.Properties['PreserveNetworkDiscovery']){[bool]$Data.PreserveNetworkDiscovery}else{$true}
                PreserveHibernation=if($Data -and $Data.PSObject.Properties['PreserveHibernation']){[bool]$Data.PreserveHibernation}else{$true}
                PreserveVirtualization=if($Data -and $Data.PSObject.Properties['PreserveVirtualization']){[bool]$Data.PreserveVirtualization}else{$true}
                PreservePrinter=if($Data -and $Data.PSObject.Properties['PreservePrinter']){[bool]$Data.PreservePrinter}else{$true}
            }
            [void](Invoke-SOGamerBrowserProfile -Options $opts)
            if($script:DryRun){
                $det='GAMER + NAVEGADOR'
            }else{
                # Verifique com as opções desta própria execução. Isso evita depender da
                # releitura imediata do marcador do State para classificar um perfil que
                # acabou de ser aplicado e, se houver drift real, registra exatamente o motivo.
                $gbVerify=Get-SOGamerBrowserVerification -Options $opts
                if([bool]$gbVerify.Match){$det='GAMER + NAVEGADOR'}
                else{
                    foreach($reason in @($gbVerify.Reasons)){Write-SOLog ('Gamer + Navegador — verificação: '+[string]$reason) 'WARN'}
                    $det=Get-SOProfileMatch
                }
            }
            if(-not $script:DryRun -and $det -ne 'GAMER + NAVEGADOR'){Write-SOLog ("Perfil Gamer + Navegador aplicado, mas estado detectado={0}. Consulte os motivos de verificação acima." -f $det) 'WARN'}else{Write-SOLog 'Estado verificado após aplicação: GAMER + NAVEGADOR' 'OK'}
            return [ordered]@{Success=$true;Message='Perfil Gamer + Navegador aplicado';RebootRecommended=([bool]$script:ProfileTransitionNeedsReboot -or -not [bool]$opts.PreserveVirtualization);Data=[ordered]@{DetectedProfile=$det;Options=$opts}}
        }
        'ProfileUniversal' { $arp=if($Data -and $Data.PSObject.Properties['AutoRestorePoint']){[bool]$Data.AutoRestorePoint}else{$false};if($arp -and -not(New-SORestorePoint 'Super Optimizer - Perfil Universal')){throw 'O perfil não foi aplicado porque o ponto de restauração solicitado não pôde ser criado. Desmarque a opção de ponto automático somente se quiser prosseguir sem ele.'};[void](Invoke-SOUniversalProfile);$det=Confirm-SOProfileResult 'UNIVERSAL';return [ordered]@{Success=$true;Message='Perfil Universal aplicado';RebootRecommended=[bool]$script:ProfileTransitionNeedsReboot;Data=[ordered]@{DetectedProfile=$det}} }
        'ProfileAggressive' { $arp=if($Data -and $Data.PSObject.Properties['AutoRestorePoint']){[bool]$Data.AutoRestorePoint}else{$false};if($arp -and -not(New-SORestorePoint 'Super Optimizer - Perfil Agressivo')){throw 'O perfil não foi aplicado porque o ponto de restauração solicitado não pôde ser criado. Desmarque a opção de ponto automático somente se quiser prosseguir sem ele.'};[void](Invoke-SOAggressiveProfile);$det=Confirm-SOProfileResult 'AGRESSIVO';return [ordered]@{Success=$true;Message='Perfil Agressivo aplicado';RebootRecommended=$true;Data=[ordered]@{DetectedProfile=$det}} }
        'ProfileExtreme' { $arp=if($Data -and $Data.PSObject.Properties['AutoRestorePoint']){[bool]$Data.AutoRestorePoint}else{$false};if($arp -and -not(New-SORestorePoint 'Super Optimizer - Perfil Extremo')){throw 'O perfil não foi aplicado porque o ponto de restauração solicitado não pôde ser criado. Desmarque a opção de ponto automático somente se quiser prosseguir sem ele.'};[void](Invoke-SOExtremeProfile);$det=Confirm-SOProfileResult 'EXTREMO';return [ordered]@{Success=$true;Message='Perfil Extremo aplicado';RebootRecommended=$true;Data=[ordered]@{DetectedProfile=$det}} }
        'MaintenanceWeekly' { $r=Invoke-SOWeeklyMaintenance;return [ordered]@{Success=$true;Message=[string]$r.Message;Data=$r} }
        'FullCleanPC' { $r=Invoke-SOFullPCCleanup;return [ordered]@{Success=$true;Message=[string]$r.Message;Data=$r} }
        'CleanupAnalyze' { $noStamp=if($Data -and $Data.PSObject.Properties['NoStamp']){[bool]$Data.NoStamp}else{$false};$timeout=if($Data -and $Data.PSObject.Properties['TimeoutSecondsPerArea']){[int]$Data.TimeoutSecondsPerArea}else{4};$r=Get-SOCleanupAnalysis -NoStamp:$noStamp -TimeoutSecondsPerArea $timeout;return [ordered]@{Success=$true;Message=('Análise concluída: ~'+[string]$r.TotalGB+' GB nas áreas mensuráveis');Data=$r} }
        'DeepCleanPC' { $r=Invoke-SODeepPCCleanup;return [ordered]@{Success=$true;Message=[string]$r.Message;RebootRecommended=$true;Data=$r} }
        'DeliveryOptimizationCache' { $ok=Clear-SODeliveryOptimizationCache;return [ordered]@{Success=$true;Message=if($ok){'Cache de Otimização de Entrega limpo'}else{'Etapa não disponível ou concluída com aviso'}} }
        'WerReports' { [void](Clear-SOWerReports);return [ordered]@{Success=$true;Message='Relatórios WER limpos'} }
        'TempUser' { [void](Clear-SOUserTemp);return [ordered]@{Success=$true;Message='Temporários do usuário limpos'} }
        'TempWindows' { [void](Clear-SOWindowsTemp);return [ordered]@{Success=$true;Message='Windows Temp limpo'} }
        'ShaderCache' { [void](Clear-SODirectXShaderCache);return [ordered]@{Success=$true;Message='Cache DirectX limpo'} }
        'DiskScan' { [void](Invoke-SODiskScan);return [ordered]@{Success=$true;Message='CHKDSK /scan concluído'} }
        'ComponentAnalyze' { [void](Invoke-SOComponentAnalyze);return [ordered]@{Success=$true;Message='Análise do Component Store concluída'} }
        'ComponentCleanup' { [void](Invoke-SOComponentCleanup);return [ordered]@{Success=$true;Message='Component Store limpo'} }
        'UpdateCache' { [void](Clear-SOUpdateCache);return [ordered]@{Success=$true;Message='Cache do Windows Update limpo'} }
        'HealthScan' { [void](Invoke-SOHealthScan);return [ordered]@{Success=$true;Message='Verificação de integridade concluída'} }
        'RepairWindows' { [void](Invoke-SORepairWindows);return [ordered]@{Success=$true;Message='Reparo do Windows concluído';RebootRecommended=$true} }
        'RecycleBin' { [void](Clear-SORecycleBin);return [ordered]@{Success=$true;Message='Operação da Lixeira concluída'} }
        'RamInfo' { return [ordered]@{Success=$true;Message='RAM lida';Data=(Get-SORamInfo)} }
        'RamStandbyClean' {
            $force=if($Data -and $Data.PSObject.Properties['Force']){[bool]$Data.Force}else{$false}
            $r=Invoke-SORamStandbyClean -Force $force
            return [ordered]@{Success=$true;Message=[string]$r.Message;Data=$r}
        }
        'RamFullClean' {
            $force=if($Data -and $Data.PSObject.Properties['Force']){[bool]$Data.Force}else{$false}
            $r=Invoke-SORamFullClean -Force $force
            return [ordered]@{Success=$true;Message=[string]$r.Message;Data=$r}
        }
        'GamingAll' { [void](Set-SOGameMode);[void](Set-SOGameDVROff);[void](Set-SOMMCSS);[void](Set-SOForeground);[void](Set-SOMouseAccelOff);return [ordered]@{Success=$true;Message='Gaming completo aplicado'} }
        'GameMode' { [void](Set-SOGameMode);return [ordered]@{Success=$true;Message='Game Mode ativado'} }
        'GameDVROff' { [void](Set-SOGameDVROff);return [ordered]@{Success=$true;Message='Game DVR/capturas desativados'} }
        'MMCSS' { [void](Set-SOMMCSS);return [ordered]@{Success=$true;Message='MMCSS Games aplicado'} }
        'Foreground' { [void](Set-SOForeground);return [ordered]@{Success=$true;Message='Foreground 0x26 aplicado'} }
        'MouseAccelOff' { [void](Set-SOMouseAccelOff);return [ordered]@{Success=$true;Message='Aceleração do mouse desativada'} }
        'GamingRestore' { [void](Restore-SORegistry 'Gaming');return [ordered]@{Success=$true;Message='Gaming restaurado'} }
        'BackgroundReduced' { [void](Set-SOBackgroundReduced);return [ordered]@{Success=$true;Message='Background reduzido'} }
        'TelemetryReduced' { [void](Set-SOTelemetryReduced);return [ordered]@{Success=$true;Message='Telemetria reduzida'} }
        'VisualsReduced' { [void](Set-SOVisualsReduced);return [ordered]@{Success=$true;Message='Efeitos visuais reduzidos'} }
        'PowerGaming' { [void](Set-SOPowerThrottlingOff);[void](Enable-SOGamingPower);return [ordered]@{Success=$true;Message='Energia gaming aplicada'} }
        'PrivacyRestore' { [void](Restore-SORegistry 'Privacy');[void](Restore-SOTasks);[void](Restore-SOServices -Names @('DiagTrack','WerSvc'));return [ordered]@{Success=$true;Message='Background/telemetria restaurados'} }
        'PowerRestore' { [void](Restore-SORegistry 'Power');[void](Restore-SOHibernation);[void](Restore-SOPower);return [ordered]@{Success=$true;Message='Energia restaurada'} }
        'WindowsStudioStatus' { return [ordered]@{Success=$true;Message='Windows Studio analisado';Data=(Get-SOWindowsStudioStatus)} }
        'WindowsStudioApplyAll' { $arp=if($Data -and $Data.PSObject.Properties['AutoRestorePoint']){[bool]$Data.AutoRestorePoint}else{$true};$r=Invoke-SOWindowsStudioApplyAll -AutoRestorePoint $arp;return [ordered]@{Success=$true;Message='Windows otimizado com sessão reversível';RebootRecommended=$true;Data=$r} }
        'WindowsStudioApplySelection' { $arp=if($Data -and $Data.PSObject.Properties['AutoRestorePoint']){[bool]$Data.AutoRestorePoint}else{$true};$mods=if($Data -and $Data.PSObject.Properties['Modules']){@($Data.Modules)}else{@()};$r=Invoke-SOWindowsStudioApplySelection -Modules $mods -AutoRestorePoint $arp;return [ordered]@{Success=$true;Message=('Módulos aplicados: '+([string[]]@($r.AppliedModules) -join ', '));RebootRecommended=$true;Data=$r} }
        'WindowsStudioRestoreSelection' { $mods=if($Data -and $Data.PSObject.Properties['Modules']){@($Data.Modules)}else{@()};$r=Restore-SOWindowsStudioSelectedOriginal -Modules $mods;return [ordered]@{Success=$true;Message=('Módulos restaurados: '+([string[]]@($r.RestoredModules) -join ', '));RebootRecommended=$true;Data=$r} }
        'WindowsStudioUndo' { $r=Restore-SOWindowsStudioSession;return [ordered]@{Success=[bool]$r.Restored;Message=if([bool]$r.Restored){'Última sessão Windows Studio desfeita'}else{'Restauração da sessão terminou com avisos; consulte o log'};RebootRecommended=$true;Data=$r} }
        'WindowsStudioRestoreOriginal' { $r=Restore-SOWindowsStudioOriginal;return [ordered]@{Success=$true;Message='Ajustes do Windows Studio restaurados para os backups originais conhecidos';RebootRecommended=$true;Data=$r} }
        'StudioEnergy' { [void](Enable-SOGamingPower);return [ordered]@{Success=$true;Message='Energia Gaming aplicada'} }
        'StudioPowerThrottle' { [void](Set-SOPowerThrottlingOff -Category 'StudioPowerThrottle');return [ordered]@{Success=$true;Message='Power Throttling desativado'} }
        'StudioVisuals' { [void](Set-SOVisualsReduced -Category 'StudioVisuals');return [ordered]@{Success=$true;Message='Efeitos visuais reduzidos'} }
        'StudioBackground' { [void](Set-SOBackgroundReduced -Category 'StudioBackground' -IncludeVisuals $false);return [ordered]@{Success=$true;Message='Background reduzido'} }
        'StudioTelemetry' { [void](Set-SOTelemetryReduced -Category 'StudioTelemetry');return [ordered]@{Success=$true;Message='Telemetria e relatórios reduzidos'} }
        'StudioIndexingOff' { [void](Set-SOServiceMode 'WSearch' Disabled 'Indexação de pesquisa');return [ordered]@{Success=$true;Message='Indexação do Windows Search desativada'} }
        'StudioHibernationOff' { $ok=Disable-SOHibernation;return [ordered]@{Success=$true;Message=if($ok){'Hibernação desativada'}else{'Hibernação não foi alterada; consulte avisos'}} }
        'ServicesApply' { [void](Set-SOServicesProfile);return [ordered]@{Success=$true;Message='Perfil de serviços aplicado'} }
        'ServicesRestore' { [void](Restore-SOServices);return [ordered]@{Success=$true;Message='Serviços restaurados'} }
        'HAGSOn' { [void](Set-SOHAGS $true);return [ordered]@{Success=$true;Message='HAGS solicitado como ON';RebootRecommended=$true} }
        'HAGSOff' { [void](Set-SOHAGS $false);return [ordered]@{Success=$true;Message='HAGS solicitado como OFF';RebootRecommended=$true} }
        'MPOOff' { [void](Set-SOMPOOff);return [ordered]@{Success=$true;Message='MPO desativado (experimental)';RebootRecommended=$true} }
        'GPURestore' { [void](Restore-SOGPU);return [ordered]@{Success=$true;Message='GPU restaurada';RebootRecommended=$true} }
        'FlushDNS' { $code=Invoke-SOExternal 'ipconfig.exe' @('/flushdns') 'Flush DNS' 10 80;if($code -ne 0){throw "ipconfig /flushdns terminou com código $code"};return [ordered]@{Success=$true;Message='DNS limpo'} }
        'DNSStatus' { return [ordered]@{Success=$true;Message='Status de DNS lido';Data=(Get-SODnsStatus)} }
        'DNSReviewStamp' { $r=Set-SODnsReviewStamp;return [ordered]@{Success=$true;Message='Revisão de DNS registrada';Data=$r} }
        'WingetScan' { $inc=if($Data -and $Data.PSObject.Properties['IncludeUnknown']){[bool]$Data.IncludeUnknown}else{$false};$r=Invoke-SOWingetScan -IncludeUnknown $inc;return [ordered]@{Success=([int]$r.ExitCode -eq 0);Message=if([int]$r.ExitCode -eq 0){'Consulta de atualizações concluída'}else{'WinGet terminou com aviso/erro; consulte a saída'};Data=$r} }
        'WingetUpgradeAll' { $inc=if($Data -and $Data.PSObject.Properties['IncludeUnknown']){[bool]$Data.IncludeUnknown}else{$false};$r=Invoke-SOWingetUpgradeAll -IncludeUnknown $inc;return [ordered]@{Success=([int]$r.ExitCode -eq 0);Message=if([int]$r.ExitCode -eq 0){'Atualização de aplicativos concluída'}else{'Alguns aplicativos podem não ter sido atualizados; consulte a saída'};Data=$r} }
        'DNSBenchmark' { $r=Invoke-SODnsBenchmark;return [ordered]@{Success=$true;Message=if($r.BestProvider){('Benchmark concluído. Melhor: '+[string]$r.BestProvider+' ('+[string]$r.BestMedianMs+' ms)')}else{'Benchmark concluído sem vencedor confiável'};Data=$r} }
        'DNSApplyProvider' { $provider=if($Data -and $Data.PSObject.Properties['Provider']){[string]$Data.Provider}else{'Cloudflare'};$r=Set-SODnsProvider -Provider $provider;return [ordered]@{Success=$true;Message=('DNS aplicado: '+$provider);Data=$r} }
        'DNSApplyBest' { $r=Invoke-SODnsApplyBest;return [ordered]@{Success=$true;Message=('Melhor DNS aplicado: '+[string]$r.BestProvider);Data=$r} }
        'DNSRestore' { $r=Restore-SODnsOriginal;return [ordered]@{Success=([int]$r.Errors -eq 0);Message=if([int]$r.Errors -eq 0){'DNS original restaurado'}else{'DNS parcialmente restaurado; consulte o log'};Data=$r} }
        'UpdateStop' {
            $r=Stop-SOUpdateSession
            return [ordered]@{Success=[bool]$r.Success;Message=[string]$r.Message;Data=$r}
        }
        'UpdateStart' {
            $r=Restore-SOUpdateSession
            return [ordered]@{Success=[bool]$r.Success;Message=[string]$r.Message;Data=$r}
        }
        'DiagnosticQuick' { return [ordered]@{Success=$true;Message='Diagnóstico rápido concluído';Data=(Get-SODiagnosticQuick)} }
        'DiagnosticReport' { $p=New-SODiagnosticReport;return [ordered]@{Success=$true;Message='Relatório de diagnóstico criado';Data=[ordered]@{Path=$p}} }
        'LogsCleanup' { $n=Clear-SOOldLogs 30;return [ordered]@{Success=$true;Message=("Logs antigos removidos: {0}" -f $n)} }
        'VBSOff' { [void](Set-SOVBSOff);return [ordered]@{Success=$true;Message='VBS/HVCI/Hypervisor desativados';RebootRecommended=$true} }
        'VBSRestore' { [void](Restore-SORegistry 'VBS');[void](Restore-SOHypervisor);return [ordered]@{Success=$true;Message='VBS/Hypervisor restaurados';RebootRecommended=$true} }
        'PerGameSet' { [void](Set-SOPerGamePriority $Data.ExeName);return [ordered]@{Success=$true;Message=("Prioridade HIGH configurada para "+$Data.ExeName)} }
        'PerGameList' { return [ordered]@{Success=$true;Message='Lista de prioridades lida';Data=@(Get-SOPerGamePriorities)} }
        'PerGameRemove' { [void](Restore-SOPerGameOne $Data.ExeName);return [ordered]@{Success=$true;Message=("Prioridade restaurada para "+$Data.ExeName)} }
        'PerGameRestore' { [void](Restore-SOPerGame);return [ordered]@{Success=$true;Message='Prioridades por jogo restauradas'} }
        'RestoreAll' { [void](Restore-SOAll);return [ordered]@{Success=$true;Message='Rollback completo concluído';RebootRecommended=$true} }
        'HistoryGet' { return [ordered]@{Success=$true;Message='Histórico carregado';Data=[object[]](Get-SOHistoryData)} }
        'StateManager' { return [ordered]@{Success=$true;Message='State Manager carregado';Data=(Get-SOStateManager)} }
        'HealthSummary' { return [ordered]@{Success=$true;Message='Health Summary carregado';Data=(Get-SOHealthSummary)} }
        'PostRebootStatus' { return [ordered]@{Success=$true;Message='Relatório pós-reboot lido';Data=(Get-SOPostRebootStatus)} }
        'ProfileCompare' { $target=[string]$Data.Target;return [ordered]@{Success=$true;Message=('Comparação para '+$target);Data=(Get-SOProfileComparison -Target $target)} }
        'CustomProfilesGet' { return [ordered]@{Success=$true;Message='Perfis personalizados carregados';Data=[object[]](Get-SOCustomProfiles)} }
        'CustomProfileSave' { $r=Save-SOCustomProfile -Name ([string]$Data.Name) -Modules @($Data.Modules);return [ordered]@{Success=$true;Message=('Perfil personalizado salvo: '+[string]$r.Name);Data=$r} }
        'CustomProfileDelete' { [void](Remove-SOCustomProfile -Name ([string]$Data.Name));return [ordered]@{Success=$true;Message=('Perfil personalizado removido: '+[string]$Data.Name)} }
        'DiagnosticExportTxt' { $r=Export-SODiagnostic -Format txt;return [ordered]@{Success=$true;Message='Diagnóstico TXT exportado';Data=$r} }
        'DiagnosticExportJson' { $r=Export-SODiagnostic -Format json;return [ordered]@{Success=$true;Message='Diagnóstico JSON exportado';Data=$r} }
        default { throw "Ação desconhecida: $Action" }
    }
}

Export-ModuleMember -Function Initialize-SOEnvironment,Set-SOLogFile,Set-SOProgressFile,Set-SODryRun,Write-SOLog,Write-SOProgress,Invoke-SOAction,Get-SOConfig,Get-SOStatus,Get-SORamInfo,Get-SOPerGamePriorities,Get-SOWarningCount,Get-SOWarningMessages,Get-SOStateAudit,Test-SORamNativeApiAvailable,Get-SOChangeSnapshot,Compare-SOChangeSnapshots,Add-SOHistoryEntry,Get-SOHistoryData,Get-SOStateManager,Save-SOPostRebootMarker,Get-SOPostRebootStatus,Get-SOHealthSummary,Get-SOProfileComparison
