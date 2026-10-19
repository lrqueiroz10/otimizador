param([string]$ProjectRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$script:Assertions=0
function Assert-Equal($Actual,$Expected,[string]$Because){
    if($Actual -cne $Expected){throw ("{0}: esperado '{1}', recebido '{2}'" -f $Because,$Expected,$Actual)}
    $script:Assertions++
}
$app=Join-Path $ProjectRoot 'SuperOptimizer'
$manifest=Get-Content -LiteralPath (Join-Path $app 'Integrity.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal $manifest.algorithm 'SHA256' 'Algoritmo de integridade'
Assert-Equal @($manifest.files).Count 7 'Sete componentes operacionais no manifesto'
foreach($entry in $manifest.files){
    $file=Join-Path $app $entry.path
    Assert-Equal (Test-Path -LiteralPath $file -PathType Leaf) $true ('Componente: '+$entry.path)
    Assert-Equal (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() $entry.sha256 ('Integridade: '+$entry.path)
}
foreach($file in Get-ChildItem -LiteralPath $app -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert-Equal @($errors).Count 0 ('Parser: '+$file.Name)
}
[xml]$xaml=Get-Content -LiteralPath (Join-Path $app 'UI/MainWindow.xaml') -Raw -Encoding UTF8
$config=Get-Content -LiteralPath (Join-Path $app 'Config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal $config.version $manifest.version 'Config e manifesto sincronizados'
Assert-Equal $xaml.Window.Title ('Super Optimizer V'+$config.version) 'Título XAML sincronizado'
foreach($relative in @('SuperOptimizer.bat','SuperOptimizer/Launcher.ps1','SuperOptimizer/Core/SelfTest.ps1')){
    $text=Get-Content -LiteralPath (Join-Path $ProjectRoot $relative) -Raw -Encoding UTF8
    Assert-Equal ($text.Contains('V'+$config.version)) $true ('Versão: '+$relative)
}
# Executa somente o novo bloco de regressão do SelfTest, sem seu fluxo Windows.
$appSource=Get-Content -LiteralPath (Join-Path $app 'App.ps1') -Raw -Encoding UTF8
$tokens=$null;$errors=$null
$selfTestAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'Core/SelfTest.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Add-Test','Write-CurrentReport')){
    $definition=$selfTestAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name
    . ([scriptblock]::Create($definition.Extent.Text))
}
$OutputFile='';$results=New-Object System.Collections.Generic.List[object]
$classificationBlock=$selfTestAst.Find({param($node) $node -is [System.Management.Automation.Language.TryStatementAst] -and $node.Extent.Text.Contains('$classifiers=@(')},$true)
if($null -eq $classificationBlock){throw 'SelfTest sem bloco de regressão de classificação.'}
. ([scriptblock]::Create($classificationBlock.Extent.Text))
Assert-Equal $results.Count 8 'SelfTest registra oito cenários de classificação'
Assert-Equal @($results | Where-Object {-not $_.Passed}).Count 0 'Cenários embutidos do SelfTest aprovados'
# Comparador real do Engine com snapshots sintéticos e histórico temporário.
$module=Import-Module (Join-Path $app 'Core/Engine.psm1') -Force -DisableNameChecking -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('otimizador-history-tests-'+[guid]::NewGuid().ToString('N'))
try{
    & $module {
        param($root)
        $script:StateRoot=$root
        $script:MachineRoot=Join-Path $root 'Machines/INTEGRATION'
        New-Item -ItemType Directory -Path (Join-Path $script:MachineRoot 'History') -Force | Out-Null
    } $temp
    $before=[ordered]@{Profile='UNIVERSAL';PowerPlan='Balanced';Hibernation='1';Hypervisor='Auto';Defender='ScanAvgCPU=20';Registry=[pscustomobject]@{Keep='1';Changed='0';Removed='1'};Services=[pscustomobject]@{Spooler='Manual'};Tasks=[pscustomobject]@{Keep='Ready'}}
    $after=[ordered]@{Profile='AGRESSIVO';PowerPlan='Balanced';Hibernation='1';Hypervisor='Auto';Defender='ScanAvgCPU=20';Registry=[pscustomobject]@{Keep='1';Changed='1'};Services=[pscustomobject]@{Spooler='Disabled'};Tasks=[pscustomobject]@{Keep='Ready';Added='Disabled'}}
    Assert-Equal @(Compare-SOChangeSnapshots -Before $before -After $before).Count 0 'Snapshots iguais não inventam diferenças'
    $changes=@(Compare-SOChangeSnapshots -Before $before -After $after)
    Assert-Equal $changes.Count 5 'Diferenças de sistema, registro, serviços e tarefas'
    Assert-Equal ($changes | Where-Object Item -eq 'Removed').After '<ausente>' 'Remoção explícita'
    Assert-Equal ($changes | Where-Object Item -eq 'Added').Before '<ausente>' 'Criação explícita'
    Assert-Equal ($changes | Where-Object Item -eq 'Spooler').Before 'Manual' 'Estado anterior do serviço'
    Assert-Equal ($changes | Where-Object Item -eq 'Spooler').After 'Disabled' 'Estado posterior do serviço'
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'App.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('ConvertTo-ComparisonValueText','Get-ComparisonRows')){
        $fn=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $result=[ordered]@{Success=$true;Action='Integration';Comparison=$changes}
    $wire=ConvertTo-Json -InputObject $result -Depth 14
    $received=$wire | ConvertFrom-Json
    $rows=@(Get-ComparisonRows -Comparison $received.Comparison)
    Assert-Equal $rows.Count 5 'Engine → JSON do Worker → comparador UI'
    Assert-Equal @(Get-ComparisonRows -Comparison $received.Comparison -Search 'Spooler').Count 1 'Busca em dados reais do Engine'
    Assert-Equal @($rows | ConvertTo-Csv -NoTypeInformation | ConvertFrom-Csv).Count 5 'CSV dos dados reais'
    Assert-Equal @(Get-SOHistoryData).Count 0 'Histórico inicialmente vazio'
    Set-SODryRun $true
    Add-SOHistoryEntry -Action 'DryRun' -Success $true -Message 'Não persistir' -Warnings 0 -LogPath '' -Comparison $changes
    Assert-Equal @(Get-ChildItem -LiteralPath $temp -Recurse -File).Count 0 'Dry-run não grava histórico'
    Set-SODryRun $false
    Add-SOHistoryEntry -Action 'Integration' -Success $true -Message 'Concluído' -Warnings 0 -LogPath '' -Comparison $changes -RebootRecommended $true
    $history=@(Get-SOHistoryData)
    Assert-Equal $history.Count 1 'Primeira operação persiste corretamente'
    Assert-Equal @($history[0].Changes).Count 5 'Comparações preservadas no histórico'
    Assert-Equal $history[0].RebootRecommended $true 'Reinício preservado no histórico'
    Assert-Equal @(Get-ComparisonRows -Comparison $history[0].Changes).Count 5 'Histórico → comparador UI'
    Add-SOHistoryEntry -Action 'Failure' -Success $false -Message 'Falha controlada' -Warnings 1 -LogPath '' -Comparison $null
    $failure=Get-SOHistoryData | Where-Object Action -eq 'Failure'
    Assert-Equal $failure.Success $false 'Histórico mantém falhas'
    Assert-Equal @(Get-ComparisonRows -Comparison $failure.Changes).Count 0 'Comparação nula não inventa linha'
    Assert-Equal $failure.Warnings 1 'Avisos preservados'
    Assert-Equal @(Get-ChildItem -LiteralPath $temp -Recurse -Filter '*.tmp.*').Count 0 'Sem temporários restantes'
    foreach($i in 1..205){Add-SOHistoryEntry -Action ('Rotation'+$i) -Success $true -Message 'Teste de retenção' -Warnings 0 -LogPath '' -Comparison $null}
    $history=@(Get-SOHistoryData)
    Assert-Equal $history.Count 200 'Retenção limitada a 200 operações'
    Assert-Equal @($history | Where-Object Action -eq 'Rotation1').Count 0 'Operações mais antigas retiradas'
    Assert-Equal @($history | Where-Object Action -eq 'Rotation205').Count 1 'Operação mais recente preservada'
}finally{
    Remove-Module $module -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ('APROVADO: {0} verificações de integração; sem executar APIs do Windows.' -f $script:Assertions)
