param([string]$AppPath=(Join-Path $PSScriptRoot '../SuperOptimizer/App.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($AppPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw ($parseErrors | Out-String)}
# Carrega apenas funções selecionadas por AST, sem executar App ou WPF.
$names=@('Get-SelfTestOutcome','ConvertTo-ComparisonValueText','Get-ComparisonRows','Show-Operation','Show-SelfTestDialog','Sync-ActiveOperationState','Test-ActiveOperation')
foreach($name in $names){
    $definition=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object {$_.Name -eq $name}
    if(@($definition).Count -ne 1){throw "Função ausente/duplicada: $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:Assertions=0
function Assert-Equal($Actual,$Expected,[string]$Because){
    if($Actual -cne $Expected){throw ("{0}: esperado '{1}', recebido '{2}'" -f $Because,$Expected,$Actual)}
    $script:Assertions++
}
$cases=@(
    @{Report='RESULTADO: 8/8 testes aprovados';Code=0;Expected='Passed'},
    @{Report='RESULTADO: 8/8 testes aprovados';Code=1;Expected='Failed'},
    @{Report='RESULTADO: 7/8 testes aprovados';Code=0;Expected='Failed'},
    @{Report='RESULTADO: 0/0 testes aprovados';Code=0;Expected='Inconclusive'},
    @{Report='';Code=0;Expected='Inconclusive'},
    @{Report='Tudo certo';Code=0;Expected='Inconclusive'},
    @{Report='RESULTADO: 8/8 testes aprovados';Code=$null;Expected='Inconclusive'},
    @{Report="[ERRO] Falha no Worker`r`nRESULTADO: 8/8 testes aprovados";Code=0;Expected='Failed'},
    @{Report="  [ERROR] Falha no Worker`nRESULTADO: 8/8 testes aprovados";Code=0;Expected='Failed'},
    @{Report='RESULTADO: 9/8 testes aprovados';Code=0;Expected='Inconclusive'},
    @{Report="RESULTADO: 1/1 testes aprovados`nRESULTADO: 2/2 testes aprovados";Code=0;Expected='Inconclusive'},
    @{Report='RESULTADO: 999999999999999/999999999999999 testes aprovados';Code=0;Expected='Inconclusive'},
    @{Report='log contém RESULTADO: 8/8 testes aprovados';Code=0;Expected='Inconclusive'},
    @{Report="[OK] Parser`r`nRESULTADO: 8/8 testes aprovados`r`n";Code=0;Expected='Passed'},
    @{Report='';Code=2;Expected='Failed'}
)
foreach($case in $cases){Assert-Equal (Get-SelfTestOutcome -Report $case.Report -ExitCode $case.Code).State $case.Expected ('Classificação: '+$case.Report)}
$changes=@(
    [pscustomobject]@{Category='Serviços';Item='Spooler';Before='Manual';After='Disabled'},
    [pscustomobject]@{Category='Registro';Item='Booleano';Before=$false;After=$true},
    [pscustomobject]@{Category='Perfil';Item='Configuração';Before=$null;After=''},
    [pscustomobject]@{Category='Rede';Item='DNS';Before=@('1.1.1.1','8.8.8.8');After=[pscustomobject]@{Address='9.9.9.9'}}
)
$rows=@(Get-ComparisonRows -Comparison $changes)
Assert-Equal $rows.Count 4 'Quantidade de diferenças'
Assert-Equal $rows[1].Before 'False' 'Booleano preservado'
Assert-Equal $rows[2].Before '(não informado)' 'Valor ausente distinto de vazio'
Assert-Equal $rows[2].After '(vazio)' 'Texto vazio explícito'
Assert-Equal (($rows[3].Before | ConvertFrom-Json).Count) 2 'Array serializado com todos os valores'
Assert-Equal (($rows[3].After | ConvertFrom-Json).Address) '9.9.9.9' 'Objeto serializado'
Assert-Equal (ConvertTo-ComparisonValueText -Value @('Único')) '["Único"]' 'Array de um item preserva sua estrutura'
Assert-Equal (ConvertTo-ComparisonValueText -Value @()) '[]' 'Array vazio distinto de valor ausente'
Assert-Equal @(Get-ComparisonRows -Comparison $changes -Search ' sPOOLer ').Count 1 'Busca sem diferenciar maiúsculas'
Assert-Equal @(Get-ComparisonRows -Comparison $changes -Search 'Disabled').Count 1 'Busca por valor'
Assert-Equal @(Get-ComparisonRows -Comparison $changes -Search '*').Count 0 'Busca literal, sem curingas'
Assert-Equal @(Get-ComparisonRows -Comparison $null).Count 0 'Comparação ausente não gera linha fictícia'
Assert-Equal @(Get-ComparisonRows -Comparison @($null)).Count 0 'Entrada nula ignorada'
Assert-Equal @(Get-ComparisonRows -Comparison $rows -Search 'DNS').Count 1 'Filtrar linhas já formatadas'
Assert-Equal $changes[2].Before $null 'Dados originais preservados'
$rejected=$false
try{Get-ComparisonRows -Comparison ([pscustomobject]@{Item='Incompleto'})}catch{$rejected=$true}
Assert-Equal $rejected $true 'Dados incompletos não viram comparação vazia'
$roundtrip=@($rows | ConvertTo-Csv -NoTypeInformation | ConvertFrom-Csv)
Assert-Equal $roundtrip[3].Before $rows[3].Before 'CSV preserva JSON e separadores'
function Show-Info {param($Title,$Text)}
function Confirm-SO {param($Text,$Danger) return $false}
$script:ActiveOperationProcess=[pscustomobject]@{HasExited=$false}
$script:ActiveOperationStarted=Get-Date
$script:ActiveOperationAction='Teste'
$script:LastOperationResult=[pscustomobject]@{Success=$true;Data='Antigo'}
Show-Operation -Action 'HistoryGet'
Assert-Equal $script:LastOperationResult $null 'Operação bloqueada descarta resultado anterior'
$script:ActiveOperationProcess=$null
$script:LastOperationResult=[pscustomobject]@{Success=$true;Data='Antigo'}
Show-Operation -Action 'Apply' -ConfirmText 'Confirmar?'
Assert-Equal $script:LastOperationResult $null 'Cancelamento descarta resultado anterior'
$script:ActiveOperationProcess=[pscustomobject]@{HasExited=$false}
$script:LastOperationResult=[pscustomobject]@{Success=$true;Comparison=$changes}
Show-SelfTestDialog
Assert-Equal $script:LastOperationResult $null 'Auto-Teste não reutiliza comparação anterior'
$comparisonUi=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object {$_.Name -eq 'Show-ComparisonResultUi'}
$xaml=$comparisonUi.Find({param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('<Grid xmlns=')},$true)
[xml]$xml=$xaml.Value
Assert-Equal $xml.DocumentElement.LocalName 'Grid' 'XAML do comparador é XML válido'
# Executa callback real com processos simulados e relatórios temporários.
$selfTestUi=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object {$_.Name -eq 'Show-SelfTestDialog'}
$tickAssignment=$selfTestUi.Find({param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$tick'},$true)
$tickExpression=$tickAssignment.Find({param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true)
$tickSource=$tickExpression.ScriptBlock.Extent.Text
$tick=[scriptblock]::Create($tickSource.Substring(1,$tickSource.Length-2))
$script:B=@{Green='green';Red='red';Yellow='yellow'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('otimizador-ui-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try{
    foreach($scenario in @(
        @{Name='Relatório completo';Report='RESULTADO: 2/2 testes aprovados';Code=0;Color='green';Timeout=$false;HasReport=$true},
        @{Name='Processo falhou';Report='RESULTADO: 2/2 testes aprovados';Code=1;Color='red';Timeout=$false;HasReport=$true},
        @{Name='Último relatório reprovou';Report='RESULTADO: 1/2 testes aprovados';Code=0;Color='red';Timeout=$false;HasReport=$true},
        @{Name='Só stdout, sem relatório';Report='RESULTADO: 2/2 testes aprovados';Code=0;Color='yellow';Timeout=$false;HasReport=$false},
        @{Name='Timeout oculto';Report='';Code=0;Color='red';Timeout=$true;HasReport=$false}
    )){
        $output=Join-Path $temp 'report.txt';$stdout=Join-Path $temp 'stdout.txt';$stderr=Join-Path $temp 'stderr.txt'
        Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue
        if($scenario.HasReport){$scenario.Report | Set-Content -LiteralPath $output -Encoding UTF8}
        $scenario.Report | Set-Content -LiteralPath $stdout -Encoding UTF8
        $process=[pscustomobject]@{HasExited=(-not $scenario.Timeout);ExitCode=$scenario.Code;Killed=$false}
        $process | Add-Member ScriptMethod WaitForExit {}
        $process | Add-Member ScriptMethod Refresh {}
        $process | Add-Member ScriptMethod Kill {$this.Killed=$true;$this.HasExited=$true}
        $box=[pscustomobject]@{Text='RESULTADO: 2/2 testes aprovados'}
        $box | Add-Member ScriptMethod ScrollToEnd {}
        $ctx=[pscustomobject]@{Output=$output;StdOut=$stdout;StdErr=$stderr;Box=$box;Process=$process;Status=[pscustomobject]@{Text='';Foreground=''};Started=$(if($scenario.Timeout){(Get-Date).AddSeconds(-181)}else{Get-Date});Finished=$false}
        $sender=[pscustomobject]@{Tag=$ctx;Stopped=$false}
        $sender | Add-Member ScriptMethod Stop {$this.Stopped=$true}
        $script:ActiveOperationProcess=$process
        & $tick $sender $null
        Assert-Equal $ctx.Status.Foreground $scenario.Color ('Timer: '+$scenario.Name)
        Assert-Equal $sender.Stopped $true ('Timer encerra: '+$scenario.Name)
        if($scenario.Timeout){Assert-Equal $process.Killed $true 'Timeout encerra somente o processo de teste'}
        else{Assert-Equal $script:ActiveOperationProcess $null 'Teste concluído libera bloqueio de operações'}
    }
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
Write-Output ('APROVADO: {0} verificações de regressão; parser sem erros.' -f $script:Assertions)
