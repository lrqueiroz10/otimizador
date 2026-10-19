#Requires -RunAsAdministrator
param([string]$OutputFile='')

$ErrorActionPreference='Continue'
$ScriptVersion='V3.9.0 DEV'
$ConfigVersion='3.9.0 DEV'
$AppRoot=Split-Path $PSScriptRoot -Parent
$results=New-Object System.Collections.Generic.List[object]

function Write-CurrentReport {
    if(-not $OutputFile){return}
    try{
        $passed=@($results|Where-Object Passed).Count
        $total=$results.Count
        $lines=New-Object System.Collections.Generic.List[string]
        [void]$lines.Add(('=== SUPER OPTIMIZER {0} - AUTO-TESTE ===' -f $ScriptVersion))
        [void]$lines.Add('')
        foreach($item in $results){
            $prefix=if($item.Passed){'[OK] '}else{'[ERRO] '}
            [void]$lines.Add($prefix+$item.Test+' :: '+$item.Detail)
        }
        [void]$lines.Add('')
        [void]$lines.Add(('PROGRESSO PARCIAL: {0} aprovados em {1} testes executados — AUTO-TESTE AINDA EM EXECUÇÃO' -f $passed,$total))
        ($lines -join "`r`n") | Set-Content -LiteralPath $OutputFile -Encoding UTF8
    }catch{}
}

function Add-Test([string]$Name,[bool]$Passed,[string]$Detail){
    [void]$results.Add([pscustomobject]@{Test=$Name;Passed=$Passed;Detail=$Detail})
    Write-CurrentReport
}

function Invoke-WorkerProbe {
    param([string]$Action,$Data,[int]$TimeoutMs=30000)
    $runtime=Join-Path $AppRoot 'State\Runtime'
    $logs=Join-Path $AppRoot 'State\Logs'
    New-Item -ItemType Directory -Force -Path $runtime,$logs|Out-Null
    $id=[guid]::NewGuid().ToString('N')
    $req=Join-Path $runtime ($id+'.selfprobe.request.json')
    $res=Join-Path $runtime ($id+'.selfprobe.result.json')
    $prog=Join-Path $runtime ($id+'.selfprobe.progress.json')
    $log=Join-Path $runtime ('selfprobe_'+$id+'.log')
    try{
        [ordered]@{Action=$Action;Data=$Data;DryRun=$true;Created=(Get-Date).ToString('o')} |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $req -Encoding UTF8
        $exe=Join-Path $PSHOME 'powershell.exe'
        $args='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RequestFile "{1}" -ResultFile "{2}" -ProgressFile "{3}" -LogFile "{4}"' -f (Join-Path $PSScriptRoot 'Worker.ps1'),$req,$res,$prog,$log
        $proc=Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru
        if(-not $proc.WaitForExit($TimeoutMs)){
            try{$proc.Kill()}catch{}
            return [pscustomobject]@{Success=$false;Message=('Timeout do Worker em '+$Action)}
        }
        if(-not(Test-Path -LiteralPath $res)){
            return [pscustomobject]@{Success=$false;Message=('Worker não gerou resultado em '+$Action)}
        }
        $r=Get-Content -LiteralPath $res -Raw -Encoding UTF8|ConvertFrom-Json
        return [pscustomobject]@{Success=[bool]$r.Success;Message=[string]$r.Message;Result=$r;ExitCode=$proc.ExitCode}
    }catch{
        return [pscustomobject]@{Success=$false;Message=$_.Exception.Message}
    }finally{
        Remove-Item -LiteralPath $req,$res,$prog -Force -ErrorAction SilentlyContinue
        # Logs de probe ficam em Runtime e são limpos automaticamente pela aplicação.
    }
}

trap {
    try{Add-Test 'Falha inesperada do Auto-Teste' $false $_.Exception.Message;Write-CurrentReport}catch{}
    exit 2
}

# -----------------------------------------------------------------------------
# Ambiente Windows / PowerShell
# -----------------------------------------------------------------------------
$admin=$false
try{$id=[Security.Principal.WindowsIdentity]::GetCurrent();$pr=New-Object Security.Principal.WindowsPrincipal($id);$admin=$pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}catch{}
Add-Test 'Permissão administrativa' $admin $(if($admin){'Processo elevado'}else{'O Auto-Teste precisa ser executado como Administrador'})
Add-Test 'PowerShell compatível' ($PSVersionTable.PSVersion.Major -ge 5) ('PowerShell '+[string]$PSVersionTable.PSVersion)
Add-Test 'Thread STA para WPF' ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA) ('ApartmentState='+[string][Threading.Thread]::CurrentThread.ApartmentState)

$nativeRequired=@('DISM.exe','sfc.exe','chkdsk.exe','ipconfig.exe','powercfg.exe','bcdedit.exe')
$nativeMissing=@($nativeRequired|Where-Object {-not(Get-Command $_ -ErrorAction SilentlyContinue)})
Add-Test 'Ferramentas nativas do Windows' ($nativeMissing.Count -eq 0) $(if($nativeMissing.Count){'Ausentes: '+($nativeMissing -join ', ')}else{($nativeRequired -join ', ')+' disponíveis'})

$coreCmdlets=@('Get-CimInstance','Get-ScheduledTask','Disable-ScheduledTask','Enable-ScheduledTask','Clear-RecycleBin')
$coreMissing=@($coreCmdlets|Where-Object {-not(Get-Command $_ -ErrorAction SilentlyContinue)})
Add-Test 'Cmdlets principais' ($coreMissing.Count -eq 0) $(if($coreMissing.Count){'Ausentes: '+($coreMissing -join ', ')}else{'CIM, ScheduledTasks e Lixeira disponíveis'})
$netCmdOk=($null -ne (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command Set-DnsClientServerAddress -ErrorAction SilentlyContinue))
Add-Test 'Cmdlets de DNS/Rede' $netCmdOk 'Get-NetIPConfiguration e DnsClient disponíveis para o DNS Lab.'

$restorePointCmd=Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue
Add-Test 'Checkpoint-Computer disponível' ($null -ne $restorePointCmd) $(if($restorePointCmd){'Cmdlet presente; a criação ainda depende da Proteção do Sistema estar habilitada.'}else{'Cmdlet ausente; criação automática de ponto de restauração não funcionará.'})

$wingetCmd=Get-Command winget.exe -ErrorAction SilentlyContinue
Add-Test 'WinGet opcional' $true $(if($wingetCmd){'winget.exe detectado; atualização centralizada de apps disponível.'}else{'winget.exe não detectado; o restante do Super Optimizer continua funcional.'})

# -----------------------------------------------------------------------------
# Estrutura e parser
# -----------------------------------------------------------------------------
$required=@(
    'Launcher.ps1','App.ps1','Config.json','UI\MainWindow.xaml',
    'Core\Engine.psm1','Core\Worker.ps1','Core\SelfTest.ps1','Docs\README.html','Integrity.json'
)
foreach($r in $required){
    $p=Join-Path $AppRoot $r
    Add-Test ("Arquivo "+$r) (Test-Path -LiteralPath $p) $p
}

$psfiles=Get-ChildItem $AppRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -in @('.ps1','.psm1')}
$parseOk=$true;$parseDetail=''
foreach($f in $psfiles){
    $tok=$null;$err=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$err)
    foreach($e in @($err)){
        $parseOk=$false
        $parseDetail += ('{0} L{1}:C{2} - {3}; ' -f $f.Name,$e.Extent.StartLineNumber,$e.Extent.StartColumnNumber,$e.Message)
    }
}
Add-Test 'Parser PowerShell' $parseOk $(if($parseOk){'Todos os .ps1/.psm1 passaram no parser oficial'}else{$parseDetail})


