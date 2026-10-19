#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)][string]$RequestFile,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [Parameter(Mandatory=$true)][string]$ProgressFile,
    [Parameter(Mandatory=$true)][string]$LogFile
)
$ErrorActionPreference='Stop'
$req=$null
$operationLock=$null
$beforeSnapshot=$null

try {
    Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force -DisableNameChecking
    Set-SOLogFile $LogFile
    Set-SOProgressFile $ProgressFile
    [void](Initialize-SOEnvironment)

    $req=Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Set-SODryRun ([bool]$req.DryRun)

    # Trava entre processos: mesmo que a interface seja fechada e reaberta,
    # duas operações mutáveis nunca executam ao mesmo tempo.
    $readOnlyActions=@('Status','RamInfo','PerGameList','StateAudit','HistoryGet','StateManager','HealthSummary','PostRebootStatus','ProfileCompare','CustomProfilesGet')
    if(-not [bool]$req.DryRun -and $readOnlyActions -notcontains [string]$req.Action){
        $appRoot=Split-Path $PSScriptRoot -Parent
        $stateRoot=Join-Path $appRoot 'State'
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        $lockPath=Join-Path $stateRoot 'operation.lock'
        try{
            $operationLock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $operationLock.SetLength(0)
            $payload=[Text.Encoding]::UTF8.GetBytes(("{0}|{1}|{2}" -f $PID,[string]$req.Action,(Get-Date).ToString('o')))
            $operationLock.Write($payload,0,$payload.Length)
            $operationLock.Flush()
        }catch{
            throw 'Outra operação mutável do Super Optimizer já está em andamento. Aguarde ela terminar antes de iniciar uma nova.'
        }
    }

    Write-SOProgress 0 ('Iniciando: '+[string]$req.Action)

    # V3.8: captura estado antes/depois para comparador e histórico.
    $trackedActions=@('ProfileUniversal','ProfileAggressive','ProfileExtreme','ProfileGamerBrowser','RestoreAll','WindowsStudioApplyAll','WindowsStudioApplySelection','WindowsStudioRestoreSelection','WindowsStudioUndo','WindowsStudioRestoreOriginal','GamingAll','GameMode','GameDVROff','MMCSS','Foreground','MouseAccelOff','GamingRestore','BackgroundReduced','TelemetryReduced','VisualsReduced','PowerGaming','PrivacyRestore','PowerRestore','ServicesApply','ServicesRestore','HAGSOn','HAGSOff','MPOOff','GPURestore','VBSOff','VBSRestore')
    if(-not [bool]$req.DryRun -and $trackedActions -contains [string]$req.Action){try{$beforeSnapshot=Get-SOChangeSnapshot}catch{$beforeSnapshot=$null}}

    # Contrato rígido: uma rota deve produzir EXATAMENTE um resultado estruturado.
    # Saídas acidentais de helpers (booleans/strings) deixam de corromper o Worker silenciosamente.
    $raw=@(Invoke-SOAction -Action ([string]$req.Action) -Data $req.Data)
    if($raw.Count -ne 1){
        throw ("Contrato de saída violado pela ação {0}: esperava 1 objeto estruturado e recebeu {1}." -f [string]$req.Action,$raw.Count)
    }
    $result=$raw[0]
    $hasSuccess=$false
    if($result -is [System.Collections.IDictionary]){$hasSuccess=$result.Contains('Success')}
    elseif($result -and $result.PSObject.Properties['Success']){$hasSuccess=$true}
    if(-not $hasSuccess){throw ("Contrato de saída violado pela ação {0}: campo Success ausente." -f [string]$req.Action)}

    if(-not [bool]$req.DryRun -and $trackedActions -contains [string]$req.Action){
        try{
            $afterSnapshot=Get-SOChangeSnapshot
            if($beforeSnapshot){$cmp=@(Compare-SOChangeSnapshots -Before $beforeSnapshot -After $afterSnapshot);$result['Comparison']=$cmp}
        }catch{}
    }

    $warningCount=Get-SOWarningCount
    $warningMessages=@(Get-SOWarningMessages)
    $result['Warnings']=$warningCount
    if($warningCount -gt 0){
        $result['WarningMessages']=$warningMessages
        if([bool]$result.Success){
            $result['Message']=([string]$result.Message + " — concluído com $warningCount aviso(s); consulte o log.")
        }
    }

    $result['Action']=[string]$req.Action
    $result['Finished']=(Get-Date).ToString('o')
    if(-not [bool]$req.DryRun -and -not ($readOnlyActions -contains [string]$req.Action)){
        try{Add-SOHistoryEntry -Action ([string]$req.Action) -Success ([bool]$result.Success) -Message ([string]$result.Message) -Warnings ([int]$warningCount) -LogPath $LogFile -Comparison $(if($result.Contains('Comparison')){$result['Comparison']}else{$null}) -RebootRecommended $(if($result.Contains('RebootRecommended')){[bool]$result['RebootRecommended']}else{$false})}catch{}
        try{if($result.Contains('RebootRecommended') -and [bool]$result['RebootRecommended']){Save-SOPostRebootMarker -Action ([string]$req.Action) -Result $result}}catch{}
    }
    $result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $ResultFile -Encoding UTF8 -ErrorAction Stop
    Write-SOProgress 100 ([string]$result.Message) -NoLog
    if([bool]$result.Success){exit 0}else{exit 1}
} catch {
    try{Write-SOLog ($_.Exception.Message + "`r`n" + $_.ScriptStackTrace) 'ERROR'}catch{}
    try{if($req -and -not [bool]$req.DryRun -and -not ($readOnlyActions -contains [string]$req.Action)){Add-SOHistoryEntry -Action ([string]$req.Action) -Success $false -Message ([string]$_.Exception.Message) -Warnings (Get-SOWarningCount) -LogPath $LogFile -Comparison $null -RebootRecommended $false}}catch{}
    [ordered]@{
        Success=$false
        Message=$_.Exception.Message
        Detail=$_.ScriptStackTrace
        Action=if($req){[string]$req.Action}else{'Unknown'}
        Finished=(Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    try{Write-SOProgress 100 ('ERRO: '+$_.Exception.Message) -NoLog}catch{}
    exit 1
} finally {
    if($operationLock){
        try{$operationLock.Dispose()}catch{}
        $operationLock=$null
    }
}