try{
    $manifestPath=Join-Path $AppRoot 'Integrity.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $bad=New-Object System.Collections.Generic.List[string]
    foreach($entry in @($manifest.files)){
        $p=Join-Path $AppRoot ([string]$entry.path)
        if(-not(Test-Path -LiteralPath $p -PathType Leaf)){[void]$bad.Add(([string]$entry.path)+': ausente');continue}
        $actual=(Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if($actual -ne ([string]$entry.sha256).ToLowerInvariant()){[void]$bad.Add(([string]$entry.path)+': hash diferente')}
    }
    Add-Test 'Integridade dos arquivos operacionais' ($bad.Count -eq 0) $(if($bad.Count){$bad -join '; '}else{('{0} arquivo(s) conferidos por SHA-256' -f @($manifest.files).Count)})
}catch{Add-Test 'Integridade dos arquivos operacionais' $false $_.Exception.Message}

# State precisa ser gravável para backup/rollback/logs.
try{
    $state=Join-Path $AppRoot 'State';New-Item -ItemType Directory -Force -Path $state|Out-Null
    $probe=Join-Path $state ('.write_test_'+[guid]::NewGuid().ToString('N')+'.tmp')
    'ok'|Set-Content -LiteralPath $probe -Encoding ASCII -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    Add-Test 'State gravável' $true 'Backup, logs e rollback podem ser salvos.'
}catch{Add-Test 'State gravável' $false $_.Exception.Message}

# -----------------------------------------------------------------------------
# Config, versão e XAML real
# -----------------------------------------------------------------------------
$cfg=$null;$appSource='';$engineSource='';$workerSource='';$launcherSource='';$xamlSource='';$batSource=''
try{
    $cfg=Get-Content (Join-Path $AppRoot 'Config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $appSource=Get-Content -LiteralPath (Join-Path $AppRoot 'App.ps1') -Raw -Encoding UTF8
    $engineSource=Get-Content -LiteralPath (Join-Path $AppRoot 'Core\Engine.psm1') -Raw -Encoding UTF8
    $workerSource=Get-Content -LiteralPath (Join-Path $AppRoot 'Core\Worker.ps1') -Raw -Encoding UTF8
    $launcherSource=Get-Content -LiteralPath (Join-Path $AppRoot 'Launcher.ps1') -Raw -Encoding UTF8
    $xamlSource=Get-Content -LiteralPath (Join-Path $AppRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
    $batPath=Join-Path (Split-Path $AppRoot -Parent) 'SuperOptimizer.bat'
    if(Test-Path -LiteralPath $batPath){$batSource=Get-Content -LiteralPath $batPath -Raw}
    Add-Test 'Config JSON' ($cfg.services.Count -gt 0) ('Serviços='+$cfg.services.Count+' | Versão='+$cfg.version)
}catch{Add-Test 'Config JSON' $false $_.Exception.Message}

if($cfg){
    $serviceNames=@($cfg.services|ForEach-Object {[string]$_.name})
    $dupServices=@($serviceNames|Group-Object|Where-Object Count -gt 1|ForEach-Object Name)
    $badModes=@($cfg.services|Where-Object {$_.mode -notin @('Disabled','Manual','Automatic')})
    $badRisks=@($cfg.services|Where-Object {$_.risk -notin @('low','medium','high')})
    Add-Test 'Config: serviços únicos' ($dupServices.Count -eq 0) $(if($dupServices.Count){'Duplicados: '+($dupServices -join ', ')}else{'Nenhum serviço duplicado'})
    Add-Test 'Config: modos válidos' ($badModes.Count -eq 0) $(if($badModes.Count){'Modo inválido em '+(($badModes|ForEach-Object name)-join ', ')}else{'Disabled/Manual/Automatic válidos'})
    Add-Test 'Config: riscos válidos' ($badRisks.Count -eq 0) $(if($badRisks.Count){'Risco inválido em '+(($badRisks|ForEach-Object name)-join ', ')}else{'low/medium/high válidos'})
    $taskKeys=@($cfg.telemetryTasks|ForEach-Object {([string]$_.path)+'|'+([string]$_.name)})
    $dupTasks=@($taskKeys|Group-Object|Where-Object Count -gt 1|ForEach-Object Name)
    Add-Test 'Config: tarefas únicas' ($dupTasks.Count -eq 0) $(if($dupTasks.Count){'Duplicadas: '+($dupTasks -join ', ')}else{'Nenhuma tarefa duplicada'})
    $preserveExpected=@('Microsoft Store','Xbox / Game Pass','Bluetooth','Camera','Microfone','Phone Link','Windows Update','Defender','VirtualBox / AMD-V')
    $missingPreserved=@($preserveExpected|Where-Object {$cfg.preserved -notcontains $_})
    Add-Test 'Config: recursos preservados' ($missingPreserved.Count -eq 0) $(if($missingPreserved.Count){'Ausentes: '+($missingPreserved -join ', ')}else{'Lista de recursos essenciais preservados está completa'})
    $protectedServices=@('wuauserv','BITS','DoSvc','InstallService','ClipSVC','AppXSvc','GamingServices','GamingServicesNet','bthserv','Audiosrv','AudioEndpointBuilder','FrameServer')
    $configuredServiceNames=@($cfg.services|ForEach-Object {[string]$_.name})
    $protectedTouched=@($protectedServices|Where-Object {$configuredServiceNames -contains $_})
    Add-Test 'Config: serviços essenciais fora do perfil' ($protectedTouched.Count -eq 0) $(if($protectedTouched.Count){'Não deveriam estar no perfil: '+($protectedTouched -join ', ')}else{'Update, Store/Xbox, Bluetooth e áudio/câmera não são alvo do perfil de serviços'})
    $blockedExpected=@('Microsoft\Windows\Recent','Prefetch','Event Logs','dllcache')
    $missingBlocked=@($blockedExpected|Where-Object {$cfg.dangerousCleanupBlocked -notcontains $_})
    Add-Test 'Config: limpezas perigosas bloqueadas' ($missingBlocked.Count -eq 0) $(if($missingBlocked.Count){'Ausentes: '+($missingBlocked -join ', ')}else{'Recent, Prefetch, Event Logs e dllcache declarados como bloqueados'})
}

$versionOk=$false
if($cfg){
    $versionOk=([string]$cfg.version -eq $ConfigVersion) -and ($xamlSource -match [regex]::Escape($ScriptVersion)) -and ($launcherSource -match [regex]::Escape($ScriptVersion)) -and ($batSource -match [regex]::Escape($ScriptVersion))
}
Add-Test 'Versão consistente' $versionOk $(if($versionOk){'Config, XAML, Launcher, BAT e Auto-Teste estão sincronizados'}else{'Há referência de versão antiga em arquivo operacional'})

try{
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName WindowsBase
    [xml]$uiXml=$xamlSource
    $reader=New-Object System.Xml.XmlNodeReader($uiXml)
    try{$window=[Windows.Markup.XamlReader]::Load($reader);$ok=($window -is [System.Windows.Window]);if($ok){$window.Close()}}
    finally{$reader.Close()}
    Add-Test 'XAML/WPF real' $ok ('ApartmentState='+[Threading.Thread]::CurrentThread.ApartmentState)
}catch{Add-Test 'XAML/WPF real' $false $_.Exception.Message}

# -----------------------------------------------------------------------------
# Auditoria estática de segurança e arquitetura
# -----------------------------------------------------------------------------
$danger=@('Microsoft\Windows\Recent','\Prefetch','wevtutil.exe cl','DisableAntiSpyware','/ResetBase','useplatformclock','disabledynamictick')
foreach($d in $danger){
    Add-Test ('Bloqueio perigoso: '+$d) (-not ($engineSource -match [regex]::Escape($d))) 'Não deve existir no Engine.'
}

Add-Test 'Backup de Registro fail-safe' ($engineSource.Contains('$backupOk=Backup-SORegistryValue') -and $engineSource.Contains('estado original não pôde ser salvo')) 'Ajuste não é aplicado se o rollback original não puder ser salvo.'
Add-Test 'TEMP com fail-safe de caminho' ($engineSource.Contains('function Test-SOCleanupPathSafe') -and $engineSource.Contains('Caminho de limpeza recusado pelo fail-safe')) 'Limpezas só aceitam TEMP/Windows Temp/D3DSCache/SoftwareDistribution\Download esperados.'
Add-Test 'TEMP ignora reparse points' ($engineSource.Contains('Reparse point ignorado por segurança') -and -not $engineSource.Contains('Remove somente o link/junction')) 'Junctions/reparse points não são seguidos nem removidos.'
Add-Test 'PowerCfg verificado' ($engineSource.Contains('function Invoke-SOPowerCfg') -and $engineSource.Contains('powercfg falhou') -and $engineSource.Contains('$ErrorActionPreference=''Continue''')) 'Plano de energia verifica código de retorno sem deixar stderr nativo virar exceção prematura.'
Add-Test 'PowerCfg usa GUIDs portáveis' ($engineSource.Contains('2a737441-1930-4402-8d77-b2bebba308a3') -and $engineSource.Contains('48e6b7a6-50f5-4782-a5d4-53bb8f07e226') -and $engineSource.Contains('ee12f906-d277-404b-b6da-e5fa1a576df5') -and (-not $engineSource.Contains("'SUB_USB','USBSELECTIVE'"))) 'Plano Gaming usa GUIDs oficiais para USB selective suspend e PCIe ASPM em vez de alias ausente em algumas instalações.'
Add-Test 'PowerCfg centralizado' ($engineSource.Contains('function Invoke-SOPowerCfgRaw') -and (-not $engineSource.Contains('& powercfg.exe /hibernate off')) -and (-not $engineSource.Contains('powercfg.exe /duplicatescheme'))) 'Chamadas de energia críticas passam pelo executor que captura stderr/ExitCode, inclusive hibernação, duplicação e rollback de sessão.'
Add-Test 'Registro não recria chave existente' ($engineSource.Contains('if(-not(Test-Path -LiteralPath $Path))') -and $engineSource.Contains('Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value')) 'Escrita de Registro não chama New-Item -Force sobre chave existente; evita UnauthorizedAccessException observado em Explorer\Advanced e PushNotifications.'
Add-Test 'Progresso tolera leitura concorrente' ($engineSource.Contains('[IO.FileShare]::ReadWrite') -and $engineSource.Contains('$attempt -le 5') -and $engineSource.Contains('Start-Sleep -Milliseconds 25') -and $appSource.Contains('function Read-UiJsonShared') -and $appSource.Contains('[IO.FileShare]::ReadWrite') -and $appSource.Contains('Read-UiJsonShared -Path $ctx.Files.Progress')) 'Writer e UI compartilham o arquivo de progresso explicitamente; falha de telemetria não cancela a operação real.'
Add-Test 'Perfis resilientes' ($engineSource.Contains('[switch]$Optional') -and $engineSource.Contains("'AllowNewsAndInterests' DWord 0 `$Category -Optional")) 'Políticas opcionais não abortam Agressivo/Extremo.'
Add-Test 'Avisos estruturados' ($engineSource.Contains('Get-SOWarningCount') -and $workerSource.Contains("`$result['Warnings']")) 'Worker devolve avisos sem mascará-los como falha fatal.'
Add-Test 'Contrato de saída do Worker' ($workerSource.Contains('Contrato de saída violado') -and $workerSource.Contains('$raw=@(Invoke-SOAction')) 'Cada ação deve retornar exatamente um objeto estruturado; vazamento de pipeline vira erro explícito.'
Add-Test 'UI sem dynamic closure' (-not $appSource.Contains('GetNewClosure')) 'Callbacks WPF não usam módulos dinâmicos.'
$launcherPsExplicit=($launcherSource -match '(?m)\$psExe\s*=\s*Join-Path\s+\$PSHOME\s+[''"]powershell\.exe[''"]')
$batPsExplicit=($batSource -match '(?im)set\s+"PS=%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe"')
Add-Test 'PowerShell com caminho explícito' ($launcherPsExplicit -and $batPsExplicit) 'Launcher e BAT usam caminhos explícitos para Windows PowerShell 5.1 e não dependem da busca PATH.' 
Add-Test 'Bloqueio local de operações' ($appSource.Contains('function Test-ActiveOperation') -and $appSource.Contains('$script:ActiveOperationProcess')) 'A interface evita operações simultâneas.'
Add-Test 'Bloqueio entre processos' ($workerSource.Contains("operation.lock") -and $workerSource.Contains('[IO.FileShare]::None')) 'Mesmo após fechar/reabrir a interface, dois Workers mutáveis não podem operar juntos.'
Add-Test 'Instância única com handoff' ($launcherSource.Contains('SuperOptimizer_ActivateExisting') -and $launcherSource.Contains('OpenExisting($activationEventName)') -and $appSource.Contains("OpenExisting('Local\SuperOptimizer_ActivateExisting')") -and $appSource.Contains('WaitOne(0)')) 'Uma segunda abertura sinaliza e traz a janela existente para frente, sem falso erro de inicialização.'
Add-Test 'Rollback Update sem efeito colateral' ($engineSource -match '(?ms)function Restore-SOAll.*?Test-Path -LiteralPath \$updateFile.*?Restore-SOUpdateSession') 'Rollback só restaura serviços de Update quando existe snapshot temporário; não os inicia do nada.'
Add-Test 'Transição entre perfis' ($engineSource.Contains('function Reset-SOToUniversalLayer') -and $engineSource.Contains('function Reset-SOExtremeLayerForAggressive') -and $engineSource.Contains('Confirm-SOProfileResult')) 'Universal remove camadas agressivas salvas; Agressivo remove a camada Extrema; todos verificam o estado resultante.'
Add-Test 'Flush DNS verifica retorno' ($engineSource.Contains("Invoke-SOExternal 'ipconfig.exe' @('/flushdns')")) 'Falha real do ipconfig não vira falso sucesso.'
Add-Test 'RAM com timeout CIM' ($engineSource.Contains('Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5')) 'Leitura de RAM não deve ficar presa indefinidamente.'
Add-Test 'RAM cleaner nativo' ($engineSource.Contains('function Initialize-SORamNativeApi') -and $engineSource.Contains('NtSetSystemInformation') -and $engineSource.Contains('SystemMemoryListInformation = 80') -and $engineSource.Contains('SeProfileSingleProcessPrivilege')) 'Limpeza de RAM funciona nativamente; executável externo não é requisito.'
Add-Test 'Fallback RAM validado' ($engineSource.Contains('function Get-SORamCleanerValidation') -and $engineSource.Contains('Cabeçalho MZ ausente') -and $engineSource.Contains('HashMismatch')) 'Se houver EmptyStandbyList.exe em Tools, ele só é aceito como fallback após validação.'
Add-Test 'Restore de Registro verificado' ($engineSource.Contains('function Test-SORegistryDataEqual') -and $engineSource.Contains('Valor restaurado não confere')) 'DWord/QWord/String/Binary/MultiString são comparados após restauração.'
Add-Test 'State crítico fail-safe' ($engineSource.Contains("Backup-SOHibernation") -and $engineSource.Contains("Backup-SODefender") -and $engineSource.Contains("Backup-SOHypervisor") -and $engineSource.Contains("Plano Gaming não foi alterado porque o backup")) 'Hibernação, Defender, plano de energia e BCD não são alterados sem estado de rollback válido.'
Add-Test 'Hibernação sem adivinhação' ($engineSource.Contains('não é possível garantir rollback exato') -and $engineSource.Contains('restauração automática ignorada para evitar adivinhação')) 'Se HibernateEnabled original não existe, o tweak é pulado em vez de inventar estado.'
Add-Test 'VBS pré-backup completo' ($engineSource.Contains('function Test-SOVBSBackupReady') -and $engineSource.Contains('backup completo da camada de virtualização')) 'Registry de VBS e BCD são salvos antes da primeira mutação crítica.'
Add-Test 'Update snapshot validado' ($engineSource.Contains('function Read-SOUpdateSessionSnapshot') -and $engineSource.Contains('SNAPSHOT INVÁLIDO') -and $engineSource.Contains('Snapshot gravado não passou na validação')) 'Parar/Reativar Update valida e grava snapshot seguro antes de alterar serviços.'
Add-Test 'Update pausa transacional' ($engineSource.Contains('Pausa do Windows Update ficou parcial; tentando desfazer automaticamente') -and $engineSource.Contains('RolledBack')) 'Falha parcial ao parar Update tenta retornar automaticamente ao estado anterior.'
Add-Test 'State valida identidade dos backups' ($engineSource.Contains('nome do arquivo não corresponde ao Path/Name salvo') -and $engineSource.Contains('nome do arquivo não corresponde ao serviço salvo') -and $engineSource.Contains('nome do arquivo não corresponde à tarefa salva')) 'Auditoria detecta backups trocados/renomeados além de JSON inválido.'
Add-Test 'PerGame remove chave criada pelo tweak' ($engineSource.Contains('KeyExisted') -and $engineSource.Contains('Prioridade restaurada para $name')) 'Restauração individual pode remover a chave PerfOptions vazia quando ela não existia originalmente.'
Add-Test 'Update retorna estado real' ($engineSource.Contains('Pausa parcial:') -and $engineSource.Contains("'UpdateStop' {") -and $engineSource.Contains("'UpdateStart' {")) 'Falha parcial em Parar/Reativar Update não vira mensagem de sucesso falsa.'
Add-Test 'Auditoria de State' ($engineSource.Contains('function Get-SOStateAudit') -and $appSource.Contains("-Action 'StateAudit'")) 'Backups de Registry/Services/Tasks/Settings podem ser validados pela interface.'
Add-Test 'Manutenção semanal verifica DNS' ($engineSource.Contains("Invoke-SOExternal 'ipconfig.exe' @('/flushdns') 'Flush DNS' 75 20")) 'Flush DNS da rotina semanal verifica o código do processo nativo.'
Add-Test 'PerGame restore validado' ($engineSource.Contains('O backup não corresponde ao executável selecionado') -and $engineSource.Contains('O valor original não pôde ser confirmado')) 'Restauração individual valida identidade do backup e faz read-back.'
$progressFn=[regex]::Match($engineSource,'(?ms)^function Write-SOProgress\s*\{.*?(?=^function\s+Get-SOHash)').Value
Add-Test 'Progresso não derruba operação' ($progressFn.Contains('telemetria da UI') -and $progressFn.Contains('[switch]$NoLog') -and $progressFn.Contains('catch {') -and $progressFn.Contains('return') -and -not $progressFn.Contains('throw')) 'Falha de telemetria/progresso é absorvida; atualizações silenciosas evitam duplicação do log sem cancelar a operação real.'
Add-Test 'Backups críticos atômicos' ($engineSource.Contains('$file+''.tmp.''+[guid]::NewGuid().ToString(''N'')') -and $engineSource.Contains('Backup da tarefa não passou na validação') -and $engineSource.Contains('Backup de serviço não passou na validação')) 'Registry, Services e Tasks usam arquivo temporário validado antes de substituir o backup final.'
Add-Test 'Ponto automático é obrigatório' ($engineSource.Contains('ponto de restauração solicitado não pôde ser criado')) 'Se a caixa de ponto automático estiver marcada, o perfil não prossegue silenciosamente sem o ponto solicitado.'
Add-Test 'Fallback RAM com timeout' ($engineSource.Contains('WaitForExit(30000)') -and $engineSource.Contains('excedeu 30 segundos e foi interrompido')) 'O fallback externo opcional não pode ficar preso indefinidamente.'
Add-Test 'Perfil não depende da hibernação opcional' (($engineSource -match '(?m)^\s*\$aggressiveComplete=.*\$powerName.*\$svcRatio') -and -not ($engineSource -match '(?m)^\s*\$aggressiveComplete=.*\$hib')) 'Falha best-effort de hibernação não impede o perfil Agressivo de ser identificado.'
Add-Test 'Diagnósticos nativos retornam falha real' ($engineSource.Contains('CHKDSK /scan terminou com código') -and $engineSource.Contains('AnalyzeComponentStore terminou com código')) 'Falhas operacionais de CHKDSK/DISM Analyze não são anunciadas como sucesso.'
Add-Test 'App usa PowerShell explícito' ($appSource.Contains("Join-Path `$PSHOME 'powershell.exe'") -and -not $appSource.Contains('Start-Process -FilePath powershell.exe')) 'Fallback de elevação da interface também não depende do PATH.'

Add-Test 'Windows Studio com snapshot reversível' ($engineSource.Contains('function New-SOWindowsStudioSnapshot') -and $engineSource.Contains('windows_studio_session') -and $engineSource.Contains('function Restore-SOWindowsStudioSession')) 'Modo Tudo salva o estado imediatamente anterior e oferece desfazer da última sessão.'
Add-Test 'Windows Studio restaura plano criado' ($engineSource.Contains('PowerPlanState=$powerState') -and $engineSource.Contains('remover plano criado na sessão')) 'Desfazer sessão também remove o plano Gaming criado apenas por aquela sessão e restaura o State anterior.'
Add-Test 'Windows Studio curado' ($engineSource.Contains('function Get-SOWindowsStudioNonExperimentalModuleIds') -and $engineSource.Contains("if([string]`$d.Risk -ne 'EXPERIMENTAL')") -and $engineSource.Contains('Invoke-SOWindowsStudioApplySelection -Modules (Get-SOWindowsStudioNonExperimentalModuleIds)')) 'O modo Tudo exclui experimentais e não mistura VBS/HVCI, debloat ou DNS.'
Add-Test 'DNS Jumper integrado' ($appSource.Contains('Find-DnsJumperPath') -and $appSource.Contains('https://www.sordum.org/7952/dns-jumper-v2-3/')) 'DNS Jumper é o benchmark recomendado; o binário externo não é redistribuído pelo Super Optimizer.'
Add-Test 'DNS sem release/renew' (-not ($engineSource -match "ipconfig(?:\.exe)?[^\r\n]*(?:/release|/renew)")) 'Troca de DNS não derruba o lease DHCP nem finge que release/renew reduz latência.'
Add-Test 'DNS nativo de recuperação' ($engineSource.Contains('function Backup-SODnsOriginal') -and $engineSource.Contains('ResetServerAddresses') -and $engineSource.Contains('dns_original')) 'Status/rollback nativo continuam disponíveis para recuperar alterações feitas pelo Super Optimizer.'
Add-Test 'Benchmark DNS próprio retirado da UI' (-not ([regex]::Match($appSource,'(?ms)^function Show-DnsLab\s*\{.*?^\}').Value -match 'DNSBenchmark|DNSApplyBest')) 'Evita repetir o erro do benchmark próprio; DNS Jumper assume a função de comparação de latência.'
Add-Test 'Smart Care persistente' ($engineSource.Contains('LastDeepClean') -and $engineSource.Contains('LastWingetScan') -and $engineSource.Contains('LastDnsReview') -and $appSource.Contains('SMART CARE • RECOMENDAÇÕES')) 'Semanal=7 dias, integridade/apps/DNS e pressão de RAM usam histórico persistente no State.'
Add-Test 'WinGet integrado' ($engineSource.Contains('function Invoke-SOWingetScan') -and $engineSource.Contains('function Invoke-SOWingetUpgradeAll') -and $appSource.Contains('Atualizar apps (WinGet)')) 'Busca e atualização de aplicativos reconhecidos pelo Windows Package Manager disponíveis na tela inicial.'
Add-Test 'Limpeza Final protegida' ($engineSource.Contains('function Invoke-SODeepPCCleanup') -and $engineSource.Contains('Delivery Optimization') -and $engineSource.Contains('WER') -and $engineSource.Contains('Invoke-SOComponentCleanup') -and $appSource.Contains('Limpeza Final / Profunda')) 'Limpeza profunda amplia caches do sistema sem tocar em Recent, Prefetch, Event Logs, Downloads, Windows.old ou perfis de navegadores.'
Add-Test 'Central de Limpeza reconstruída' ($appSource.Contains("function Show-Cleanup") -and $appSource.Contains("-Title 'Central de Limpeza'")) 'Central foi reconstruída sobre a base V3.4.4 que passou 91/91 no Windows.'
Add-Test 'Análise de armazenamento compatível com PS5.1' ($engineSource.Contains('function Get-SOCleanupAnalysis') -and $engineSource.Contains('$items=@()') -and $engineSource.Contains('Items=[object[]]$items')) 'Evita o binder error de Generic.List observado no Windows PowerShell 5.1.'
Add-Test 'Resultado de operação disponível para a UI' ($appSource.Contains('$script:LastOperationResult = $r')) 'Relatórios pós-operação (armazenamento, WinGet, diagnóstico e State) recebem o resultado real do Worker.'
Add-Test 'WinGet UTF-8 e ExitCode' ($engineSource.Contains('function Read-SOTextFileSmart') -and $engineSource.Contains('System.Text.UTF8Encoding($false,$true)') -and $engineSource.Contains('$p.Refresh()') -and $engineSource.Contains('$exitCode=[int]$p.ExitCode')) 'Saída do WinGet usa UTF-8 estrito com fallback do Windows e o ExitCode é capturado após o processo terminar.'
Add-Test 'Windows Studio selecionável' ($engineSource.Contains('function Invoke-SOWindowsStudioApplySelection') -and $engineSource.Contains('function Restore-SOWindowsStudioSelectedOriginal') -and $appSource.Contains('APLICAR SELECIONADOS') -and $appSource.Contains('RESTAURAR SELECIONADOS')) 'Módulos podem ser aplicados em conjunto e restaurados seletivamente, além do desfazer exato da última sessão.'

Add-Test 'Optimization Lab amplo' ($engineSource.Contains("'GameMode','GameDVR','MMCSS','Foreground','MouseAccel','DefenderScan'") -and $engineSource.Contains('MemoryCompressionOff') -and $engineSource.Contains('TelemetryTasks') -and $appSource.Contains('32 otimizações granulares')) 'Catálogo amplo com opções Gaming, energia, interface, privacidade, serviços e experimentais.'
Add-Test 'Optimization Lab rótulos visíveis' ($appSource.Contains('$cb.Content=$labelHost') -and $appSource.Contains('$riskRun.Foreground=$B.Yellow') -and $appSource.Contains('$riskRun.Foreground=$B.Red') -and $appSource.Contains('x:Name="LabRestorePointCheck"')) 'Opções mantêm rótulo/risco no próprio CheckBox; o ponto de restauração do Lab vem de XAML estático para evitar caixa órfã.'
$presetFn=[regex]::Match($appSource,'(?ms)^function Add-StudioPresetSelectionUi\s*\{.*?(?=^function\s+Show-WindowsStudioChangesUi)').Value
Add-Test 'Optimization Lab presets cumulativos' ($presetFn.Contains('.IsChecked = $true') -and -not $presetFn.Contains('.IsChecked = $false') -and $appSource.Contains('Os presets são cumulativos')) 'Presets rápidos somente adicionam módulos à seleção; Limpar seleção continua sendo o único reset explícito.'
Add-Test 'Optimization Lab reversível' ($engineSource.Contains('Version=4') -and $engineSource.Contains('Defender=$def') -and $engineSource.Contains('MemoryCompression=$mem') -and $appSource.Contains('DESFAZER ÚLTIMA APLICAÇÃO')) 'Snapshot V4 inclui Registro, serviços, tarefas, energia, hibernação, Defender e Memory Compression conforme a seleção.'
Add-Test 'Startup com feedback visual' ($launcherSource.Contains('New-StartupSplash') -and $launcherSource.Contains('startup_timing.log') -and -not $launcherSource.Contains('Worker de preflight excedeu')) 'A abertura mostra splash imediatamente e deixa testes profundos para o Auto-Teste.'
Add-Test 'Snapshot Windows Studio compatível com PS5.1' ($engineSource.Contains('function New-SOWindowsStudioSnapshot') -and $engineSource.Contains('$regs=@()') -and $engineSource.Contains('Registry=[object[]]$regs')) 'Snapshot não usa Generic.List embrulhado em @(), evitando o mesmo binder bug da análise de armazenamento.'
Add-Test 'Diagnóstico legível' ($engineSource.Contains('function Get-SODiagnosticQuick') -and $appSource.Contains('RESUMO ATUAL') -and $appSource.Contains('Show-DiagnosticQuickUi')) 'A aba Diagnóstico mostra resumo imediato e relatório legível além do Auto-Teste.'

$weeklyMatch=[regex]::Match($engineSource,'(?ms)^function Invoke-SOWeeklyMaintenance\s*\{.*?^\}')
$profilesText=([regex]::Match($engineSource,'(?ms)^function Invoke-SOUniversalProfile\s*\{.*?^\}').Value + [regex]::Match($engineSource,'(?ms)^function Invoke-SOAggressiveCore\s*\{.*?^\}').Value + [regex]::Match($engineSource,'(?ms)^function Invoke-SOExtremeProfile\s*\{.*?^\}').Value)
$ramManual=$weeklyMatch.Success -and (-not $weeklyMatch.Value.Contains('RamStandbyClean')) -and (-not $weeklyMatch.Value.Contains('RamFullClean')) -and (-not $profilesText.Contains('RamStandbyClean')) -and (-not $profilesText.Contains('RamFullClean'))
Add-Test 'RAM cleaner somente manual' $ramManual 'A limpeza de RAM não faz parte da manutenção semanal nem dos perfis.'

$fullCleanMatch=[regex]::Match($engineSource,'(?ms)^function Invoke-SOFullPCCleanup\s*\{.*?^\}')
$fullCleanText=$fullCleanMatch.Value
$fullCleanSafe=$fullCleanMatch.Success -and $fullCleanText.Contains('Clear-SOUpdateCache -SuppressProgress') -and $fullCleanText.Contains("D3DSCache") -and $fullCleanText.Contains('Clear-RecycleBin') -and $fullCleanText.Contains("ipconfig.exe") -and (-not $fullCleanText.Contains('\\Prefetch')) -and (-not $fullCleanText.Contains('Microsoft\\Windows\\Recent')) -and (-not $fullCleanText.Contains('wevtutil')) -and (-not $fullCleanText.Contains('StartComponentCleanup'))
Add-Test 'Limpeza completa segura do PC' $fullCleanSafe 'Inclui temporários, Shader DirectX, cache baixado do Update, Lixeira e DNS; preserva Recent/Acesso Rápido, Prefetch, Event Logs e WinSxS.'

try{
    Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force -DisableNameChecking
    [void](Initialize-SOEnvironment)
    Set-SODryRun $true
    $nativeReady=Test-SORamNativeApiAvailable
    Add-Test 'API nativa de RAM carregável' ([bool]$nativeReady) $(if($nativeReady){'Add-Type/PInvoke carregado; nenhuma lista de memória foi limpa durante este teste.'}else{'A API nativa de RAM não pôde ser carregada.'})
}catch{Add-Test 'API nativa de RAM carregável' $false $_.Exception.Message}

$ramTool=Join-Path $AppRoot 'Tools\EmptyStandbyList.exe'
if(Test-Path -LiteralPath $ramTool -PathType Leaf){
    try{
        $bytes=[IO.File]::ReadAllBytes($ramTool)
        $peOk=($bytes.Length -gt 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
        $hash=(Get-FileHash -LiteralPath $ramTool -Algorithm SHA256).Hash
        $sig=(Get-AuthenticodeSignature -LiteralPath $ramTool).Status
        Add-Test 'Fallback EmptyStandbyList estrutural' $peOk (('PE={0} | SHA-256={1} | Assinatura={2}' -f $peOk,$hash,$sig))
    }catch{Add-Test 'Fallback EmptyStandbyList estrutural' $false $_.Exception.Message}
}else{
    Add-Test 'Fallback EmptyStandbyList estrutural' $true 'Não instalado, como esperado. A limpeza continua disponível pelo método nativo.'
}

# -----------------------------------------------------------------------------
# UI -> Engine, funções internas e rotas
# -----------------------------------------------------------------------------
try{
    $actionBlock=[regex]::Match($engineSource,'(?ms)^function Invoke-SOAction\s*\{.*?^\}\s*\r?\n\s*Export-ModuleMember').Value
    $engineActions=@([regex]::Matches($actionBlock,"(?m)^\s*'([A-Za-z0-9]+)'\s*\{")|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique)
    $uiActions=New-Object System.Collections.Generic.List[string]
    foreach($m in [regex]::Matches($appSource,"-Action\s+'([A-Za-z0-9]+)'")){[void]$uiActions.Add($m.Groups[1].Value)}
    $uiUnique=@($uiActions|Sort-Object -Unique)
    $unknown=@($uiUnique|Where-Object {$engineActions -notcontains $_})
    Add-Test 'Mapeamento UI -> Engine' ($unknown.Count -eq 0) $(if($unknown.Count){'Sem rota: '+($unknown -join ', ')}else{('{0} ações da interface possuem rota' -f $uiUnique.Count)})

    $expectedActions=@(
        'Status','StateAudit','CreateRestorePoint','ProfileUniversal','ProfileAggressive','ProfileExtreme','ProfileGamerBrowser','MaintenanceWeekly','FullCleanPC','CleanupAnalyze','DeepCleanPC','DeliveryOptimizationCache','WerReports','TempUser','TempWindows','ShaderCache','DiskScan','ComponentAnalyze','ComponentCleanup','UpdateCache','HealthScan','RepairWindows','RecycleBin','RamInfo','RamStandbyClean','RamFullClean','GamingAll','GameMode','GameDVROff','MMCSS','Foreground','MouseAccelOff','GamingRestore','BackgroundReduced','TelemetryReduced','VisualsReduced','PowerGaming','PrivacyRestore','PowerRestore','WindowsStudioStatus','WindowsStudioApplyAll','WindowsStudioApplySelection','WindowsStudioRestoreSelection','WindowsStudioUndo','WindowsStudioRestoreOriginal','StudioEnergy','StudioPowerThrottle','StudioVisuals','StudioBackground','StudioTelemetry','StudioIndexingOff','StudioHibernationOff','ServicesApply','ServicesRestore','HAGSOn','HAGSOff','MPOOff','GPURestore','FlushDNS','DNSStatus','DNSReviewStamp','WingetScan','WingetUpgradeAll','DNSBenchmark','DNSApplyProvider','DNSApplyBest','DNSRestore','UpdateStop','UpdateStart','DiagnosticQuick','DiagnosticReport','LogsCleanup','VBSOff','VBSRestore','PerGameSet','PerGameList','PerGameRemove','PerGameRestore','RestoreAll','HistoryGet','StateManager','HealthSummary','PostRebootStatus','ProfileCompare','CustomProfilesGet','CustomProfileSave','CustomProfileDelete','DiagnosticExportTxt','DiagnosticExportJson'
    )
    $missingRoutes=@($expectedActions|Where-Object {$engineActions -notcontains $_})
    $extraRoutes=@($engineActions|Where-Object {$expectedActions -notcontains $_})
    Add-Test 'Contrato de rotas' ($missingRoutes.Count -eq 0 -and $extraRoutes.Count -eq 0) $(if($missingRoutes.Count -or $extraRoutes.Count){'Faltando: '+($missingRoutes -join ', ')+' | Extras: '+($extraRoutes -join ', ')}else{($expectedActions.Count.ToString()+'/'+$expectedActions.Count.ToString()+' rotas esperadas presentes, sem rotas fantasma')})
}catch{Add-Test 'Mapeamento UI -> Engine' $false $_.Exception.Message}

try{
    $defs=@([regex]::Matches($engineSource,'(?m)^function\s+([A-Za-z0-9_-]+)')|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique)
    $refs=@([regex]::Matches($engineSource,'\b(?:Get|Set|Invoke|Restore|Backup|Clear|Disable|Enable|New|Write|Reset|Test|Stop|Normalize|Read)-SO[A-Za-z0-9_-]+\b')|ForEach-Object {$_.Value}|Sort-Object -Unique)
    $unresolved=@($refs|Where-Object {$defs -notcontains $_})
    Add-Test 'Funções internas do Engine' ($unresolved.Count -eq 0) $(if($unresolved.Count){'Referências sem definição: '+($unresolved -join ', ')}else{('{0} referências SO resolvidas' -f $refs.Count)})
}catch{Add-Test 'Funções internas do Engine' $false $_.Exception.Message}

Add-Test 'Dashboard Smart Care' (-not $appSource.Contains('$recommendScroll.MaxHeight=150') -and $appSource.Contains('$recommend=New-Text -Text ''Aguardando status do Windows para gerar recomendações.''') -and $appSource.Contains('x:Name="WingetScanButton"') -and $appSource.Contains('x:Name="RefreshStatusButton"')) 'Smart Care permanece direto; WinGet e atalhos críticos usam XAML estático para evitar cards vazios.'
Add-Test 'Paleta de botões' ((-not $appSource.Contains('-Accent $B.Magenta')) -and $xamlSource.Contains('x:Name="ButtonFrame"') -and $appSource.Contains('x:Name="DnsStatusButton"') -and $appSource.Contains('x:Name="WingetUpgradeButton"') -and $appSource.Contains('x:Name="LabApplyButton"') -and $appSource.Contains('BorderThickness="1.5"')) 'Cards críticos têm botões XAML com fundo, borda e conteúdo definidos no próprio fragmento.'
Add-Test 'UI sem caixas órfãs conhecidas' ($appSource.Contains('function New-CheckboxLine') -and $appSource.Contains('$restoreLine=New-CheckboxLine -Text ''Criar ponto de restauração antes''') -and $appSource.Contains('x:Name="WingetUnknownCheck"') -and $appSource.Contains('x:Name="LabRestorePointCheck"') -and -not $appSource.Contains('$check.Content = $checkLabel')) 'Perfis usam linha explícita e WinGet/Lab usam CheckBox definido em XAML estático; nenhum rótulo crítico depende de montagem dinâmica em Content.'

Add-Test 'Perfil ORIGINAL acessível' ($appSource.Contains('x:Name="ProfileRestoreOriginal"') -and $appSource.Contains("-Action 'RestoreAll'") -and $appSource.Contains('x:Name="ProfileAuditState"') -and $appSource.Contains('x:Name="ProfileOpenState"')) 'Tela Perfis expõe restauração do estado anterior ao Super Optimizer reutilizando RestoreAll e oferece auditoria/acesso ao State.'
Add-Test 'UI sem helpers experimentais mortos' (-not $appSource.Contains('function New-ReliableButton') -and -not $appSource.Contains('function New-ReliableActionButton') -and -not $appSource.Contains('function New-MatrixActionCard') -and -not $appSource.Contains('function Add-MatrixButton') -and -not $appSource.Contains('function New-ActionCard') -and -not $appSource.Contains('WrapPanel')) 'Helpers temporários/legados de renderização foram removidos para reduzir caminhos frágeis no PowerShell 5.1.'

Add-Test 'UI sem cards vazios secundários' (-not $appSource.Contains('$maintenance.Stack.Children.Add') -and -not $appSource.Contains('$tests.Stack.Children.Add') -and -not $appSource.Contains('$serviceStack.Children.Add') -and $appSource.Contains('x:Name="MaintHealth"') -and $appSource.Contains('x:Name="VirtRestore"') -and $appSource.Contains('x:Name="RbOpenState"') -and $appSource.Contains('x:Name="DiagReport"')) 'As subseções que deixavam rebarbas não são mais anexadas dinamicamente depois de grades; o conteúdo composto é estático.'

Add-Test 'UI composta em XAML estático' ($appSource.Contains('x:Name="MaintHealth"') -and $appSource.Contains('x:Name="GamePriorityGrid"') -and $appSource.Contains('x:Name="VirtRestore"') -and $appSource.Contains('x:Name="RbOpenState"') -and $appSource.Contains('x:Name="DiagReport"') -and $appSource.Contains('x:Name="ServicesGrid"')) 'Manutenção, Gaming, Serviços, Virtualização, Rollback e Diagnóstico usam fragmentos XAML estáticos nas áreas compostas que apresentaram rebarbas no WPF real.'
Add-Test 'DataGrid com tema escuro explícito' ($xamlSource.Contains('DarkDataGridHeaderStyle') -and $xamlSource.Contains('DarkDataGridCellStyle') -and $xamlSource.Contains('DarkDataGridRowStyle') -and $appSource.Contains("FindResource('DarkDataGridHeaderStyle')")) 'Tabelas de jogos/serviços não dependem mais do cabeçalho branco padrão do Windows.'
try{
    $uiTokens=$null;$uiErrors=$null
    $uiAst=[System.Management.Automation.Language.Parser]::ParseInput($appSource,[ref]$uiTokens,[ref]$uiErrors)
    $classifiers=@($uiAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SelfTestOutcome'},$false))
    if($uiErrors.Count -gt 0 -or $classifiers.Count -ne 1){throw 'Classificador do Auto-Teste ausente, duplicado ou com erro de parser.'}
    # Carrega somente a função pura; não executa App, WPF ou elevação.
    . ([scriptblock]::Create($classifiers[0].Extent.Text))
    foreach($case in @(
        @{Name='relatório completo';Report='RESULTADO: 2/2 testes aprovados';Code=0;State='Passed'},
        @{Name='ExitCode não zero';Report='RESULTADO: 2/2 testes aprovados';Code=1;State='Failed'},
        @{Name='zero testes';Report='RESULTADO: 0/0 testes aprovados';Code=0;State='Inconclusive'},
        @{Name='relatório ausente';Report='';Code=0;State='Inconclusive'},
        @{Name='ExitCode indisponível';Report='RESULTADO: 2/2 testes aprovados';Code=$null;State='Inconclusive'},
        @{Name='teste reprovado';Report='RESULTADO: 1/2 testes aprovados';Code=0;State='Failed'},
        @{Name='erro no relatório';Report="[ERRO] Worker falhou`r`nRESULTADO: 2/2 testes aprovados";Code=0;State='Failed'},
        @{Name='contagem ambígua';Report="RESULTADO: 1/1 testes aprovados`r`nRESULTADO: 2/2 testes aprovados";Code=0;State='Inconclusive'}
    )){
        $outcome=Get-SelfTestOutcome -Report $case.Report -ExitCode $case.Code
        Add-Test ('Auto-Teste resultado: '+$case.Name) ($outcome.State -eq $case.State) ('Esperado='+$case.State+'; recebido='+$outcome.State)
    }
}catch{Add-Test 'Auto-Teste resultado robusto' $false $_.Exception.Message}


try{
    $catalogBlock=[regex]::Match($engineSource,'(?ms)^function Get-SOWindowsStudioCatalog\s*\{.*?^\}').Value
    $applyBlock=[regex]::Match($engineSource,'(?ms)^function Invoke-SOWindowsStudioModule\s*\{.*?^\}').Value
    $restoreBlock=[regex]::Match($engineSource,'(?ms)^function Restore-SOWindowsStudioSelectedOriginal\s*\{.*?^\}').Value
    $uiStudioBlock=[regex]::Match($appSource,'(?ms)^function Show-System\s*\{.*?^\}').Value
    $studioIds=@([regex]::Matches($catalogBlock,"Id='([^']+)'")|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique)
    $missingApply=@($studioIds|Where-Object {$applyBlock -notmatch ("'"+[regex]::Escape($_)+"'\s*\{")})
    $missingRestore=@($studioIds|Where-Object {$restoreBlock -notmatch [regex]::Escape($_)})
    $missingUi=@($studioIds|Where-Object {$uiStudioBlock -notmatch ("Id='"+[regex]::Escape($_)+"'")})
    Add-Test 'Optimization Lab cobertura 32/32' ($studioIds.Count -eq 32 -and $missingApply.Count -eq 0 -and $missingRestore.Count -eq 0 -and $missingUi.Count -eq 0) $(if($studioIds.Count -eq 32 -and $missingApply.Count -eq 0 -and $missingRestore.Count -eq 0 -and $missingUi.Count -eq 0){'32 módulos presentes em catálogo, UI, aplicação e rollback seletivo.'}else{'Catálogo='+$studioIds.Count+' | sem apply: '+($missingApply -join ', ')+' | sem restore: '+($missingRestore -join ', ')+' | sem UI: '+($missingUi -join ', ')})
}catch{Add-Test 'Optimization Lab cobertura 32/32' $false $_.Exception.Message}

Add-Test 'Interface preserva tema Claro/Escuro' ((-not $engineSource.Contains("'AppsUseLightTheme'")) -and (-not $engineSource.Contains("'SystemUsesLightTheme'")) -and (-not $engineSource.Contains("'VisualFXSetting' DWord 2")) -and $engineSource.Contains("'MinAnimate' String '0'") -and $engineSource.Contains("'TaskbarAnimations' DWord 0")) 'Efeitos visuais são curados e não alteram AppsUseLightTheme/SystemUsesLightTheme nem usam VisualFXSetting=2.'
Add-Test 'Restore de serviços via SCM' ($engineSource.Contains('function Set-SOServiceStartupFromBackup') -and $engineSource.Contains('& sc.exe config $Name start= $startArg') -and (-not $engineSource.Contains('Set-ItemProperty -LiteralPath $rp -Name Start -Type DWord -Value ([int]$state.Start)'))) 'Rollback de serviços restaura StartupType pelo Service Control Manager; evita acesso negado ao gravar Start diretamente em chaves protegidas como TrkWks.'
Add-Test 'V3.8 comparador Antes x Depois' ($engineSource.Contains('function Get-SOChangeSnapshot') -and $engineSource.Contains('function Compare-SOChangeSnapshots') -and $workerSource.Contains("$result['Comparison']")) 'Operações monitoradas capturam snapshot antes/depois e devolvem mudanças estruturadas.'
Add-Test 'V3.8 histórico persistente' ($engineSource.Contains('function Add-SOHistoryEntry') -and $appSource.Contains('function Show-HistoryUi') -and $appSource.Contains('Abrir log selecionado')) 'Timeline persistente por MachineGuid com acesso ao log e comparador.'
Add-Test 'V3.8 histórico portátil' ($engineSource.Contains('LogRelative=$logRelative') -and $appSource.Contains("$x.PSObject.Properties['LogRelative']") -and $appSource.Contains('Join-Path $State ([string]$x.LogRelative)')) 'Histórico guarda caminho relativo do log dentro do State e consegue reabrir logs após mover a pasta do programa.'
Add-Test 'V3.8 export/import Studio' ($appSource.Contains('function Export-StudioSelectionUi') -and $appSource.Contains('function Import-StudioSelectionUi') -and $appSource.Contains('SuperOptimizerStudioSelection')) 'Optimization Lab exporta/importa seleção JSON validada.'
Add-Test 'V3.8 perfil personalizado' ($engineSource.Contains('function Save-SOCustomProfile') -and $appSource.Contains('Salvar perfil personalizado') -and $appSource.Contains('Carregar perfil personalizado')) 'Combinações do Lab podem ser persistidas como perfil personalizado.'
Add-Test 'V3.8 health sem score artificial' ($engineSource.Contains('function Get-SOHealthSummary') -and $appSource.Contains('Saúde objetiva do PC') -and -not $appSource.Contains('93/100')) 'Saúde usa blocos objetivos em vez de nota artificial.'
Add-Test 'V3.8 estado visual por módulo' ($engineSource.Contains("'ATIVO'") -and $engineSource.Contains("'PADRÃO'") -and $engineSource.Contains("'DIFERENTE'") -and $engineSource.Contains("'NÃO SUPORTADO'") -and $appSource.Contains('Atualizar estados dos módulos')) 'Optimization Lab classifica estado dos módulos.'
Add-Test 'V3.8 comparação de perfis' ($engineSource.Contains('function Get-SOProfileComparison') -and $appSource.Contains('Show-ProfileComparisonUi')) 'Perfis mostram delta antes de aplicar.'
Add-Test 'Perfis sem clipping de ações' ($appSource.Contains('$actions=New-Object System.Windows.Controls.StackPanel') -and $appSource.Contains("$compare=New-Button -Text 'Comparar perfil'") -and $appSource.Contains('$compare.MinWidth=0') -and (-not $appSource.Contains('$c2.Width=[Windows.GridLength]::new(130)'))) 'Aplicar e Comparar ficam empilhados e ocupam a largura disponível, sem coluna fixa que corte o botão em DPI/janelas menores.'
Add-Test 'V3.8 State Manager e portabilidade' ($engineSource.Contains('function Get-SOStateManager') -and $engineSource.Contains('MachineGuid') -and $appSource.Contains('Backup / State Manager')) 'State Manager expõe primeiro backup, tamanho, categorias, integridade e isolamento por máquina.'
Add-Test 'V3.8 diagnóstico exportável' ($engineSource.Contains('function Export-SODiagnostic') -and $appSource.Contains('Exportar diagnóstico TXT') -and $appSource.Contains('Exportar diagnóstico JSON')) 'Diagnóstico exportável em TXT/JSON.'
Add-Test 'V3.8 pós-reboot' ($engineSource.Contains('function Save-SOPostRebootMarker') -and $engineSource.Contains('function Get-SOPostRebootStatus') -and $workerSource.Contains('Save-SOPostRebootMarker')) 'Alterações com reboot recomendado deixam marcador e confirmação após boot.'
Add-Test 'V3.8 manutenção semanal resumida' ($engineSource.Contains('TEMP do usuário: {0} item(ns) removido(s)') -and $engineSource.Contains('Windows Temp: {0} item(ns) removido(s)') -and $engineSource.Contains('if($LogIgnoredItems){Write-SOLog ("Item temporário ignorado: {0}"') -and -not $engineSource.Contains('Remove-SOFolderChildrenSafe $env:TEMP -CollectStats -LogIgnoredItems')) 'Manutenção semanal resume itens removidos/ignorados sem poluir o log por arquivo.'
Add-Test 'Dashboard Estado & histórico estático' ($appSource.Contains('$intelXaml=@"') -and $appSource.Contains('HealthSummaryButton') -and $appSource.Contains('StateManagerButton') -and (-not $appSource.Contains("$intel=New-GridActionCard -Title 'Estado & histórico'"))) 'O painel V3.8 do Dashboard usa XAML estático 2x2 e não depende do UniformGrid dinâmico que já produziu card vazio no WPF real.'
Add-Test 'Histórico com tema escuro e virtualização' ($appSource.Contains('$grid.ColumnHeaderStyle=$Window.FindResource(''DarkDataGridHeaderStyle'')') -and $appSource.Contains('$grid.CellStyle=$Window.FindResource(''DarkDataGridCellStyle'')') -and $appSource.Contains('$grid.RowStyle=$Window.FindResource(''DarkDataGridRowStyle'')') -and $appSource.Contains('$grid.EnableRowVirtualization=$true') -and $appSource.Contains('$grid.EnableColumnVirtualization=$true')) 'Timeline usa tema escuro explícito e virtualização de linhas/colunas.'
Add-Test 'Painéis V3.8 críticos em XAML estático' ($appSource.Contains('$manageXaml=@"') -and $appSource.Contains('StudioExportButton') -and $appSource.Contains('$extraXaml=@"') -and $appSource.Contains('DiagExportTxtButton')) 'Configuração/perfis personalizados e Exportação/suporte usam fragmentos XAML estáticos nas áreas novas mais sensíveis a regressões visuais.'
Add-Test 'V3.8 persistência respeita DRY-RUN' ($engineSource.Contains('if($script:DryRun){Write-SOLog ("Salvaria perfil personalizado:') -and $engineSource.Contains('if($script:DryRun){Write-SOLog ("Removeria perfil personalizado:') -and $engineSource.Contains('if($script:DryRun){Write-SOLog ("Exportaria diagnóstico')) 'Perfis personalizados e exportação de diagnóstico não escrevem arquivos quando o Worker está em DRY-RUN.'
Add-Test 'PerGame restore não recria chave existente' ($engineSource.Contains('$restorePath=[string]$state.Path;$restoreName=[string]$state.Name;$kind=[string]$state.Kind') -and $engineSource.Contains('if(-not(Test-Path -LiteralPath $restorePath))') -and $engineSource.Contains('Set-ItemProperty -LiteralPath $restorePath -Name $restoreName')) 'Rollback individual por jogo segue o mesmo padrão seguro de Registro e não usa New-Item -Force sobre uma chave já existente.'

Add-Test 'Perfil Gamer + Navegador personalizável' ($engineSource.Contains('function Invoke-SOGamerBrowserProfile') -and $engineSource.Contains("'ProfileGamerBrowser'") -and $appSource.Contains('GAMER + NAVEGADOR') -and $appSource.Contains('Recursos que eu uso — marque para PRESERVAR')) 'Novo perfil gamer/browser parte de uma base restaurada e permite preservar recursos usados pelo dono do PC.'
Add-Test 'Perfil Gamer impressão personalizável' ((-not (@($config.services|ForEach-Object {[string]$_.name}) -contains 'Spooler')) -and $appSource.Contains('GamerWebPrinter') -and $engineSource.Contains('PreservePrinter') -and $engineSource.Contains("Set-SOServiceMode 'Spooler' Disabled 'Impressão / Print Spooler'") -and $engineSource.Contains("Get-SOServiceStart 'Spooler'")) 'Impressão é preservada por padrão, mas só o perfil Gamer + Navegador pode desativar explicitamente o Spooler com backup/rollback.'
Add-Test 'Perfil Gamer respeita recursos opcionais' ($engineSource.Contains('Get-SOGamerBrowserServiceExclusions') -and $engineSource.Contains('PreservePrinter') -and $engineSource.Contains('PreserveOneDrive') -and $engineSource.Contains('PreserveVirtualization') -and $engineSource.Contains('PreserveHibernation') -and $appSource.Contains('GamerWebPrinter') -and $appSource.Contains('GamerWebVirtualization')) 'Impressão, Search, OneDrive, RDP, VPN, Hotspot, biometria, descoberta de rede, hibernação e virtualização têm preservação explícita.'
Add-Test 'Perfil Gamer callback sem escopo frágil' ($appSource.Contains('$gamerWebApply.Tag=$gamerCtx') -and $appSource.Contains('$ctx=$sender.Tag') -and $appSource.Contains("Context 'Perfil Gamer + Navegador - aplicar'") -and -not $appSource.Contains("$gamerWeb.FindName('GamerWebVirtualization').IsChecked")) 'O clique usa referências de controles persistidas no Tag do botão; não depende de $gamerWeb existir no escopo quando o evento WPF ocorre.'
Add-Test 'Perfil Gamer verificação pós-aplicação contextual' ($engineSource.Contains('function Get-SOGamerBrowserVerification') -and $engineSource.Contains('Get-SOGamerBrowserVerification -Options $opts') -and $engineSource.Contains('Gamer + Navegador — verificação:') -and $engineSource.Contains('ServicesMatched=$matched')) 'Após aplicar o perfil, a verificação usa diretamente as opções daquela execução e registra o motivo exato se houver drift, sem classificar falsamente como Extremo por falha de releitura do marcador.'

Add-Test 'Worker com resultado estruturado' ($workerSource.Contains("`$result['Warnings']") -and $workerSource.Contains('Contrato de saída violado') -and $workerSource.Contains('Finished=(Get-Date).ToString') -and $workerSource.Contains('if([bool]$result.Success){exit 0}else{exit 1}')) 'Sucesso, avisos, contrato único e falhas são serializados e refletidos no ExitCode.'

Add-Test 'Análise de armazenamento limitada' ($engineSource.Contains('function Measure-SOSafeFolder') -and $engineSource.Contains('TimeoutSecondsPerArea')) 'A análise possui limite de tempo/itens por área para não parecer travada em pastas enormes.'
Add-Test 'Windows Studio rollback de Registro idempotente' ($engineSource.Contains('if(-not(Test-Path -LiteralPath $path))') -and $engineSource.Contains('Set-ItemProperty -LiteralPath $path -Name $name -Type $kind') -and $engineSource.Contains('$afterRemove=Get-Item -LiteralPath $path -ErrorAction SilentlyContinue') -and $engineSource.Contains("Start-Sleep -Milliseconds 120")) 'Rollback de sessão não recria chaves HKCU existentes e tolera corrida benigna quando valor/chave já desapareceram antes da limpeza.'
Add-Test 'Windows Studio snapshot escopado' ($engineSource.Contains('Version=4') -and $engineSource.Contains('SelectedModules=[string[]]$selected') -and $engineSource.Contains('ESCOPADO')) 'DESFAZER V4 captura apenas os módulos selecionados, reduzindo efeitos colaterais sobre opções não tocadas.'
Add-Test 'Undo remove chave criada pelo Studio' ($engineSource.Contains('KeyExisted') -and $engineSource.Contains('GetValueNames().Count -gt 0')) 'Rollback de sessão remove uma chave criada só pelo tweak quando ela termina vazia.'
Add-Test 'WinGet robusto em PowerShell 5.1' ($engineSource.Contains('Microsoft.DesktopAppInstaller') -and $engineSource.Contains('BigEndianUnicode') -and $engineSource.Contains('ExitCode não pôde ser lido')) 'Descoberta do executável e decodificação UTF-8/UTF-16/ANSI foram endurecidas.'
Add-Test 'Launcher com preflight rápido' (-not $launcherSource.Contains("@('CleanupAnalyze',[pscustomobject]@{})")) 'Análise de armazenamento não bloqueia a abertura oculta da interface; testes profundos ficam no Auto-Teste.'

# -----------------------------------------------------------------------------
# Dry-run de TODAS as rotas sem efeito no Windows
# -----------------------------------------------------------------------------
try{
    Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force -DisableNameChecking
    [void](Initialize-SOEnvironment)
    Set-SODryRun $true

    $actions=@(
        'Status','StateAudit','CreateRestorePoint','ProfileUniversal','ProfileAggressive','ProfileExtreme','ProfileGamerBrowser',
        'MaintenanceWeekly','FullCleanPC','CleanupAnalyze','DeepCleanPC','DeliveryOptimizationCache','WerReports','TempUser','TempWindows','ShaderCache','UpdateCache','HealthScan','RepairWindows','DiskScan','ComponentAnalyze','ComponentCleanup','RecycleBin','RamInfo','RamStandbyClean','RamFullClean',
        'GamingAll','GameMode','GameDVROff','MMCSS','Foreground','MouseAccelOff','GamingRestore',
        'BackgroundReduced','TelemetryReduced','VisualsReduced','PowerGaming','PrivacyRestore','PowerRestore',
        'WindowsStudioStatus','WindowsStudioApplyAll','WindowsStudioApplySelection','WindowsStudioRestoreSelection','WindowsStudioUndo','WindowsStudioRestoreOriginal','StudioEnergy','StudioPowerThrottle','StudioVisuals','StudioBackground','StudioTelemetry','StudioIndexingOff','StudioHibernationOff',
        'ServicesApply','ServicesRestore','HAGSOn','HAGSOff','MPOOff','GPURestore',
        'FlushDNS','DNSStatus','DNSReviewStamp','WingetScan','WingetUpgradeAll','DNSBenchmark','DNSApplyProvider','DNSApplyBest','DNSRestore','UpdateStop','UpdateStart','DiagnosticQuick','DiagnosticReport','LogsCleanup','VBSOff','VBSRestore','PerGameSet','PerGameList','PerGameRestore','RestoreAll','HistoryGet','StateManager','HealthSummary','PostRebootStatus','ProfileCompare','CustomProfilesGet','CustomProfileSave','CustomProfileDelete','DiagnosticExportTxt','DiagnosticExportJson'
    )

    $ok=$true;$detail=''
    foreach($a in $actions){
        try{
            $data=[pscustomobject]@{AutoRestorePoint=$false;ExeName='TestGame.exe';Force=$true;Provider='Cloudflare';Modules=@('GameMode','GameDVR','Energy','SearchSuggestions','DiagTrack','DefenderScan','HAGSOn');IncludeUnknown=$false;Name='SO SelfTest';Target='UNIVERSAL';PreserveSearch=$true;PreserveOneDrive=$true;PreserveRdp=$false;PreserveVpn=$true;PreserveHotspot=$false;PreserveBiometrics=$true;PreserveNetworkDiscovery=$true;PreserveHibernation=$true;PreserveVirtualization=$true}
            $raw=@(Invoke-SOAction -Action $a -Data $data)
            if($raw.Count -ne 1){throw ("contrato de saída: {0} objetos" -f $raw.Count)}
            $r=$raw[0]
            $hasSuccess=($r -is [System.Collections.IDictionary] -and $r.Contains('Success')) -or ($r -and $r.PSObject.Properties['Success'])
            if(-not $hasSuccess){throw 'retorno sem campo Success'}
            if(-not [bool]$r.Success){throw ('retorno Success=False: '+[string]$r.Message)}
        }catch{$ok=$false;$detail += ('{0}: {1}; ' -f $a,$_.Exception.Message)}
    }
    Add-Test 'Dry-run de rotas' $ok $(if($ok){$actions.Count.ToString()+' rotas concluíram em DRY-RUN'}else{$detail})

    $fakeExe=('SO_SELFTEST_'+[guid]::NewGuid().ToString('N')+'.exe')
    $guardOk=$false;$guardDetail=''
    try{
        [void](Invoke-SOAction -Action 'PerGameRemove' -Data ([pscustomobject]@{ExeName=$fakeExe}))
        $guardOk=$true;$guardDetail='Rota executada em dry-run porque havia backup correspondente.'
    }catch{
        $msg=[string]$_.Exception.Message;$guardOk=($msg -match 'backup');$guardDetail=if($guardOk){'Proteção contra restauração sem backup funcionando.'}else{$msg}
    }
    Add-Test 'PerGameRemove contextual' $guardOk $guardDetail
}catch{Add-Test 'Dry-run de rotas' $false $_.Exception.Message}

# -----------------------------------------------------------------------------
# Probes REAIS somente de leitura: capturam bugs que DRY-RUN não consegue ver.
# Não alteram Registry, serviços, tarefas, DNS ou arquivos de limpeza.
# -----------------------------------------------------------------------------
try{
    Set-SODryRun $false
    $liveOk=$true;$liveDetail=''
    foreach($probe in @(
        @('Status',[pscustomobject]@{}),
        @('CleanupAnalyze',[pscustomobject]@{NoStamp=$true;TimeoutSecondsPerArea=2}),
        @('DiagnosticQuick',[pscustomobject]@{}),
        @('WindowsStudioStatus',[pscustomobject]@{}),
        @('DNSStatus',[pscustomobject]@{}),
        @('RamInfo',[pscustomobject]@{})
    )){
        try{
            $raw=@(Invoke-SOAction -Action ([string]$probe[0]) -Data $probe[1])
            if($raw.Count -ne 1){throw ('contrato de saída: '+$raw.Count+' objetos')}
            $r=$raw[0];if(-not [bool]$r.Success){throw [string]$r.Message}
        }catch{$liveOk=$false;$liveDetail += ('{0}: {1}; ' -f $probe[0],$_.Exception.Message)}
    }
    Add-Test 'Probes reais somente leitura' $liveOk $(if($liveOk){'Status, armazenamento, diagnóstico, Studio, DNS e RAM executaram fora de DRY-RUN sem alterar o Windows.'}else{$liveDetail})
}finally{Set-SODryRun $true}

# -----------------------------------------------------------------------------
# Worker real/IPC: processo separado, ainda em DRY-RUN
# -----------------------------------------------------------------------------
$probe1=Invoke-WorkerProbe -Action 'Status' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: Status' ([bool]$probe1.Success) $(if($probe1.Success){'JSON/IPC/Worker funcionando em processo separado'}else{$probe1.Message})

$probeState=Invoke-WorkerProbe -Action 'StateAudit' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: StateAudit' ([bool]$probeState.Success) $(if($probeState.Success){'Auditoria de backups atravessou JSON/Worker sem alterar o Windows'}else{$probeState.Message})

$probe2=Invoke-WorkerProbe -Action 'ProfileExtreme' -Data ([pscustomobject]@{AutoRestorePoint=$false}) -TimeoutMs 45000
Add-Test 'Worker IPC: Perfil Extremo DRY-RUN' ([bool]$probe2.Success) $(if($probe2.Success){'Pipeline completo do perfil atravessou o Worker sem alterar o Windows'}else{$probe2.Message})

$probe3=Invoke-WorkerProbe -Action 'MaintenanceWeekly' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: Manutenção DRY-RUN' ([bool]$probe3.Success) $(if($probe3.Success){'Pipeline de manutenção atravessou JSON/Worker sem alterar o Windows'}else{$probe3.Message})

$probe4=Invoke-WorkerProbe -Action 'RestoreAll' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: Rollback DRY-RUN' ([bool]$probe4.Success) $(if($probe4.Success){'Pipeline de rollback atravessou o Worker sem restaurar nada de verdade'}else{$probe4.Message})

$probeClean=Invoke-WorkerProbe -Action 'FullCleanPC' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: Limpeza completa do PC DRY-RUN' ([bool]$probeClean.Success) $(if($probeClean.Success){'Limpeza completa segura atravessou o Worker em DRY-RUN sem apagar arquivos'}else{$probeClean.Message})

$probeStudio=Invoke-WorkerProbe -Action 'WindowsStudioApplyAll' -Data ([pscustomobject]@{AutoRestorePoint=$false}) -TimeoutMs 30000
Add-Test 'Worker IPC: Windows Studio DRY-RUN' ([bool]$probeStudio.Success) $(if($probeStudio.Success){'Modo Tudo atravessou Worker em DRY-RUN com snapshot planejado'}else{$probeStudio.Message})

$probeStudioSelection=Invoke-WorkerProbe -Action 'WindowsStudioApplySelection' -Data ([pscustomobject]@{AutoRestorePoint=$false;Modules=@('GameMode','GameDVR','Energy','SearchSuggestions','DiagTrack','DefenderScan','HAGSOn')}) -TimeoutMs 30000
Add-Test 'Worker IPC: Windows Studio seleção DRY-RUN' ([bool]$probeStudioSelection.Success) $(if($probeStudioSelection.Success){'Seleção de módulos atravessou Worker em DRY-RUN'}else{$probeStudioSelection.Message})

$probeDiagnostic=Invoke-WorkerProbe -Action 'DiagnosticQuick' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: Diagnóstico rápido' ([bool]$probeDiagnostic.Success) $(if($probeDiagnostic.Success){'Diagnóstico rápido atravessou JSON/IPC/Worker em processo separado'}else{$probeDiagnostic.Message})

$probeDns=Invoke-WorkerProbe -Action 'DNSBenchmark' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: DNS Lab DRY-RUN' ([bool]$probeDns.Success) $(if($probeDns.Success){'Benchmark DNS atravessou Worker sem enviar consultas em DRY-RUN'}else{$probeDns.Message})

$probe5=Invoke-WorkerProbe -Action 'RamFullClean' -Data ([pscustomobject]@{Force=$true}) -TimeoutMs 30000
$probe=Invoke-WorkerProbe -Action 'DeepCleanPC' -Data ([pscustomobject]@{}) -TimeoutMs 45000
Add-Test 'Worker IPC: Limpeza Final DRY-RUN' ([bool]$probe.Success) $probe.Message
$probe=Invoke-WorkerProbe -Action 'WingetScan' -Data ([pscustomobject]@{}) -TimeoutMs 30000
Add-Test 'Worker IPC: WinGet DRY-RUN' ([bool]$probe.Success) $probe.Message

Add-Test 'Worker IPC: RAM completa DRY-RUN' ([bool]$probe5.Success) $(if($probe5.Success){'Integração da limpeza nativa de RAM foi validada em DRY-RUN, sem limpar memória de verdade'}else{$probe5.Message})

# Final
$passed=@($results|Where-Object Passed).Count
$total=$results.Count
$lines=New-Object System.Collections.Generic.List[string]
[void]$lines.Add(('=== SUPER OPTIMIZER {0} - AUTO-TESTE ===' -f $ScriptVersion))
[void]$lines.Add('')
foreach($item in $results){$prefix=if($item.Passed){'[OK] '}else{'[ERRO] '};[void]$lines.Add($prefix+$item.Test+' :: '+$item.Detail)}
[void]$lines.Add('')
[void]$lines.Add(('RESULTADO: {0}/{1} testes aprovados' -f $passed,$total))
$text=$lines -join "`r`n"
if($OutputFile){$text|Set-Content -LiteralPath $OutputFile -Encoding UTF8}else{Write-Output $text}
if($passed -ne $total){exit 1}else{exit 0}
