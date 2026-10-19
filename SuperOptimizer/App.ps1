param([switch]$Elevated)
$ErrorActionPreference = 'Stop'

$AppRoot = $PSScriptRoot
$Core = Join-Path $AppRoot 'Core'
$Worker = Join-Path $Core 'Worker.ps1'
$SelfTest = Join-Path $Core 'SelfTest.ps1'
$State = Join-Path $AppRoot 'State'
$Runtime = Join-Path $State 'Runtime'
$Logs = Join-Path $State 'Logs'
$UiRoot = Join-Path $AppRoot 'UI'
$XamlPath = Join-Path $UiRoot 'MainWindow.xaml'
$psExe = Join-Path $PSHOME 'powershell.exe'
New-Item -ItemType Directory -Force -Path $Runtime,$Logs | Out-Null

# Runtime garbage from old sessions should not accumulate forever.
Get-ChildItem -LiteralPath $Runtime -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    try {
        $arg = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Elevated' -f $PSCommandPath
        if(-not(Test-Path -LiteralPath $psExe)){throw "Windows PowerShell não encontrado em $psExe"}
        Start-Process -FilePath $psExe -ArgumentList $arg -Verb RunAs -WindowStyle Hidden
    } catch {}
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName Microsoft.VisualBasic

$script:CrashLog = Join-Path $Logs 'ui_last_error.txt'
$script:LastOperationResult = $null

function Write-UiError {
    param($ErrorRecord,[string]$Context='Interface')
    try {
        $text = @(
            'SUPER OPTIMIZER UI ERROR'
            ('Data: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            ('Contexto: {0}' -f $Context)
            ('Mensagem: {0}' -f $ErrorRecord.Exception.Message)
            ''
            ($ErrorRecord | Out-String)
            'Stack:'
            $ErrorRecord.ScriptStackTrace
        ) -join "`r`n"
        $text | Set-Content -LiteralPath $script:CrashLog -Encoding UTF8
    } catch {}
}

function Show-UiError {
    param($ErrorRecord,[string]$Context='Interface')
    Write-UiError -ErrorRecord $ErrorRecord -Context $Context
    $message = "{0}`r`n`r`nO erro foi salvo em:`r`n{1}" -f $ErrorRecord.Exception.Message,$script:CrashLog
    [System.Windows.MessageBox]::Show($message,'Super Optimizer - Erro',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null
}

function Get-Brush([string]$Hex) {
    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($Hex)
}

$B = @{
    Bg = Get-Brush '#090E1C'
    Panel = Get-Brush '#111B31'
    Card = Get-Brush '#16233E'
    Card2 = Get-Brush '#1A2A49'
    Text = Get-Brush '#F1F5F9'
    Muted = Get-Brush '#94A3B8'
    Cyan = Get-Brush '#22D3EE'
    Magenta = Get-Brush '#F43FB4'
    Green = Get-Brush '#34D399'
    Yellow = Get-Brush '#FBBF24'
    Red = Get-Brush '#FB7185'
}

function Load-MainWindow {
    if (-not (Test-Path -LiteralPath $XamlPath)) { throw 'UI\MainWindow.xaml não encontrado.' }
    [xml]$xml = Get-Content -LiteralPath $XamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader($xml)
    try { return [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
}

$Window = Load-MainWindow

# O Launcher mantém um EventWaitHandle nomeado. Uma segunda tentativa de abertura sinaliza
# este evento para trazer a janela atual para frente, sem criar outra instância.
$script:ActivationEvent=$null
try{
    $script:ActivationEvent=[System.Threading.EventWaitHandle]::OpenExisting('Local\SuperOptimizer_ActivateExisting')
}catch{}
$NavHost = $Window.FindName('NavHost')
$PageHost = $Window.FindName('PageHost')
$CloseButton = $Window.FindName('CloseButton')
$HeaderStatus = $Window.FindName('HeaderStatus')

$script:CurrentPage = 'Dashboard'
$script:LastStatus = $null
$script:LastStatusError = $null
$script:StatusProcess = $null
$script:StatusFiles = $null
$script:StatusStarted = $null
$script:DashboardRefs = @{}
$script:StatusRefreshRequested = $false
$script:ActiveOperationProcess = $null
$script:ActiveOperationAction = $null
$script:ActiveOperationFiles = $null
$script:ActiveOperationStarted = $null

function New-Text {
    param(
        [string]$Text,
        [double]$Size=14,
        $Color=$B.Text,
        [switch]$Bold,
        [System.Windows.Thickness]$Margin=[System.Windows.Thickness]::new(0)
    )
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = $Color
    $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $t.Margin = $Margin
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    return $t
}

function New-Card {
    param([System.Windows.Thickness]$Margin=[System.Windows.Thickness]::new(0,0,0,16))
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $Window.FindResource('CardStyle')
    $card.Margin = $Margin
    return $card
}

function New-Button {
    param(
        [string]$Text,
        $Accent=$B.Cyan,
        [double]$Width=215,
        [double]$Height=44
    )
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $Window.FindResource('ActionButtonStyle')

    # Não depender apenas de Setters do Style: no Windows PowerShell 5.1 alguns
    # botões dinâmicos dentro de UniformGrid chegaram a renderizar só o texto.
    # Valores locais + conteúdo WPF explícito mantêm fundo/borda visíveis.
    $button.Background = $B.Panel
    $button.Foreground = $B.Text
    $button.BorderBrush = $Accent
    $button.BorderThickness = [Windows.Thickness]::new(1.5)
    $button.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Center
    $button.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
    $button.Padding = [Windows.Thickness]::new(14,6,14,6)

    $label = New-Text -Text $Text -Size 12 -Color $B.Text -Bold
    $label.TextAlignment = [System.Windows.TextAlignment]::Center
    $label.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $button.Content = $label

    if ($Width -gt 0) { $button.Width = $Width }
    $button.Height = $Height
    return $button
}

function Read-UiJsonShared {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream=$null;$reader=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $raw=$reader.ReadToEnd()
        if([string]::IsNullOrWhiteSpace($raw)){return $null}
        return ($raw|ConvertFrom-Json)
    }finally{
        if($reader){$reader.Dispose()}
        elseif($stream){$stream.Dispose()}
    }
}

function Add-PageHeader {
    param([string]$Title,[string]$Subtitle)
    $PageHost.Children.Add((New-Text -Text $Title -Size 28 -Bold -Margin ([Windows.Thickness]::new(0,0,0,4)))) | Out-Null
    $PageHost.Children.Add((New-Text -Text $Subtitle -Size 13 -Color $B.Muted -Margin ([Windows.Thickness]::new(0,0,0,18)))) | Out-Null
}

function Clear-Page {
    $PageHost.Children.Clear()
}

function Confirm-SO {
    param([string]$Text,[bool]$Danger=$false)
    $icon = if ($Danger) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question }
    return ([System.Windows.MessageBox]::Show($Text,'Confirmar',[System.Windows.MessageBoxButton]::YesNo,$icon) -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-Info {
    param([string]$Text,[string]$Title='Super Optimizer')
    [System.Windows.MessageBox]::Show($Text,$Title,[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information) | Out-Null
}

function New-RequestFiles {
    param([string]$Action,$Data,[bool]$DryRun=$false)
    $id = [guid]::NewGuid().ToString('N')
    $req = Join-Path $Runtime ($id + '.request.json')
    $res = Join-Path $Runtime ($id + '.result.json')
    $prog = Join-Path $Runtime ($id + '.progress.json')
    $log = if($Action -eq 'Status'){
        Join-Path $Runtime ('status_'+$id.Substring(0,8)+'.log')
    }else{
        Join-Path $Logs ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + $Action + '_' + $id.Substring(0,6) + '.log')
    }
    [ordered]@{
        Action=$Action
        Data=$Data
        DryRun=$DryRun
        Created=(Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $req -Encoding UTF8
    return [pscustomobject]@{Request=$req;Result=$res;Progress=$prog;Log=$log}
}

function Start-Worker {
    param($Files)
    $exe = Join-Path $PSHOME 'powershell.exe'
    $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -RequestFile "{1}" -ResultFile "{2}" -ProgressFile "{3}" -LogFile "{4}"' -f $Worker,$Files.Request,$Files.Result,$Files.Progress,$Files.Log
    return Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru
}

function Start-StatusRefresh {
    try {
        if ($script:StatusProcess -and -not $script:StatusProcess.HasExited) { return }
        $files = New-RequestFiles -Action 'Status' -Data ([pscustomobject]@{}) -DryRun $false
        $script:StatusFiles = $files
        $script:StatusProcess = Start-Worker -Files $files
        $script:StatusStarted = Get-Date
        $script:LastStatusError = $null
        $HeaderStatus.Text = 'ADMIN • LENDO STATUS'
        Update-DashboardStatus
    } catch {
        $script:LastStatusError = $_.Exception.Message
        Write-UiError -ErrorRecord $_ -Context 'Status - iniciar'
        Update-DashboardStatus
    }
}

function Update-DashboardStatus {
    if ($script:DashboardRefs.Count -eq 0) { return }
    try {
        if ($script:LastStatus) {
            $s = $script:LastStatus
            $script:DashboardRefs.Profile.Text = [string]$s.Profile
            $script:DashboardRefs.Gaming.Text = 'GameMode {0}  •  DVR {1}' -f $s.GameMode,$s.GameDVR
            $script:DashboardRefs.VBS.Text = [string]$s.VBS
            $script:DashboardRefs.Services.Text = [string]$s.Services
            $weekly = if ($s.LastWeekly) { ([datetime]$s.LastWeekly).ToString('dd/MM/yyyy HH:mm') } else { 'Nunca' }
            $health = if ($s.LastHealthScan) { ([datetime]$s.LastHealthScan).ToString('dd/MM/yyyy HH:mm') } else { 'Nunca' }
            $power = if($s.PSObject.Properties['PowerPlanName']){[string]$s.PowerPlanName}else{[string]$s.PowerPlan}
            $ramUsed = if($s.PSObject.Properties['RAMUsedPercent']){[string]$s.RAMUsedPercent}else{'?'}
            $script:DashboardRefs.System.Text = @(
                ('Windows: {0}' -f $s.Windows)
                ('CPU: {0}' -f $s.CPU)
                ('RAM: {0} GB total / {1} GB livre / {2}% em uso' -f $s.RAMTotalGB,$s.RAMFreeGB,$ramUsed)
                ('Disco do sistema: {0} GB livre / {1}% livre' -f $s.DiskFreeGB,$s.DiskFreePercent)
                ('Plano de energia: {0}' -f $power)
                ('VirtualBox: {0}' -f $s.VirtualBox)
                ('Manutenção semanal: {0}' -f $weekly)
                ('Última verificação de integridade: {0}' -f $health)
            ) -join "`r`n"
            $script:DashboardRefs.Message.Text = 'Status atualizado: ' + (Get-Date -Format 'HH:mm:ss')
            $script:DashboardRefs.Message.Foreground = $B.Green
            $HeaderStatus.Text = 'ADMIN • STATUS OK'
        } elseif ($script:LastStatusError) {
            $script:DashboardRefs.Message.Text = 'Falha/timeout ao ler status: ' + $script:LastStatusError
            $script:DashboardRefs.Message.Foreground = $B.Red
            $HeaderStatus.Text = 'ADMIN • STATUS INDISPONÍVEL'
        } else {
            $script:DashboardRefs.Message.Text = 'Lendo o estado do Windows em processo separado...'
            $script:DashboardRefs.Message.Foreground = $B.Yellow
        }
        Update-DashboardExtras
    } catch {
        Write-UiError -ErrorRecord $_ -Context 'Dashboard - atualizar'
    }
}

function Sync-ActiveOperationState {
    try{
        if($script:ActiveOperationProcess -and $script:ActiveOperationProcess.HasExited){
            $script:ActiveOperationProcess=$null
            $script:ActiveOperationAction=$null
            $script:ActiveOperationFiles=$null
            $script:ActiveOperationStarted=$null
            $script:StatusRefreshRequested=$true
        }
    }catch{
        $script:ActiveOperationProcess=$null
        $script:ActiveOperationAction=$null
        $script:ActiveOperationFiles=$null
        $script:ActiveOperationStarted=$null
    }
}

function Test-ActiveOperation {
    Sync-ActiveOperationState
    return ($null -ne $script:ActiveOperationProcess)
}

function Show-Operation {
    param(
        [string]$Action,
        [object]$Data=([pscustomobject]@{}),
        [string]$Title=$Action,
        [string]$Description='',
        [string]$ConfirmText='',
        [bool]$Danger=$false,
        [bool]$DryRun=$false
    )
    $script:LastOperationResult = $null
    try {
        if(Test-ActiveOperation){
            $elapsed=if($script:ActiveOperationStarted){[math]::Round(((Get-Date)-$script:ActiveOperationStarted).TotalMinutes,1)}else{0}
            Show-Info -Title 'Operação em andamento' -Text ("Já existe uma operação ativa: {0}`r`nTempo: {1} min`r`n`r`nAguarde ela terminar antes de iniciar outra. Isso evita conflitos entre Registro, serviços, DISM e rollback." -f $script:ActiveOperationAction,$elapsed)
            return
        }
        if ($ConfirmText -and -not (Confirm-SO -Text $ConfirmText -Danger $Danger)) { return }
        $files = New-RequestFiles -Action $Action -Data $Data -DryRun $DryRun
        $proc = Start-Worker -Files $files
        $started = Get-Date
        $script:ActiveOperationProcess=$proc
        $script:ActiveOperationAction=$Action
        $script:ActiveOperationFiles=$files
        $script:ActiveOperationStarted=$started
        $HeaderStatus.Text=('ADMIN • EXECUTANDO '+$Action)

        $dlg = New-Object System.Windows.Window
        $dlg.Title = $Title
        $dlg.Width = 860
        $dlg.Height = 620
        $dlg.MinWidth = 720
        $dlg.MinHeight = 520
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
        $dlg.Owner = $Window
        $dlg.Background = $B.Bg
        $dlg.Foreground = $B.Text

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = [Windows.Thickness]::new(22)
        foreach ($h in @('Auto','Auto','Auto','*','Auto')) {
            $rd = New-Object System.Windows.Controls.RowDefinition
            $rd.Height = if ($h -eq '*') { [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto }
            [void]$grid.RowDefinitions.Add($rd)
        }

        $titleBlock = New-Text -Text $Title -Size 22 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,0,0,6))
        [Windows.Controls.Grid]::SetRow($titleBlock,0)
        $grid.Children.Add($titleBlock) | Out-Null

        $descBlock = New-Text -Text $Description -Size 12 -Color $B.Muted -Margin ([Windows.Thickness]::new(0,0,0,14))
        [Windows.Controls.Grid]::SetRow($descBlock,1)
        $grid.Children.Add($descBlock) | Out-Null

        $progressStack = New-Object System.Windows.Controls.StackPanel
        $progressStack.Margin = [Windows.Thickness]::new(0,0,0,12)
        $bar = New-Object System.Windows.Controls.ProgressBar
        $bar.Height = 18
        $bar.Minimum = 0
        $bar.Maximum = 100
        $bar.Value = 0
        $status = New-Text -Text 'Iniciando...' -Size 12 -Color $B.Yellow -Margin ([Windows.Thickness]::new(0,7,0,0))
        $progressStack.Children.Add($bar) | Out-Null
        $progressStack.Children.Add($status) | Out-Null
        [Windows.Controls.Grid]::SetRow($progressStack,2)
        $grid.Children.Add($progressStack) | Out-Null

        $box = New-Object System.Windows.Controls.TextBox
        $box.IsReadOnly = $true
        $box.AcceptsReturn = $true
        $box.AcceptsTab = $true
        $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $box.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $box.TextWrapping = [System.Windows.TextWrapping]::NoWrap
        $box.Background = $B.Panel
        $box.Foreground = $B.Text
        $box.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $box.FontSize = 12
        $box.Padding = [Windows.Thickness]::new(10)
        [Windows.Controls.Grid]::SetRow($box,3)
        $grid.Children.Add($box) | Out-Null

        $buttons = New-Object System.Windows.Controls.DockPanel
        $buttons.Margin = [Windows.Thickness]::new(0,14,0,0)
        $openLogs = New-Button -Text 'Abrir pasta de logs' -Accent $B.Cyan -Width 180
        $close = New-Button -Text 'Ocultar / Fechar' -Accent $B.Red -Width 170
        [Windows.Controls.DockPanel]::SetDock($openLogs,[Windows.Controls.Dock]::Left)
        [Windows.Controls.DockPanel]::SetDock($close,[Windows.Controls.Dock]::Right)
        $buttons.Children.Add($openLogs) | Out-Null
        $buttons.Children.Add($close) | Out-Null
        [Windows.Controls.Grid]::SetRow($buttons,4)
        $grid.Children.Add($buttons) | Out-Null

        $dlg.Content = $grid

        $openLogs.Add_Click({
            try { Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $Logs) }
            catch { Show-UiError -ErrorRecord $_ -Context 'Abrir logs' }
        })

        $close.Tag = $dlg
        $close.Add_Click({
            param($sender,$eventArgs)
            try { $sender.Tag.Close() } catch {}
        })

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(400)
        $timer.Tag = [pscustomobject]@{
            Files=$files
            Bar=$bar
            Status=$status
            Started=$started
            Box=$box
            Process=$proc
            Finished=$false
        }

        $tick = {
            param($sender,$eventArgs)
            $ctx = $sender.Tag

            try {
                if (Test-Path -LiteralPath $ctx.Files.Progress) {
                    $p = Read-UiJsonShared -Path $ctx.Files.Progress
                    $ctx.Bar.Value = [Math]::Max(0,[Math]::Min(100,[int]$p.Percent))
                    $elapsed = (Get-Date) - $ctx.Started
                    $ctx.Status.Text = '{0}  •  {1:hh\:mm\:ss}' -f $p.Message,$elapsed
                }
            } catch {}

            try {
                if (Test-Path -LiteralPath $ctx.Files.Log) {
                    $txt = Get-Content -LiteralPath $ctx.Files.Log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($null -ne $txt -and $txt -ne $ctx.Box.Text) {
                        $ctx.Box.Text = $txt
                        $ctx.Box.ScrollToEnd()
                    }
                }
            } catch {}

            if (-not $ctx.Finished -and $ctx.Process.HasExited) {
                $ctx.Finished = $true
                $ctx.Bar.Value = 100
                try {
                    if (Test-Path -LiteralPath $ctx.Files.Result) {
                        $r = Get-Content -LiteralPath $ctx.Files.Result -Raw -Encoding UTF8 | ConvertFrom-Json
                        $script:LastOperationResult = $r
                        if ($r.Success) {
                            $warningCount=if($r.PSObject.Properties['Warnings']){[int]$r.Warnings}else{0}
                            $ctx.Status.Foreground = if($warningCount -gt 0){$B.Yellow}else{$B.Green}
                            $suffix = if ($r.RebootRecommended) { ' • Reinício recomendado' } else { '' }
                            $ctx.Status.Text = [string]$r.Message + $suffix
                            if($warningCount -gt 0 -and $r.PSObject.Properties['WarningMessages']){
                                try{
                                    $warnText=@($r.WarningMessages) -join "`r`n• "
                                    if($warnText){$ctx.Box.AppendText("`r`n`r`n--- AVISOS ---`r`n• "+$warnText+"`r`n");$ctx.Box.ScrollToEnd()}
                                }catch{}
                            }
                            if($r.PSObject.Properties['Data'] -and $null -ne $r.Data){
                                try{
                                    $dataText=$r.Data | ConvertTo-Json -Depth 8
                                    if($dataText){
                                        if($ctx.Box.Text){$ctx.Box.AppendText("`r`n`r`n--- RESULTADO ---`r`n")}
                                        else{$ctx.Box.Text="--- RESULTADO ---`r`n"}
                                        $ctx.Box.AppendText($dataText)
                                        $ctx.Box.ScrollToEnd()
                                    }
                                }catch{}
                            }
                        } else {
                            $ctx.Status.Foreground = $B.Red
                            $ctx.Status.Text = 'ERRO: ' + [string]$r.Message
                        }
                    } else {
                        $ctx.Status.Foreground = $B.Red
                        $ctx.Status.Text = 'O worker terminou sem gerar resultado. Consulte o log.'
                    }
                } catch {
                    $ctx.Status.Foreground = $B.Red
                    $ctx.Status.Text = 'Não foi possível ler o resultado. Consulte o log.'
                }

                if($script:ActiveOperationProcess -and $script:ActiveOperationProcess.Id -eq $ctx.Process.Id){
                    $script:ActiveOperationProcess=$null
                    $script:ActiveOperationAction=$null
                    $script:ActiveOperationFiles=$null
                    $script:ActiveOperationStarted=$null
                }
                $script:StatusRefreshRequested = $true
            }
        }
        $timer.Add_Tick($tick)

        $dlg.Tag = [pscustomobject]@{Process=$proc}
        $closing = {
            param($sender,$eventArgs)
            $running = $false
            try { $running = -not $sender.Tag.Process.HasExited } catch {}
            if ($running) {
                $answer = [System.Windows.MessageBox]::Show(
                    'A operação ainda está rodando. Fechar esta janela não cancela o processo; ele continuará em segundo plano. Deseja ocultar mesmo assim?',
                    'Operação em andamento',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning
                )
                if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $eventArgs.Cancel = $true }
            }
        }
        $dlg.Add_Closing($closing)
        $timer.Start()
        [void]$dlg.ShowDialog()
        $timer.Stop()
        if($script:LastOperationResult -and $script:LastOperationResult.Success -and $script:LastOperationResult.PSObject.Properties['Comparison'] -and @($script:LastOperationResult.Comparison).Count -gt 0){
            $answer=[System.Windows.MessageBox]::Show(('A operação alterou {0} item(ns) monitorado(s). Ver comparador Antes x Depois agora?' -f @($script:LastOperationResult.Comparison).Count),'Antes x Depois',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Information)
            if($answer -eq [System.Windows.MessageBoxResult]::Yes){Show-ComparisonResultUi -Comparison @($script:LastOperationResult.Comparison) -Title ('Antes x Depois — '+$Action)}
        }
    } catch {
        Show-UiError -ErrorRecord $_ -Context ('Operação ' + $Action)
    }
}

function New-ActionButton {
    param(
        [string]$Text,
        [string]$Action,
        $Accent=$B.Cyan,
        [string]$Confirm='',
        [bool]$Danger=$false,
        [string]$Description='',
        [object]$Data=([pscustomobject]@{})
    )
    $button = New-Button -Text $Text -Accent $Accent -Width 220
    $button.Tag = [pscustomobject]@{
        Action=$Action
        Data=$Data
        Title=$Text
        Confirm=$Confirm
        Danger=$Danger
        Description=$Description
    }
    $button.Add_Click({
        param($sender,$eventArgs)
        try {
            $tag = $sender.Tag
            Show-Operation -Action ([string]$tag.Action) -Data $tag.Data -Title ([string]$tag.Title) -Description ([string]$tag.Description) -ConfirmText ([string]$tag.Confirm) -Danger ([bool]$tag.Danger)
        } catch {
            Show-UiError -ErrorRecord $_ -Context 'Botão de ação'
        }
    })
    return $button
}

function New-UiFragment {
    param([Parameter(Mandatory=$true)][string]$Xaml)
    [xml]$fragmentXml = $Xaml
    $fragmentReader = New-Object System.Xml.XmlNodeReader($fragmentXml)
    try {
        return [Windows.Markup.XamlReader]::Load($fragmentReader)
    } finally {
        $fragmentReader.Close()
    }
}

function New-CheckboxLine {
    param(
        [string]$Text,
        [bool]$Checked=$false,
        [string]$ToolTip=''
    )
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $row.Margin = [Windows.Thickness]::new(6,10,6,2)

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.IsChecked = $Checked
    $cb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $cb.Margin = [Windows.Thickness]::new(0,0,8,0)

    $label = New-Text -Text $Text -Size 12 -Color $B.Muted
    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $label.Cursor = [System.Windows.Input.Cursors]::Hand
    $label.Tag = $cb
    $label.Add_MouseLeftButtonUp({
        param($sender,$eventArgs)
        try{$sender.Tag.IsChecked = -not [bool]$sender.Tag.IsChecked}catch{}
    })

    if($ToolTip){
        $row.ToolTip = $ToolTip
        $cb.ToolTip = $ToolTip
        $label.ToolTip = $ToolTip
    }

    [void]$row.Children.Add($cb)
    [void]$row.Children.Add($label)
    return [pscustomobject]@{Container=$row;CheckBox=$cb;Label=$label}
}

# Cards de ação que precisam de alinhamento rígido usam UniformGrid.
# Isso evita botões com larguras diferentes e grandes espaços mortos em resoluções menores.
function New-GridActionCard {
    param([string]$Title,[string]$Subtitle='',[int]$Columns=3)
    $card=New-Card
    $stack=New-Object System.Windows.Controls.StackPanel
    if($Title){$stack.Children.Add((New-Text -Text $Title -Size 16 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,0,0,4))))|Out-Null}
    if($Subtitle){$stack.Children.Add((New-Text -Text $Subtitle -Size 12 -Color $B.Muted -Margin ([Windows.Thickness]::new(0,0,0,12))))|Out-Null}
    $grid=New-Object System.Windows.Controls.Primitives.UniformGrid
    $grid.Columns=[Math]::Max(1,$Columns)
    $grid.Margin=[Windows.Thickness]::new(-6,0,-6,0)
    [void]$stack.Children.Add($grid)
    $card.Child=$stack
    return [pscustomobject]@{Card=$card;Stack=$stack;Grid=$grid}
}

function Add-GridButton {
    param($Grid,$Button)
    if($null -eq $Grid -or $null -eq $Button){return}
    $Button.Width = [double]::NaN
    $Button.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $Button.Margin = [Windows.Thickness]::new(6)
    [void]$Grid.Children.Add($Button)
}

function New-StatusCard {
    param([string]$Label)
    $card = New-Card -Margin ([Windows.Thickness]::new(6))
    $card.MinHeight = 96
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Children.Add((New-Text -Text $Label -Size 11 -Color $B.Muted -Bold -Margin ([Windows.Thickness]::new(0,0,0,7)))) | Out-Null
    $value = New-Text -Text 'Carregando...' -Size 18 -Color $B.Cyan -Bold
    $stack.Children.Add($value) | Out-Null
    $card.Child = $stack
    return [pscustomobject]@{Card=$card;Value=$value}
}

function Get-UiMachineId {
    try{
        $id=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if($id){return ($id -replace '[^a-zA-Z0-9-]','_')}
    }catch{}
    return (($env:COMPUTERNAME+'_'+$env:USERNAME) -replace '[^a-zA-Z0-9-]','_')
}

function Get-UiReportsPath {
    return (Join-Path $State ('Machines\'+(Get-UiMachineId)+'\Reports'))
}

function Show-RamUsageUi {
    try{
        if($script:LastStatus){
            $total=[double]$script:LastStatus.RAMTotalGB
            $free=[double]$script:LastStatus.RAMFreeGB
            $used=[math]::Round($total-$free,1)
            $usedPct=if($script:LastStatus.PSObject.Properties['RAMUsedPercent']){[double]$script:LastStatus.RAMUsedPercent}elseif($total -gt 0){[math]::Round(($used/$total)*100,1)}else{0}
            Show-Info -Title 'Memória RAM' -Text ("RAM total: {0} GB`r`nEm uso: ~{1} GB ({2}%)`r`nLivre: {3} GB`r`n`r`nRAM em cache não é necessariamente desperdício. O Windows reutiliza esse espaço quando necessário." -f $total,$used,$usedPct,$free)
        }else{
            Show-Operation -Action 'RamInfo' -Data ([pscustomobject]@{}) -Title 'Memória RAM' -Description 'Leitura de memória do Windows.'
        }
    }catch{Show-UiError -ErrorRecord $_ -Context 'RAM'}
}

function Start-StandbyRamCleanupUi {
    try{
        $force=$false
        if($script:LastStatus -and [double]$script:LastStatus.RAMTotalGB -gt 0){
            $freePct=[math]::Round(([double]$script:LastStatus.RAMFreeGB/[double]$script:LastStatus.RAMTotalGB)*100,1)
            if($freePct -ge 25){
                $answer=[System.Windows.MessageBox]::Show(
                    ("Você ainda possui {0} GB livres ({1}%).`r`n`r`nA limpeza de Standby provavelmente não é necessária agora e pode eliminar cache útil.`r`n`r`nExecutar mesmo assim?" -f $script:LastStatus.RAMFreeGB,$freePct),
                    'Standby RAM - limpeza provavelmente desnecessária',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning
                )
                if($answer -ne [System.Windows.MessageBoxResult]::Yes){return}
                $force=$true
            }
        }
        Show-Operation -Action 'RamStandbyClean' -Data ([pscustomobject]@{Force=$force}) -Title 'Limpar Standby RAM' -Description 'Usa o método nativo do Windows. EmptyStandbyList.exe é apenas fallback opcional. Pode causar recarregamento de dados que estavam em cache.' -ConfirmText 'Executar a limpeza manual da Standby RAM?' -Danger $true
    }catch{Show-UiError -ErrorRecord $_ -Context 'Standby RAM'}
}

function Start-FullRamCleanupUi {
    try{
        Show-Operation -Action 'RamFullClean' -Data ([pscustomobject]@{Force=$true}) -Title 'Limpeza COMPLETA da RAM' -Description 'EXPERIMENTAL: usa comandos nativos equivalentes a workingsets + modifiedpagelist + standbylist. Pode eliminar cache útil e causar recarregamentos ou stutter.' -ConfirmText 'Executar LIMPEZA COMPLETA da RAM? Use somente para diagnóstico ou pressão anormal de memória.' -Danger $true
    }catch{Show-UiError -ErrorRecord $_ -Context 'Limpeza completa da RAM'}
}

function Get-RecentLogSummary {
    try{
        $files=@(Get-ChildItem -LiteralPath $Logs -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object {$_.Name -notmatch '^(preflight_|selfprobe_)'} |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5)
        if($files.Count -eq 0){return 'Nenhuma operação registrada ainda.'}
        $friendly=@{
            MaintenanceWeekly='Manutenção semanal';FullCleanPC='Limpeza completa do PC';RamStandbyClean='Standby RAM';RamFullClean='Limpeza completa da RAM';
            ProfileUniversal='Perfil Universal';ProfileAggressive='Perfil Agressivo';ProfileExtreme='Perfil Extremo';ProfileGamerBrowser='Perfil Gamer + Navegador';
            HealthScan='Verificar integridade';RepairWindows='Reparar Windows';DiagnosticReport='Relatório de diagnóstico';
            FlushDNS='Limpar DNS';UpdateCache='Cache Windows Update';GamingAll='Gaming Completo';RestoreAll='Rollback completo'
        }
        $lines=New-Object System.Collections.Generic.List[string]
        foreach($f in $files){
            $action=$f.BaseName
            if($f.BaseName -match '^\d{8}_\d{6}_(.+?)_[0-9a-fA-F]{6}$'){$action=$matches[1]}
            $label=if($friendly.ContainsKey($action)){$friendly[$action]}else{$action}
            [void]$lines.Add(('• {0} — {1}' -f $f.LastWriteTime.ToString('dd/MM HH:mm'),$label))
        }
        return ($lines -join "`r`n")
    }catch{return 'Não foi possível ler a atividade recente.'}
}

function Update-DashboardExtras {
    try{
        if(-not $script:DashboardRefs.ContainsKey('Recommendations')){return}
        if(-not $script:LastStatus){
            $script:DashboardRefs.Recommendations.Text='Aguardando o status do Windows para gerar recomendações.'
            $script:DashboardRefs.Recommendations.Foreground=$B.Muted
            return
        }
        $s=$script:LastStatus;$items=New-Object System.Collections.Generic.List[string];$attention=$false;$now=Get-Date
        function Days-Since($value){try{return [math]::Floor(($now-[datetime]$value).TotalDays)}catch{return $null}}

        $weekly=Days-Since $s.LastWeekly
        if($null -eq $weekly){[void]$items.Add('• [RECOMENDADO] Faça a Manutenção Semanal pela primeira vez.');$attention=$true}
        elseif($weekly -ge 7){[void]$items.Add(('• [RECOMENDADO] Manutenção Semanal vencida: {0} dia(s).' -f $weekly));$attention=$true}
        else{[void]$items.Add(('• [OK] Manutenção Semanal em dia: {0} dia(s).' -f $weekly))}

        $deep=Days-Since $s.LastDeepClean
        if($null -eq $deep){[void]$items.Add('• [OPCIONAL] Nenhuma Limpeza Final registrada; use quando quiser uma manutenção profunda.')}
        elseif($deep -ge 30){[void]$items.Add(('• [OPCIONAL] Limpeza Final há {0} dia(s); uma revisão mensal pode ser útil.' -f $deep))}

        $used=[double]$s.RAMUsedPercent
        if($used -ge 92){[void]$items.Add(('• [ATENÇÃO] RAM em {0}%. Veja processos; Standby RAM pode ser útil se o uso continuar alto.' -f $used));$attention=$true}
        elseif($used -ge 85){[void]$items.Add(('• [RECOMENDADO] RAM elevada ({0}%). Considere Standby RAM após verificar o Gerenciador de Tarefas.' -f $used));$attention=$true}
        else{[void]$items.Add(('• [OK] RAM em {0}%.' -f $used))}

        if($s.PSObject.Properties['DiskFreePercent']){
            $fp=[double]$s.DiskFreePercent
            if($fp -gt 0 -and $fp -lt 10){[void]$items.Add(('• [ATENÇÃO] Disco do sistema com apenas {0}% livre. Analise a Limpeza Final e o Armazenamento do Windows.' -f $fp));$attention=$true}
            elseif($fp -gt 0 -and $fp -lt 15){[void]$items.Add(('• [RECOMENDADO] Espaço livre do sistema baixo: {0}%.' -f $fp));$attention=$true}
        }

        $health=Days-Since $s.LastHealthScan
        if($null -eq $health){[void]$items.Add('• [OPCIONAL] Nenhuma Verificação de Integridade registrada.')}
        elseif($health -ge 30){[void]$items.Add(('• [OPCIONAL] Integridade não verificada há {0} dia(s).' -f $health))}

        $apps=Days-Since $s.LastWingetScan
        if([bool]$s.WingetAvailable){
            if($null -eq $apps -or $apps -ge 7){[void]$items.Add('• [RECOMENDADO] Verifique atualizações de aplicativos com WinGet (ciclo sugerido: 7 dias).');$attention=$true}
        }else{[void]$items.Add('• [INFO] WinGet não foi detectado; atualização centralizada de apps fica indisponível.')}

        $dns=Days-Since $s.LastDnsReview
        if($null -eq $dns -or $dns -ge 30){[void]$items.Add('• [OPCIONAL] Revise o DNS com DNS Jumper (~30 dias ou após trocar de rede/ISP).')}

        if([bool]$s.RebootPending){[void]$items.Add('• [ATENÇÃO] O Windows indica reinicialização pendente.');$attention=$true}
        if($s.PSObject.Properties['PostReboot'] -and $s.PostReboot){if([bool]$s.PostReboot.RebootDetected){$tag=if([bool]$s.PostReboot.Verified){'[OK]'}else{'[ATENÇÃO]'};[void]$items.Add(('• {0} Pós-reboot: {1} → perfil detectado {2}.' -f $tag,[string]$s.PostReboot.Action,[string]$s.PostReboot.DetectedProfile));if(-not [bool]$s.PostReboot.Verified){$attention=$true}}elseif([bool]$s.PostReboot.Pending){[void]$items.Add(('• [ATENÇÃO] Reinício ainda pendente após {0}.' -f [string]$s.PostReboot.Action));$attention=$true}}
        if($s.PSObject.Properties['UpdatePaused']){
            if([string]$s.UpdatePaused -eq 'SIM'){[void]$items.Add('• [ATENÇÃO] Windows Update está pausado pelo Super Optimizer.');$attention=$true}
            elseif([string]$s.UpdatePaused -eq 'PARCIAL'){[void]$items.Add('• [ATENÇÃO] Pausa do Windows Update está parcial; use Reativar Update.');$attention=$true}
        }
        if($items.Count -eq 0){[void]$items.Add('Tudo certo por agora. Nenhuma recomendação pendente.')}
        $script:DashboardRefs.Recommendations.Text=$items -join "`r`n"
        $script:DashboardRefs.Recommendations.Foreground=if($attention){$B.Yellow}else{$B.Muted}
    }catch{Write-UiError -ErrorRecord $_ -Context 'Dashboard - recomendações'}
}

function Copy-DashboardSummary {
    try{
        if(-not $script:LastStatus){Show-Info 'O status ainda não foi carregado.' 'Copiar resumo';return}
        $s=$script:LastStatus
        $txt=@(
            'SUPER OPTIMIZER - RESUMO DO PC'
            ('Perfil: {0}' -f $s.Profile)
            ('Windows: {0}' -f $s.Windows)
            ('CPU: {0}' -f $s.CPU)
            ('RAM: {0} GB total / {1} GB livre / {2}% em uso' -f $s.RAMTotalGB,$s.RAMFreeGB,$s.RAMUsedPercent)
            ('Gaming: GameMode {0} | DVR {1}' -f $s.GameMode,$s.GameDVR)
            ('VBS/HVCI: {0}' -f $s.VBS)
            ('Serviços: {0}' -f $s.Services)
            ('Plano de energia: {0}' -f $s.PowerPlanName)
            ('VirtualBox: {0}' -f $s.VirtualBox)
        ) -join "`r`n"
        [System.Windows.Clipboard]::SetText($txt)
        Show-Info 'Resumo copiado para a área de transferência.' 'Dashboard'
    }catch{Show-UiError -ErrorRecord $_ -Context 'Copiar resumo'}
}



function Show-TextReport {
    param([string]$Title,[string]$Text,[double]$Width=820,[double]$Height=560)
    try{
        $dlg=New-Object System.Windows.Window
        $dlg.Title=$Title;$dlg.Width=$Width;$dlg.Height=$Height;$dlg.MinWidth=620;$dlg.MinHeight=380
        $dlg.Owner=$Window;$dlg.WindowStartupLocation=[System.Windows.WindowStartupLocation]::CenterOwner;$dlg.Background=$B.Bg;$dlg.Foreground=$B.Text
        $grid=New-Object System.Windows.Controls.Grid;$grid.Margin=[Windows.Thickness]::new(18)
        $r1=New-Object System.Windows.Controls.RowDefinition;$r1.Height=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);$grid.RowDefinitions.Add($r1)
        $r2=New-Object System.Windows.Controls.RowDefinition;$r2.Height=[Windows.GridLength]::Auto;$grid.RowDefinitions.Add($r2)
        $box=New-Object System.Windows.Controls.TextBox;$box.Text=$Text;$box.IsReadOnly=$true;$box.TextWrapping='NoWrap';$box.AcceptsReturn=$true;$box.VerticalScrollBarVisibility='Auto';$box.HorizontalScrollBarVisibility='Auto';$box.Background=$B.Panel;$box.Foreground=$B.Text;$box.BorderBrush=$B.Cyan;$box.FontFamily='Consolas';$box.FontSize=12;$box.Padding=[Windows.Thickness]::new(10)
        [Windows.Controls.Grid]::SetRow($box,0);$grid.Children.Add($box)|Out-Null
        $close=New-Button -Text 'Fechar' -Accent $B.Cyan -Width 140;$close.HorizontalAlignment='Right';$close.Margin=[Windows.Thickness]::new(0,12,0,0);$close.Tag=$dlg;$close.Add_Click({param($sender,$e);$sender.Tag.Close()})
        [Windows.Controls.Grid]::SetRow($close,1);$grid.Children.Add($close)|Out-Null
        $dlg.Content=$grid;[void]$dlg.ShowDialog()
    }catch{Show-UiError -ErrorRecord $_ -Context 'Relatório'}
}

function Show-CleanupAnalysisUi {
    $script:LastOperationResult=$null
    Show-Operation -Action 'CleanupAnalyze' -Data ([pscustomobject]@{NoStamp=$false;TimeoutSecondsPerArea=4}) -Title 'Analisar armazenamento' -Description 'Calcula o tamanho aproximado das áreas seguras conhecidas sem apagar arquivos. A análise possui limite por área para não travar em pastas enormes.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success -and $script:LastOperationResult.Data){
        $d=$script:LastOperationResult.Data;$lines=New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('ANÁLISE DE ARMAZENAMENTO');[void]$lines.Add('')
        if($d.PSObject.Properties['DriveTotalGB']){[void]$lines.Add(('Disco {0}: {1} GB livres de {2} GB ({3}% livre)' -f $d.Drive,$d.DriveFreeGB,$d.DriveTotalGB,$d.DriveFreePercent))}
        [void]$lines.Add(('Potencial mensurável de limpeza: ~{0} GB ({1} MB)' -f $d.TotalGB,$d.TotalMB));[void]$lines.Add('');[void]$lines.Add('ÁREA                              TAMANHO      ESTADO');[void]$lines.Add('----------------------------------------------------------------')
        foreach($i in @($d.Items)){
            $state=if($i.PSObject.Properties['Partial'] -and [bool]$i.Partial){'PARCIAL'}else{'OK'}
            [void]$lines.Add(('{0,-32} {1,10} MB   {2}' -f [string]$i.Area,[string]$i.SizeMB,$state))
        }
        [void]$lines.Add('');[void]$lines.Add([string]$d.Note);[void]$lines.Add('')
        if([double]$d.DriveFreePercent -gt 0 -and [double]$d.DriveFreePercent -lt 10){[void]$lines.Add('RECOMENDAÇÃO: espaço livre crítico. Priorize Limpeza Completa/Final e revise aplicativos/arquivos grandes.')}
        elseif([double]$d.TotalGB -ge 2){[void]$lines.Add('RECOMENDAÇÃO: há espaço mensurável relevante para limpeza.')}
        else{[void]$lines.Add('RECOMENDAÇÃO: o ganho mensurável está baixo; não há motivo para limpar agressivamente só por rotina.')}
        Show-TextReport -Title 'Análise de Armazenamento' -Text ($lines -join "`r`n") -Width 800 -Height 580
    }
}

function Show-WingetResultUi {
    param([string]$Title)
    if($script:LastOperationResult -and $script:LastOperationResult.Data){
        $d=$script:LastOperationResult.Data
        $txt=if($d.PSObject.Properties['Output'] -and [string]$d.Output){[string]$d.Output}else{'O WinGet não retornou texto adicional.'}
        if($d.PSObject.Properties['Note']){$txt += "`r`n`r`nNOTA:`r`n"+[string]$d.Note}
        Show-TextReport -Title $Title -Text $txt -Width 900 -Height 620
    }
}

function Start-WingetScanUi {
    param([bool]$IncludeUnknown=$false);$script:LastOperationResult=$null
    Show-Operation -Action 'WingetScan' -Data ([pscustomobject]@{IncludeUnknown=$IncludeUnknown}) -Title 'Buscar atualizações de aplicativos' -Description 'Usa WinGet para listar aplicativos reconhecidos que possuem atualização disponível.'
    Show-WingetResultUi -Title 'WinGet - Atualizações encontradas'
}


function Start-WingetUpgradeUi {
    param([bool]$IncludeUnknown=$false);$script:LastOperationResult=$null
    $extra=if($IncludeUnknown){' Inclui pacotes cuja versão instalada não pôde ser determinada pelo WinGet.'}else{''}
    $confirm=if($IncludeUnknown){'Atualizar todos os aplicativos reconhecidos, INCLUINDO pacotes com versão atual desconhecida?'}else{'Atualizar todos os aplicativos reconhecidos pelo WinGet que possuem upgrade disponível?'}
    Show-Operation -Action 'WingetUpgradeAll' -Data ([pscustomobject]@{IncludeUnknown=$IncludeUnknown}) -Title 'Atualizar aplicativos com WinGet' -Description ('Executa winget upgrade --all.'+$extra) -ConfirmText $confirm -Danger $true
    Show-WingetResultUi -Title 'WinGet - Resultado da atualização'
}


function Find-DnsJumperPath {
    foreach($p in @(
        (Join-Path $AppRoot 'Tools\DnsJumper.exe'),
        (Join-Path $AppRoot 'Tools\DNSJumper\DnsJumper.exe'),
        (Join-Path $AppRoot 'DnsJumper.exe')
    )){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
    return $null
}

function Start-DnsJumperUi {
    try{
        $p=Find-DnsJumperPath
        if(-not $p){
            $answer=[System.Windows.MessageBox]::Show("DNS Jumper não foi encontrado.`r`n`r`nColoque DnsJumper.exe em:`r`nSuperOptimizer\Tools\DnsJumper.exe`r`n`r`nDeseja abrir a página oficial da Sordum?",'DNS Jumper',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Information)
            if($answer -eq [System.Windows.MessageBoxResult]::Yes){Start-Process 'https://www.sordum.org/7952/dns-jumper-v2-3/'}
            return
        }
        Start-Process -FilePath $p
    }catch{Show-UiError -ErrorRecord $_ -Context 'DNS Jumper'}
}

function Show-Cleanup {
    try{
        $script:CurrentPage='Cleanup';Clear-Page
        Add-PageHeader -Title 'Central de Limpeza' -Subtitle 'Armazenamento primeiro: analise antes de apagar. Depois escolha Semanal, Completa ou Final. Um nível maior já engloba os menores.'

        $storage=New-GridActionCard -Title 'Armazenamento • analisar antes' -Subtitle 'Mostra espaço livre do disco e estima TEMP, Windows Temp, Shader DirectX, Windows Update e relatórios WER sem apagar nada.' -Columns 2
        $analyze=New-Button -Text 'ANALISAR ARMAZENAMENTO' -Accent $B.Green -Width 0
        $openStorage=New-Button -Text 'Abrir Armazenamento do Windows' -Accent $B.Cyan -Width 0
        Add-GridButton -Grid $storage.Grid -Button $analyze
        Add-GridButton -Grid $storage.Grid -Button $openStorage
        $PageHost.Children.Add($storage.Card)|Out-Null
        $analyze.Add_Click({Show-CleanupAnalysisUi})
        $openStorage.Add_Click({try{Start-Process 'ms-settings:storagesense'}catch{Show-UiError -ErrorRecord $_ -Context 'Armazenamento'}})

        $main=New-GridActionCard -Title 'Plano de limpeza' -Subtitle 'Semanal = rotina. Completa = ampla. Final = profunda/ocasional. As proteções absolutas continuam ativas.' -Columns 3
        foreach($btn in @(
            (New-ActionButton -Text 'Manutenção Semanal' -Action 'MaintenanceWeekly' -Accent $B.Green -Confirm 'Executar a manutenção semanal? TEMP do usuário + Windows Temp + DNS.' -Description 'Recomendação padrão: a cada 7 dias.'),
            (New-ActionButton -Text 'Limpeza Completa' -Action 'FullCleanPC' -Accent $B.Yellow -Confirm 'Executar a Limpeza Completa? Inclui temporários, shaders, cache baixado do Windows Update, Lixeira e DNS.' -Danger $true -Description 'Ao concluir, a Manutenção Semanal também fica marcada como em dia.'),
            (New-ActionButton -Text 'Limpeza Final / Profunda' -Action 'DeepCleanPC' -Accent $B.Red -Confirm 'Executar a Limpeza Final? Além da Completa, limpa Delivery Optimization, relatórios WER, Component Store substituído (WinSxS) e Standby RAM somente se o uso estiver alto. Pode demorar.' -Danger $true -Description 'Indicada ocasionalmente, não diariamente. Preserva Downloads, Recent/Acesso Rápido, Prefetch, Event Logs, Windows.old e perfis/caches de navegadores.')
        )){Add-GridButton -Grid $main.Grid -Button $btn}
        $PageHost.Children.Add($main.Card)|Out-Null

        $individual=New-GridActionCard -Title 'Limpezas individuais' -Subtitle 'Use quando quiser agir em uma única área sem repetir a limpeza inteira.' -Columns 3
        foreach($btn in @(
            (New-ActionButton -Text 'TEMP do Usuário' -Action 'TempUser' -Accent $B.Cyan -Confirm 'Limpar TEMP do usuário?'),
            (New-ActionButton -Text 'Windows Temp' -Action 'TempWindows' -Accent $B.Cyan -Confirm 'Limpar Windows Temp?'),
            (New-ActionButton -Text 'Limpar DNS' -Action 'FlushDNS' -Accent $B.Cyan),
            (New-ActionButton -Text 'Shader DirectX' -Action 'ShaderCache' -Accent $B.Yellow -Confirm 'Limpar cache DirectX? Jogos podem recompilar shaders.' -Danger $true),
            (New-ActionButton -Text 'Cache Windows Update' -Action 'UpdateCache' -Accent $B.Yellow -Confirm 'Limpar somente SoftwareDistribution\Download?' -Danger $true),
            (New-ActionButton -Text 'Delivery Optimization' -Action 'DeliveryOptimizationCache' -Accent $B.Yellow -Confirm 'Limpar cache de Otimização de Entrega do Windows?' -Danger $true),
            (New-ActionButton -Text 'Relatórios de Erro (WER)' -Action 'WerReports' -Accent $B.Yellow -Confirm 'Remover relatórios WER em fila/arquivados? Isso elimina material de diagnóstico antigo.' -Danger $true),
            (New-ActionButton -Text 'Esvaziar Lixeira' -Action 'RecycleBin' -Accent $B.Yellow -Confirm 'Esvaziar Lixeira?' -Danger $true)
        )){Add-GridButton -Grid $individual.Grid -Button $btn}
        $PageHost.Children.Add($individual.Card)|Out-Null

        $ram=New-GridActionCard -Title 'Memória RAM — separada da limpeza de arquivos' -Subtitle 'Standby RAM é recomendada apenas sob pressão de memória. A limpeza completa da RAM permanece manual/experimental.' -Columns 3
        $info=New-Button -Text 'Ver uso da RAM' -Accent $B.Cyan -Width 0
        $standby=New-Button -Text 'Limpar Standby RAM' -Accent $B.Yellow -Width 0
        $full=New-Button -Text 'Limpeza COMPLETA da RAM' -Accent $B.Red -Width 0
        foreach($b in @($info,$standby,$full)){Add-GridButton -Grid $ram.Grid -Button $b}
        $PageHost.Children.Add($ram.Card)|Out-Null
        $info.Add_Click({Show-RamUsageUi});$standby.Add_Click({Start-StandbyRamCleanupUi});$full.Add_Click({Start-FullRamCleanupUi})

        $protect=New-Text -Text 'SEMPRE PRESERVADO: Downloads • Documentos pessoais • Recent/Acesso Rápido • Prefetch • Event Logs • Windows.old • dados/perfis de navegadores.' -Size 11 -Color $B.Muted -Margin ([Windows.Thickness]::new(2,0,0,8))
        $PageHost.Children.Add($protect)|Out-Null
    }catch{Show-UiError -ErrorRecord $_ -Context 'Central de Limpeza'}
}

function Show-DnsLab {
    try{
        $script:CurrentPage='DnsLab';Clear-Page
        Add-PageHeader -Title 'DNS / Rede' -Subtitle 'Para a fase final, o benchmark próprio foi retirado da interface. DNS Jumper é o caminho recomendado para testar muitos resolvedores; o Super Optimizer mantém apenas ferramentas nativas simples e rollback.'

        $p=Find-DnsJumperPath
        $dnsCard=New-GridActionCard -Title 'DNS Jumper — recomendado' -Subtitle $(if($p){'DnsJumper.exe detectado. Use o próprio Fastest DNS da ferramenta para comparar servidores e aplicar o vencedor.'}else{'DnsJumper.exe ainda não está em Tools. O Super Optimizer não redistribui o executável de terceiros; você pode baixar no site oficial da Sordum.'}) -Columns 3
        $open=New-Button -Text 'Abrir DNS Jumper' -Accent $B.Green -Width 0
        $site=New-Button -Text 'Site oficial / Download' -Accent $B.Cyan -Width 0
        $tools=New-Button -Text 'Abrir pasta Tools' -Accent $B.Cyan -Width 0
        foreach($b in @($open,$site,$tools)){Add-GridButton -Grid $dnsCard.Grid -Button $b}
        $PageHost.Children.Add($dnsCard.Card)|Out-Null
        $open.Add_Click({Start-DnsJumperUi})
        $site.Add_Click({try{Start-Process 'https://www.sordum.org/7952/dns-jumper-v2-3/'}catch{Show-UiError -ErrorRecord $_ -Context 'Site DNS Jumper'}})
        $tools.Add_Click({try{$tp=Join-Path $AppRoot 'Tools';New-Item -ItemType Directory -Force -Path $tp|Out-Null;Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $tp)}catch{Show-UiError -ErrorRecord $_ -Context 'Tools'}})

        # Ferramentas nativas usam a mesma grade explícita das demais áreas estáveis.
        # Card crítico em XAML estático: evita a regressão de conteúdo invisível observada no PS 5.1.
        $nativeXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Ferramentas nativas / recuperação" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Não fazem benchmark. Servem para conferir, limpar cache e recuperar configurações feitas por versões anteriores do Super Optimizer." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="DnsStatusButton" Grid.Row="0" Grid.Column="0" Content="Ver DNS atual" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DnsFlushButton" Grid.Row="0" Grid.Column="1" Content="Limpar cache DNS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DnsReviewButton" Grid.Row="1" Grid.Column="0" Content="Registrar revisão DNS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DnsRestoreButton" Grid.Row="1" Grid.Column="1" Content="Restaurar DNS original" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $nativeCard=New-UiFragment -Xaml $nativeXaml
        $dnsStatusBtn=$nativeCard.FindName('DnsStatusButton')
        $dnsFlushBtn=$nativeCard.FindName('DnsFlushButton')
        $dnsReviewBtn=$nativeCard.FindName('DnsReviewButton')
        $dnsRestoreBtn=$nativeCard.FindName('DnsRestoreButton')
        $PageHost.Children.Add($nativeCard)|Out-Null
        $dnsStatusBtn.Add_Click({Show-Operation -Action 'DNSStatus' -Data ([pscustomobject]@{}) -Title 'Ver DNS atual' -Description ''})
        $dnsFlushBtn.Add_Click({Show-Operation -Action 'FlushDNS' -Data ([pscustomobject]@{}) -Title 'Limpar cache DNS' -Description ''})
        $dnsReviewBtn.Add_Click({Show-Operation -Action 'DNSReviewStamp' -Data ([pscustomobject]@{}) -Title 'Registrar revisão DNS' -Description 'Use depois de concluir um teste/revisão no DNS Jumper. A recomendação mensal será reiniciada.'})
        $dnsRestoreBtn.Add_Click({Show-Operation -Action 'DNSRestore' -Data ([pscustomobject]@{}) -Title 'Restaurar DNS original' -Description '' -ConfirmText 'Restaurar o DNS salvo antes de alterações feitas pelo Super Optimizer?' -Danger $true})

        $note=New-Text -Text 'DNS pode reduzir o tempo de resolução de nomes e tornar navegação/login/descoberta inicial mais rápidos. Ele normalmente NÃO altera a rota do jogo nem o ping da partida depois da conexão estabelecida. Recomendo revisar DNS a cada ~30 dias ou quando trocar de rede/ISP.' -Size 12 -Color $B.Muted -Margin ([Windows.Thickness]::new(2,0,0,8))
        $PageHost.Children.Add($note)|Out-Null
    }catch{Show-UiError -ErrorRecord $_ -Context 'DNS / Rede'}
}

function Show-Dashboard {
    try {
        $script:CurrentPage = 'Dashboard';Clear-Page
        Add-PageHeader -Title 'Dashboard' -Subtitle 'Smart Care: status, recomendações persistentes, limpeza, atualizações de apps e principais funções em uma única tela.'

        # 2x2 evita KPIs espremidos quando a janela está próxima da largura mínima.
        $grid=New-Object System.Windows.Controls.Primitives.UniformGrid;$grid.Columns=2;$grid.Margin=[Windows.Thickness]::new(-6,0,-6,14)
        $profile=New-StatusCard -Label 'PERFIL';$gaming=New-StatusCard -Label 'GAMING';$vbs=New-StatusCard -Label 'VBS / HVCI';$services=New-StatusCard -Label 'SERVIÇOS'
        foreach($c in @($profile,$gaming,$vbs,$services)){$grid.Children.Add($c.Card)|Out-Null};$PageHost.Children.Add($grid)|Out-Null

        $systemCard=New-Card;$ss=New-Object System.Windows.Controls.StackPanel;$ss.Children.Add((New-Text -Text 'SISTEMA' -Size 12 -Color $B.Muted -Bold -Margin ([Windows.Thickness]::new(0,0,0,8))))|Out-Null;$sys=New-Text -Text 'Carregando informações...' -Size 13;$ss.Children.Add($sys)|Out-Null;$systemCard.Child=$ss;$PageHost.Children.Add($systemCard)|Out-Null
        $msg=New-Text -Text 'Lendo status...' -Size 12 -Color $B.Yellow -Margin ([Windows.Thickness]::new(0,0,0,10));$PageHost.Children.Add($msg)|Out-Null

        # Smart Care usa conteúdo direto. O ScrollViewer principal da página já cuida de listas longas;
        # evitar um ScrollViewer aninhado elimina o card grande/vazio observado no PowerShell 5.1.
        $recommendCard=New-Card;$recommendCard.Padding=[Windows.Thickness]::new(18,15,18,15)
        $rs=New-Object System.Windows.Controls.StackPanel
        $rs.Children.Add((New-Text -Text 'SMART CARE • RECOMENDAÇÕES' -Size 15 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,0,0,6))))|Out-Null
        $recommend=New-Text -Text 'Aguardando status do Windows para gerar recomendações.' -Size 12 -Color $B.Muted
        $recommend.Margin=[Windows.Thickness]::new(0,2,0,0)
        $rs.Children.Add($recommend)|Out-Null
        $recommendCard.Child=$rs;$PageHost.Children.Add($recommendCard)|Out-Null

        $quick=New-GridActionCard -Title 'Ações principais' -Subtitle 'O que você provavelmente vai usar com mais frequência.' -Columns 3
        $weeklyBtn=New-ActionButton -Text 'Manutenção Semanal' -Action 'MaintenanceWeekly' -Accent $B.Green -Confirm 'Executar a Manutenção Semanal agora?'
        $analyze=New-Button -Text 'Analisar armazenamento' -Accent $B.Cyan -Width 0
        $cleanBtn=New-ActionButton -Text 'Limpeza Completa' -Action 'FullCleanPC' -Accent $B.Yellow -Confirm 'Executar a Limpeza Completa segura?' -Danger $true
        $deepBtn=New-ActionButton -Text 'Limpeza Final' -Action 'DeepCleanPC' -Accent $B.Red -Confirm 'Executar a Limpeza Final/Profunda? Pode incluir DISM StartComponentCleanup e demorar.' -Danger $true
        $ramInfo=New-Button -Text 'Ver RAM' -Accent $B.Cyan -Width 0
        $standby=New-Button -Text 'Standby RAM' -Accent $B.Yellow -Width 0
        $studio=New-Button -Text 'Otimizar Windows' -Accent $B.Cyan -Width 0
        $dns=New-Button -Text 'DNS Jumper / Rede' -Accent $B.Cyan -Width 0
        $diag=New-Button -Text 'Diagnóstico Rápido' -Accent $B.Cyan -Width 0
        foreach($b in @($weeklyBtn,$analyze,$cleanBtn,$deepBtn,$ramInfo,$standby,$studio,$dns,$diag)){Add-GridButton -Grid $quick.Grid -Button $b}
        $PageHost.Children.Add($quick.Card)|Out-Null
        # FINAL: este painel usa XAML estático. Em algumas combinações de DPI/PowerShell 5.1,
        # o antigo UniformGrid dinâmico chegou a desenhar apenas o card vazio.
        $intelXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Estado &amp; histórico" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Informação objetiva: saúde, histórico, backups e confirmação pós-reboot." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="HealthSummaryButton" Grid.Row="0" Grid.Column="0" Content="Saúde objetiva do PC" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="HistoryButton" Grid.Row="0" Grid.Column="1" Content="Histórico de alterações" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StateManagerButton" Grid.Row="1" Grid.Column="0" Content="Backup / State Manager" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="PostRebootButton" Grid.Row="1" Grid.Column="1" Content="Relatório pós-reboot" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $intelCard=New-UiFragment -Xaml $intelXaml
        $intelCard.FindName('HealthSummaryButton').Add_Click({Show-HealthSummaryUi})
        $intelCard.FindName('HistoryButton').Add_Click({Show-HistoryUi})
        $intelCard.FindName('StateManagerButton').Add_Click({Show-StateManagerUi})
        $intelCard.FindName('PostRebootButton').Add_Click({
            Show-Operation -Action 'PostRebootStatus' -Data ([pscustomobject]@{}) -Title 'Relatório pós-reboot' -Description 'Confirma se o Windows reiniciou após uma alteração que recomendou reboot.'
        })
        $PageHost.Children.Add($intelCard)|Out-Null
        # WinGet e atalhos são XAML estático porque foram os blocos mais sensíveis no PowerShell 5.1 real.
        $appsXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Atualizações de aplicativos" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="WinGet centraliza upgrades de aplicativos reconhecidos. Primeiro busque; depois atualize. A opção avançada inclui pacotes cuja versão instalada o WinGet não consegue determinar." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="WingetScanButton" Grid.Column="0" Content="Buscar atualizações" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="WingetUpgradeButton" Grid.Column="1" Content="Atualizar apps (WinGet)" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
    <CheckBox x:Name="WingetUnknownCheck" Content="Incluir pacotes com versão atual desconhecida (--include-unknown)" IsChecked="False" Foreground="#94A3B8" FontSize="12" Margin="6,10,6,2" VerticalContentAlignment="Center"/>
  </StackPanel>
</Border>
"@
        $appsCard=New-UiFragment -Xaml $appsXaml
        $scanApps=$appsCard.FindName('WingetScanButton')
        $updateApps=$appsCard.FindName('WingetUpgradeButton')
        $unknown=$appsCard.FindName('WingetUnknownCheck')
        $scanApps.Tag=$unknown;$updateApps.Tag=$unknown
        $PageHost.Children.Add($appsCard)|Out-Null

        $toolsXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Atalhos do Windows" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Somente abrem ferramentas nativas." FontSize="12" Foreground="#94A3B8" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="RefreshStatusButton" Grid.Row="0" Grid.Column="0" Content="Atualizar status" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="TaskManagerButton" Grid.Row="0" Grid.Column="1" Content="Gerenciador de Tarefas" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StartupAppsButton" Grid.Row="0" Grid.Column="2" Content="Apps de Inicialização" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StorageButton" Grid.Row="1" Grid.Column="0" Content="Armazenamento" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="WindowsUpdateButton" Grid.Row="1" Grid.Column="1" Content="Windows Update" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="WindowsSecurityButton" Grid.Row="1" Grid.Column="2" Content="Segurança do Windows" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DeviceManagerButton" Grid.Row="2" Grid.Column="0" Content="Gerenciador de Dispositivos" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="CopySummaryButton" Grid.Row="2" Grid.Column="1" Content="Copiar resumo do PC" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $toolsCard=New-UiFragment -Xaml $toolsXaml
        $refresh=$toolsCard.FindName('RefreshStatusButton')
        $taskmgr=$toolsCard.FindName('TaskManagerButton')
        $startup=$toolsCard.FindName('StartupAppsButton')
        $storage=$toolsCard.FindName('StorageButton')
        $windowsUpdate=$toolsCard.FindName('WindowsUpdateButton')
        $security=$toolsCard.FindName('WindowsSecurityButton')
        $devices=$toolsCard.FindName('DeviceManagerButton')
        $copySummary=$toolsCard.FindName('CopySummaryButton')
        $PageHost.Children.Add($toolsCard)|Out-Null

        $script:DashboardRefs=@{Profile=$profile.Value;Gaming=$gaming.Value;VBS=$vbs.Value;Services=$services.Value;System=$sys;Message=$msg;Recommendations=$recommend}
        $analyze.Add_Click({Show-CleanupAnalysisUi});$ramInfo.Add_Click({Show-RamUsageUi});$standby.Add_Click({Start-StandbyRamCleanupUi});$studio.Add_Click({Show-Page -Page 'System'});$dns.Add_Click({Show-Page -Page 'DnsLab'});$diag.Add_Click({Show-DiagnosticQuickUi});$scanApps.Add_Click({param($sender,$e);Start-WingetScanUi -IncludeUnknown ([bool]$sender.Tag.IsChecked)});$updateApps.Add_Click({param($sender,$e);Start-WingetUpgradeUi -IncludeUnknown ([bool]$sender.Tag.IsChecked)})
        $refresh.Add_Click({$script:StatusRefreshRequested=$true;$HeaderStatus.Text='ADMIN • ATUALIZANDO'});$taskmgr.Add_Click({try{Start-Process 'taskmgr.exe'}catch{Show-UiError -ErrorRecord $_ -Context 'Task Manager'}});$startup.Add_Click({try{Start-Process 'ms-settings:startupapps'}catch{Show-UiError -ErrorRecord $_ -Context 'Inicialização'}});$storage.Add_Click({try{Start-Process 'ms-settings:storagesense'}catch{Show-UiError -ErrorRecord $_ -Context 'Armazenamento'}});$windowsUpdate.Add_Click({try{Start-Process 'ms-settings:windowsupdate'}catch{Show-UiError -ErrorRecord $_ -Context 'Windows Update'}});$security.Add_Click({try{Start-Process 'windowsdefender:'}catch{Show-UiError -ErrorRecord $_ -Context 'Segurança'}});$devices.Add_Click({try{Start-Process 'devmgmt.msc'}catch{Show-UiError -ErrorRecord $_ -Context 'Dispositivos'}});$copySummary.Add_Click({Copy-DashboardSummary})
        Update-DashboardStatus;Update-DashboardExtras;if(-not $script:LastStatus -and -not $script:StatusProcess){$script:StatusRefreshRequested=$true}
    } catch {Show-UiError -ErrorRecord $_ -Context 'Dashboard'}
}


function ConvertTo-ComparisonValueText {
    param($Value)
    if($null -eq $Value){return '(não informado)'}
    if($Value -is [string]){
        if($Value.Length -eq 0){return '(vazio)'}
        return $Value
    }
    if($Value -is [ValueType]){return [string]$Value}
    return (ConvertTo-Json -InputObject $Value -Depth 32 -Compress)
}

function Get-ComparisonRows {
    param($Comparison,[string]$Search='')
    foreach($change in @($Comparison)){
        if($null -eq $change){continue}
        foreach($field in @('Category','Item','Before','After')){
            if(-not $change.PSObject.Properties[$field]){throw ('Comparação incompleta: campo ausente '+$field)}
        }
        $row=[pscustomobject]@{
            Category=[string]$change.Category
            Item=[string]$change.Item
            Before=(ConvertTo-ComparisonValueText -Value $change.Before)
            After=(ConvertTo-ComparisonValueText -Value $change.After)
        }
        $text=@($row.Category,$row.Item,$row.Before,$row.After) -join "`n"
        if([string]::IsNullOrWhiteSpace($Search) -or $text.IndexOf($Search.Trim(),[StringComparison]::OrdinalIgnoreCase) -ge 0){$row}
    }
}

function Show-ComparisonResultUi {
    param($Comparison,[string]$Title='Antes x Depois')
    try{
        $rows=@(Get-ComparisonRows -Comparison $Comparison)
        $dlg=New-Object System.Windows.Window
        $dlg.Title=$Title;$dlg.Width=1100;$dlg.Height=700;$dlg.MinWidth=760;$dlg.MinHeight=450
        $dlg.Owner=$Window;$dlg.WindowStartupLocation='CenterOwner';$dlg.Background=$B.Bg;$dlg.Foreground=$B.Text
        $content=New-UiFragment -Xaml @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="18">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="Diferenças observadas nos alvos monitorados. Isto não representa uma auditoria completa do Windows." TextWrapping="Wrap" Foreground="#94A3B8" Margin="0,0,0,12"/>
  <DockPanel Grid.Row="1" Margin="0,0,0,12">
    <TextBlock Text="Buscar:" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="#F1F5F9" Margin="0,0,10,0"/>
    <TextBox x:Name="Search" ToolTip="Buscar categoria, item ou valor (texto literal)" Background="#111B31" Foreground="#F1F5F9" Padding="8"/>
  </DockPanel>
  <DataGrid x:Name="Changes" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" CanUserDeleteRows="False" SelectionMode="Single" HeadersVisibility="Column" Background="#111B31" Foreground="#F1F5F9" EnableRowVirtualization="True">
    <DataGrid.Columns>
      <DataGridTextColumn Header="Categoria" Binding="{Binding Category}" Width="140"/>
      <DataGridTextColumn Header="Item" Binding="{Binding Item}" Width="2*"/>
      <DataGridTextColumn Header="Antes" Binding="{Binding Before}" Width="*"/>
      <DataGridTextColumn Header="Depois" Binding="{Binding After}" Width="*"/>
    </DataGrid.Columns>
  </DataGrid>
  <DockPanel Grid.Row="3" Margin="0,12,0,0">
    <TextBlock x:Name="Count" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="#94A3B8"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="Export" Content="Exportar CSV filtrado" Padding="12,8" Margin="6,0" Background="#111B31" Foreground="#22D3EE"/>
      <Button x:Name="Close" Content="Fechar" Padding="12,8" Background="#111B31" Foreground="#F1F5F9"/>
    </StackPanel>
  </DockPanel>
</Grid>
'@
        $grid=$content.FindName('Changes');$search=$content.FindName('Search');$count=$content.FindName('Count');$export=$content.FindName('Export')
        try{$grid.ColumnHeaderStyle=$Window.FindResource('DarkDataGridHeaderStyle');$grid.CellStyle=$Window.FindResource('DarkDataGridCellStyle');$grid.RowStyle=$Window.FindResource('DarkDataGridRowStyle')}catch{}
        $grid.ItemsSource=$rows
        $count.Text=if($rows.Count){'{0} diferença(s) monitorada(s)' -f $rows.Count}else{'Nenhuma diferença observável nos alvos monitorados.'}
        $export.IsEnabled=($rows.Count -gt 0)
        $search.Tag=[pscustomobject]@{Rows=$rows;Grid=$grid;Count=$count;Export=$export}
        $search.Add_TextChanged({
            param($sender,$eventArgs)
            $ctx=$sender.Tag
            $filtered=@(Get-ComparisonRows -Comparison $ctx.Rows -Search $sender.Text)
            $ctx.Grid.ItemsSource=$filtered
            $ctx.Count.Text=('{0} de {1} diferença(s)' -f $filtered.Count,$ctx.Rows.Count)
            $ctx.Export.IsEnabled=($filtered.Count -gt 0)
        })
        $export.Tag=[pscustomobject]@{Grid=$grid;Window=$dlg}
        $export.Add_Click({
            param($sender,$eventArgs)
            try{
                $save=New-Object Microsoft.Win32.SaveFileDialog
                $save.Title='Exportar diferenças exibidas';$save.Filter='CSV (*.csv)|*.csv';$save.FileName='Antes-Depois.csv';$save.DefaultExt='.csv';$save.AddExtension=$true;$save.OverwritePrompt=$true
                if($save.ShowDialog($sender.Tag.Window) -eq $true){
                    @($sender.Tag.Grid.ItemsSource) | Export-Csv -LiteralPath $save.FileName -NoTypeInformation -Encoding UTF8
                    Show-Info -Title 'Comparação exportada' -Text ('Arquivo salvo em: '+$save.FileName)
                }
            }catch{Show-UiError -ErrorRecord $_ -Context 'Exportar comparação'}
        })
        $close=$content.FindName('Close');$close.Tag=$dlg;$close.Add_Click({param($sender,$eventArgs);$sender.Tag.Close()})
        $dlg.Content=$content;[void]$dlg.ShowDialog()
    }catch{Show-UiError -ErrorRecord $_ -Context 'Antes x Depois'}
}

function Get-SelfTestOutcome {
    param([string]$Report,[Nullable[int]]$ExitCode)
    $outcome=[pscustomobject]@{State='Inconclusive';Passed=0;Total=0;Message='AUTO-TESTE inconclusivo: relatório sem contagem válida de testes.'}
    $matches=[regex]::Matches($Report,'(?im)^\s*RESULTADO:\s*(\d+)\/(\d+)\s+testes aprovados\s*$')
    if($matches.Count -eq 1){
        $passed=0;$total=0
        if([int]::TryParse($matches[0].Groups[1].Value,[ref]$passed) -and [int]::TryParse($matches[0].Groups[2].Value,[ref]$total)){
            $outcome.Passed=$passed;$outcome.Total=$total
        }
    }
    $hasErrors=[regex]::IsMatch($Report,'(?im)^\s*\[(ERRO|ERROR|FALHA|FAIL)\]')
    if(($null -ne $ExitCode -and $ExitCode -ne 0) -or $hasErrors){
        $outcome.State='Failed';$outcome.Message=('AUTO-TESTE encontrou erro(s). ExitCode={0}' -f $ExitCode)
    }elseif($matches.Count -eq 1 -and $outcome.Total -gt 0 -and $outcome.Passed -le $outcome.Total){
        if($outcome.Passed -ne $outcome.Total){
            $outcome.State='Failed';$outcome.Message=('AUTO-TESTE reprovado • {0}/{1}' -f $outcome.Passed,$outcome.Total)
        }elseif($null -eq $ExitCode){
            $outcome.Message='AUTO-TESTE inconclusivo: não foi possível confirmar o ExitCode.'
        }else{
            $outcome.State='Passed';$outcome.Message=('AUTO-TESTE APROVADO • {0}/{1}' -f $outcome.Passed,$outcome.Total)
        }
    }
    return $outcome
}


function Show-ProfileComparisonUi {
    param([string]$Target)
    Show-Operation -Action 'ProfileCompare' -Data ([pscustomobject]@{Target=$Target}) -Title ('Comparar perfil → '+$Target) -Description 'Somente leitura: mostra o que será acrescentado ou restaurado.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success){$d=$script:LastOperationResult.Data;$lines=@(('PERFIL ATUAL: '+[string]$d.Current),('ALVO: '+[string]$d.Target),'');$lines+='SERÁ ADICIONADO:';if(@($d.WillAdd).Count){$lines += @($d.WillAdd|ForEach-Object {'• '+[string]$_})}else{$lines+='• Nada'};$lines+='';$lines+='SERÁ RESTAURADO/REMOVIDO:';if(@($d.WillRestore).Count){$lines += @($d.WillRestore|ForEach-Object {'• '+[string]$_})}else{$lines+='• Nada'};$lines+='';$lines += ('Reinício recomendado: '+$(if([bool]$d.RebootRecommended){'SIM'}else{'NÃO'}));Show-TextReport -Title ('Comparação '+$d.Current+' → '+$d.Target) -Text ($lines -join "`r`n") -Width 760 -Height 560}
}

function Show-HistoryUi {
    Show-Operation -Action 'HistoryGet' -Data ([pscustomobject]@{}) -Title 'Histórico de alterações' -Description 'Carregando timeline persistente desta máquina.'
    if(-not($script:LastOperationResult -and $script:LastOperationResult.Success)){return}
    $items=@($script:LastOperationResult.Data)
    $dlg=New-Object System.Windows.Window;$dlg.Title='Histórico de alterações';$dlg.Width=1050;$dlg.Height=650;$dlg.Owner=$Window;$dlg.WindowStartupLocation='CenterOwner';$dlg.Background=$B.Bg;$dlg.Foreground=$B.Text
    $g=New-Object System.Windows.Controls.Grid;$g.Margin=[Windows.Thickness]::new(18);$r1=New-Object System.Windows.Controls.RowDefinition;$r1.Height=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);$r2=New-Object System.Windows.Controls.RowDefinition;$r2.Height=[Windows.GridLength]::Auto;[void]$g.RowDefinitions.Add($r1);[void]$g.RowDefinitions.Add($r2)
    $grid=New-Object System.Windows.Controls.DataGrid;$grid.AutoGenerateColumns=$false;$grid.IsReadOnly=$true;$grid.SelectionMode='Single';$grid.SelectionUnit='FullRow';$grid.Background=$B.Panel;$grid.Foreground=$B.Text;$grid.HeadersVisibility='Column';$grid.GridLinesVisibility='Horizontal';$grid.ItemsSource=$items;$grid.CanUserAddRows=$false;$grid.CanUserDeleteRows=$false;$grid.EnableRowVirtualization=$true;$grid.EnableColumnVirtualization=$true;$grid.AlternationCount=2
    try{$grid.ColumnHeaderStyle=$Window.FindResource('DarkDataGridHeaderStyle');$grid.CellStyle=$Window.FindResource('DarkDataGridCellStyle');$grid.RowStyle=$Window.FindResource('DarkDataGridRowStyle')}catch{}
    foreach($spec in @(@('Timestamp','Quando',170),@('Action','Ação',190),@('Message','Resultado',420),@('Warnings','Avisos',70))){$c=New-Object System.Windows.Controls.DataGridTextColumn;$c.Header=$spec[1];$c.Binding=New-Object System.Windows.Data.Binding($spec[0]);$c.Width=[double]$spec[2];[void]$grid.Columns.Add($c)}
    [Windows.Controls.Grid]::SetRow($grid,0);[void]$g.Children.Add($grid)
    $bar=New-Object System.Windows.Controls.StackPanel;$bar.Orientation='Horizontal';$bar.HorizontalAlignment='Right';$bar.Margin=[Windows.Thickness]::new(0,12,0,0);$open=New-Button -Text 'Abrir log selecionado' -Accent $B.Cyan -Width 190;$changes=New-Button -Text 'Ver Antes x Depois' -Accent $B.Green -Width 180;$close=New-Button -Text 'Fechar' -Accent $B.Red -Width 110;foreach($b in @($open,$changes,$close)){[void]$bar.Children.Add($b)};[Windows.Controls.Grid]::SetRow($bar,1);[void]$g.Children.Add($bar)
    $open.Add_Click({
        try{
            $x=$grid.SelectedItem;$log=$null
            if($x -and $x.LogPath -and (Test-Path -LiteralPath ([string]$x.LogPath))){$log=[string]$x.LogPath}
            elseif($x -and $x.PSObject.Properties['LogRelative'] -and $x.LogRelative){$candidate=Join-Path $State ([string]$x.LogRelative);if(Test-Path -LiteralPath $candidate){$log=$candidate}}
            if($log){Start-Process notepad.exe -ArgumentList ('"{0}"' -f $log)}else{Show-Info -Title 'Histórico' -Text 'Selecione uma ação com log disponível. Se o State foi movido, logs antigos só abrem quando o arquivo também acompanhou a pasta State.'}
        }catch{}
    })
    $changes.Add_Click({$x=$grid.SelectedItem;if($x){Show-ComparisonResultUi -Comparison @($x.Changes) -Title ('Antes x Depois — '+[string]$x.Action)}})
    $close.Add_Click({$dlg.Close()});$dlg.Content=$g;[void]$dlg.ShowDialog()
}

function Show-StateManagerUi {
    Show-Operation -Action 'StateManager' -Data ([pscustomobject]@{}) -Title 'Backup / State Manager' -Description 'Inspecionando backups e isolamento por MachineGuid.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success){$d=$script:LastOperationResult.Data;$lines=@('BACKUP / STATE MANAGER','',('Máquina: '+$d.ComputerName),('MachineId: '+$d.MachineId),('Primeiro backup: '+$(if($d.FirstBackup){$d.FirstBackup}else{'Ainda não há backup'})),('Tamanho: '+$d.TotalSizeMB+' MB'),('Integridade: '+$d.Health+' • problemas='+$d.Issues),('Rollback disponível: '+$(if([bool]$d.RollbackAvailable){'SIM'}else{'NÃO'})),'','CATEGORIAS');foreach($p in $d.Categories.PSObject.Properties){$lines += ('• {0}: {1} arquivo(s)' -f $p.Name,$p.Value)};$lines += @('','MODO PORTÁTIL',([string]$d.PortableNote));Show-TextReport -Title 'Backup / State Manager' -Text ($lines -join "`r`n") -Width 800 -Height 620}
}

function Show-HealthSummaryUi {
    Show-Operation -Action 'HealthSummary' -Data ([pscustomobject]@{}) -Title 'Saúde objetiva do PC' -Description 'Sem nota artificial: apenas estados verificáveis.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success){$d=$script:LastOperationResult.Data;$lines=@('SAÚDE OBJETIVA DO PC','');foreach($b in @($d.Blocks)){$lines += ('[{0}] {1}' -f $b.State,$b.Name);$lines += ('  '+[string]$b.Detail)};$p=$d.PostReboot;$lines += @('','PÓS-REBOOT',('Pendente: '+$p.Pending),('Reboot detectado: '+$p.RebootDetected),('Perfil esperado: '+$p.ExpectedProfile),('Perfil detectado: '+$p.DetectedProfile),('Verificado: '+$p.Verified));Show-TextReport -Title 'Saúde objetiva do PC' -Text ($lines -join "`r`n") -Width 760 -Height 580}
}

function Export-StudioSelectionUi {
    $mods=@(Get-StudioSelectedModulesUi);if($mods.Count -eq 0){Show-Info -Title 'Exportar seleção' -Text 'Marque pelo menos um módulo.';return}
    $dlg=New-Object Microsoft.Win32.SaveFileDialog;$dlg.Filter='Configuração Super Optimizer (*.json)|*.json';$dlg.FileName='super_optimizer_selection.json';if($dlg.ShowDialog($Window)){$obj=[ordered]@{Schema='SuperOptimizerStudioSelection';Version=1;Created=(Get-Date).ToString('o');Modules=[string[]]$mods};$obj|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $dlg.FileName -Encoding UTF8;Show-Info -Title 'Exportar seleção' -Text ('Configuração salva em:`r`n'+$dlg.FileName)}
}
function Import-StudioSelectionUi {
    $dlg=New-Object Microsoft.Win32.OpenFileDialog;$dlg.Filter='Configuração Super Optimizer (*.json)|*.json';if(-not $dlg.ShowDialog($Window)){return};try{$o=Get-Content $dlg.FileName -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$o.Schema -ne 'SuperOptimizerStudioSelection'){throw 'Arquivo não é uma seleção do Super Optimizer.'};$allowed=@($script:StudioUiState.Order);$mods=@($o.Modules|Where-Object {$allowed -contains [string]$_});foreach($id in $allowed){$script:StudioUiState.Checks[$id].IsChecked=($mods -contains $id)};Update-StudioSelectionSummaryUi;Show-Info -Title 'Importar seleção' -Text ("{0} módulo(s) carregado(s)." -f $mods.Count)}catch{Show-Info -Title 'Importar seleção' -Text ('Arquivo inválido: '+$_.Exception.Message)}
}
function Save-CustomProfileUi {
    $mods=@(Get-StudioSelectedModulesUi);if($mods.Count -eq 0){Show-Info -Title 'Perfil personalizado' -Text 'Marque pelo menos um módulo.';return}
    $name=[Microsoft.VisualBasic.Interaction]::InputBox('Nome do perfil personalizado:','Salvar perfil personalizado','Meu Perfil Gaming');if([string]::IsNullOrWhiteSpace($name)){return};Show-Operation -Action 'CustomProfileSave' -Data ([pscustomobject]@{Name=$name;Modules=[string[]]$mods}) -Title 'Salvar perfil personalizado' -Description ('Módulos: '+($mods -join ', '))
}
function Load-CustomProfileUi {
    Show-Operation -Action 'CustomProfilesGet' -Data ([pscustomobject]@{}) -Title 'Perfis personalizados' -Description 'Carregando perfis salvos.';if(-not($script:LastOperationResult -and $script:LastOperationResult.Success)){return};$items=@($script:LastOperationResult.Data);if($items.Count -eq 0){Show-Info -Title 'Perfis personalizados' -Text 'Nenhum perfil personalizado salvo.';return};$names=@($items|ForEach-Object {[string]$_.Name});$chosen=[Microsoft.VisualBasic.Interaction]::InputBox(("Digite exatamente um dos nomes:`r`n`r`n"+($names -join "`r`n")),'Carregar perfil personalizado',$names[0]);if([string]::IsNullOrWhiteSpace($chosen)){return};$p=$items|Where-Object {[string]$_.Name -eq $chosen}|Select-Object -First 1;if(-not $p){Show-Info -Title 'Perfis personalizados' -Text 'Perfil não encontrado.';return};foreach($id in @($script:StudioUiState.Order)){$script:StudioUiState.Checks[$id].IsChecked=(@($p.Modules) -contains $id)};Update-StudioSelectionSummaryUi
}

function Show-Profiles {
    try {
        $script:CurrentPage = 'Profiles'
        Clear-Page
        Add-PageHeader -Title 'Perfis de Otimização' -Subtitle 'Universal prioriza compatibilidade. Agressivo e Extremo são para PCs gamers com uso conhecido e contam com rollback por máquina.'

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin=[Windows.Thickness]::new(0,0,0,0)
        for ($i=0;$i -lt 3;$i++) {
            $col = New-Object System.Windows.Controls.ColumnDefinition
            $col.Width = [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
            [void]$grid.ColumnDefinitions.Add($col)
        }

        $defs = @(
            [pscustomobject]@{Title='UNIVERSAL';Accent=$B.Green;Action='ProfileUniversal';Danger=$false;Desc="Compatibilidade primeiro.`r`n`r`n• Game Mode`r`n• MMCSS Games`r`n• Foreground 0x26`r`n`r`nNão desativa serviços, Update, OneDrive ou segurança."},
            [pscustomobject]@{Title='AGRESSIVO';Accent=$B.Cyan;Action='ProfileAggressive';Danger=$true;Desc="Para PC gamer conhecido.`r`n`r`nInclui DVR OFF, background reduzido, telemetria, energia, hibernação e serviços curados.`r`n`r`nPreserva Xbox/Store/Bluetooth/Câmera/Mic/Phone Link/VirtualBox. OneDrive é reduzido neste perfil fixo; use Gamer + Navegador para preservá-lo."},
            [pscustomobject]@{Title='EXTREMO';Accent=$B.Red;Action='ProfileExtreme';Danger=$true;Desc="Tudo do Agressivo + VBS/HVCI/Hypervisor do Windows OFF.`r`n`r`nPode afetar WSL2, Docker, Hyper-V e Sandbox.`r`n`r`nAMD-V/SVM da BIOS permanece habilitado para VirtualBox."}
        )

        for ($i=0;$i -lt $defs.Count;$i++) {
            $d = $defs[$i]
            $card = New-Card -Margin ([Windows.Thickness]::new(6,0,6,16))
            $card.MinHeight = 356
            $body = New-Object System.Windows.Controls.Grid
            foreach($h in @('Auto','*','Auto','Auto')){
                $rd=New-Object System.Windows.Controls.RowDefinition
                $rd.Height=if($h -eq '*'){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::Auto}
                [void]$body.RowDefinitions.Add($rd)
            }

            $title=New-Text -Text $d.Title -Size 19 -Color $d.Accent -Bold -Margin ([Windows.Thickness]::new(0,0,0,12))
            [Windows.Controls.Grid]::SetRow($title,0);[void]$body.Children.Add($title)

            $desc=New-Text -Text $d.Desc -Size 12 -Margin ([Windows.Thickness]::new(0,0,0,12))
            $desc.VerticalAlignment=[System.Windows.VerticalAlignment]::Top
            [Windows.Controls.Grid]::SetRow($desc,1);[void]$body.Children.Add($desc)

            $restoreLine=New-CheckboxLine -Text 'Criar ponto de restauração antes' -Checked $true -ToolTip 'Se marcado, o perfil só prossegue quando o ponto de restauração solicitado puder ser criado.'
            $restoreLine.Container.Margin=[Windows.Thickness]::new(0,4,0,10)
            [Windows.Controls.Grid]::SetRow($restoreLine.Container,2);[void]$body.Children.Add($restoreLine.Container)

            $button=New-Button -Text ('Aplicar '+$d.Title) -Accent $d.Accent -Width 0
            $button.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Stretch
            $button.Tag=[pscustomobject]@{Action=$d.Action;Title=$d.Title;Danger=$d.Danger;Check=$restoreLine.CheckBox}
            $button.Add_Click({
                param($sender,$eventArgs)
                try{
                    $tag=$sender.Tag
                    $data=[pscustomobject]@{AutoRestorePoint=[bool]$tag.Check.IsChecked}
                    $confirm=if($tag.Danger){'Aplicar o perfil '+[string]$tag.Title+'? O estado original será salvo para rollback.'}else{'Aplicar o perfil '+[string]$tag.Title+'?'}
                    Show-Operation -Action ([string]$tag.Action) -Data $data -Title ('Perfil '+[string]$tag.Title) -Description 'As alterações são registradas por MachineGuid e podem ser revertidas no menu Rollback.' -ConfirmText $confirm -Danger ([bool]$tag.Danger)
                }catch{Show-UiError -ErrorRecord $_ -Context 'Aplicar perfil'}
            })
            # RC14.2: ações empilhadas ocupam toda a largura do card. Isso evita
            # clipping do botão Comparar em janelas estreitas e com DPI/escala alta.
            $actions=New-Object System.Windows.Controls.StackPanel
            $actions.Orientation=[System.Windows.Controls.Orientation]::Vertical
            $button.Margin=[Windows.Thickness]::new(0,0,0,8);$button.MinWidth=0;[void]$actions.Children.Add($button)
            $compare=New-Button -Text 'Comparar perfil' -Accent $B.Yellow -Width 0;$compare.Margin=[Windows.Thickness]::new(0);$compare.MinWidth=0;$compare.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Stretch;$compare.Tag=[string]$d.Title;$compare.Add_Click({param($sender,$eventArgs);Show-ProfileComparisonUi -Target ([string]$sender.Tag)});[void]$actions.Children.Add($compare)
            [Windows.Controls.Grid]::SetRow($actions,3);[void]$body.Children.Add($actions)

            $card.Child=$body
            [Windows.Controls.Grid]::SetColumn($card,$i)
            [void]$grid.Children.Add($card)
        }

        $PageHost.Children.Add($grid) | Out-Null

        $PageHost.Children.Add((New-Text -Text 'Qual usar?  Universal: PC de outra pessoa ou uso desconhecido.  •  Agressivo: PC gamer com recursos conhecidos.  •  Extremo: quando você aceita reduzir VBS/HVCI para priorizar desempenho.' -Size 12 -Color $B.Muted -Margin ([Windows.Thickness]::new(4,0,4,14))))|Out-Null

        # V3.8.1: perfil focado em jogo + navegador, com preservação explícita de recursos usados.
        $gamerWebXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="0.95*"/><ColumnDefinition Width="1.25*"/></Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0" Margin="0,0,18,0">
      <TextBlock Text="GAMER + NAVEGADOR" FontSize="20" FontWeight="SemiBold" Foreground="#A78BFA" Margin="0,0,0,6"/>
      <TextBlock Text="Para PC pessoal focado em jogos, navegador e uso doméstico. Você escolhe o que deve permanecer intacto." FontSize="12" Foreground="#F1F5F9" TextWrapping="Wrap" Margin="0,0,0,10"/>
      <TextBlock Text="Aplica: Game Mode, MMCSS, Foreground, DVR OFF, mouse accel OFF, background/telemetria reduzidos, energia Gaming, serviços curados e Defender ativo com scan em 20%." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,10"/>
      <TextBlock Text="SEMPRE PRESERVADOS" FontSize="12" FontWeight="SemiBold" Foreground="#34D399" Margin="0,2,0,4"/>
      <TextBlock Text="Áudio • Microsoft Store/Xbox • Bluetooth • câmera/microfone • Phone Link • Windows Update. O Defender permanece ativo." FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
      <CheckBox x:Name="GamerWebRestorePoint" Content="Criar ponto de restauração antes" IsChecked="True" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,10"/>
      <Button x:Name="GamerWebApply" Content="Aplicar GAMER + NAVEGADOR" Height="46" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#A78BFA" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </StackPanel>
    <Border Grid.Column="1" Background="#111B31" BorderBrush="#243B63" BorderThickness="1" CornerRadius="8" Padding="14">
      <StackPanel>
        <TextBlock Text="Recursos que eu uso — marque para PRESERVAR" FontSize="15" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
        <TextBlock Text="Desmarcar permite ao perfil otimizar aquele recurso. O estado original continua salvo para rollback." FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <CheckBox x:Name="GamerWebPrinter" Grid.Row="0" Grid.Column="0" Content="Impressora / Print Spooler" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebSearch" Grid.Row="0" Grid.Column="1" Content="Windows Search / indexação" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebOneDrive" Grid.Row="1" Grid.Column="0" Content="OneDrive / sincronização" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebRdp" Grid.Row="1" Grid.Column="1" Content="Área de Trabalho Remota (RDP)" IsChecked="False" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebVpn" Grid.Row="2" Grid.Column="0" Content="VPN / roteamento" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebHotspot" Grid.Row="2" Grid.Column="1" Content="Hotspot / compartilhamento" IsChecked="False" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebBiometrics" Grid.Row="3" Grid.Column="0" Content="Windows Hello / biometria" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebDiscovery" Grid.Row="3" Grid.Column="1" Content="Descoberta de rede / UPnP" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
          <CheckBox x:Name="GamerWebHibernate" Grid.Row="4" Grid.Column="0" Content="Hibernação" IsChecked="True" Foreground="#F1F5F9" Margin="4,6"/>
        </Grid>
        <TextBlock Text="Se desmarcar Impressora, o Print Spooler será desativado. Impressoras USB/rede e recursos como Microsoft Print to PDF podem parar até o serviço ser restaurado." FontSize="11" Foreground="#FBBF24" TextWrapping="Wrap" Margin="4,6,4,2"/>
        <Separator Margin="0,8" Background="#243B63"/>
        <CheckBox x:Name="GamerWebVirtualization" Content="VirtualBox / WSL2 / Docker / Hyper-V / Sandbox — preservar virtualização" IsChecked="True" Foreground="#F1F5F9" Margin="4,4"/>
        <TextBlock Text="ATENÇÃO: se desmarcar virtualização, o perfil desativa VBS/HVCI/Hypervisor do Windows e recomenda reinício. AMD-V/SVM da BIOS não é desativado." FontSize="11" Foreground="#FBBF24" TextWrapping="Wrap" Margin="4,6,4,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Border>
"@
        $gamerWeb=New-UiFragment -Xaml $gamerWebXaml

        # RC15.2: callbacks WPF não devem depender de variáveis locais da função de página.
        # No Windows PowerShell 5.1, o Click pode ocorrer depois que Show-Profiles já saiu de
        # escopo; nesse caso $gamerWeb vira $null e a exceção só reaparece embrulhada pelo
        # ShowDialog da janela principal. Guardamos referências reais aos controles no Tag
        # do botão, o mesmo padrão estável usado no restante da interface.
        $gamerWebApply=$gamerWeb.FindName('GamerWebApply')
        $gamerCtx=[pscustomobject]@{
            RestorePoint=$gamerWeb.FindName('GamerWebRestorePoint')
            Printer=$gamerWeb.FindName('GamerWebPrinter')
            Search=$gamerWeb.FindName('GamerWebSearch')
            OneDrive=$gamerWeb.FindName('GamerWebOneDrive')
            Rdp=$gamerWeb.FindName('GamerWebRdp')
            Vpn=$gamerWeb.FindName('GamerWebVpn')
            Hotspot=$gamerWeb.FindName('GamerWebHotspot')
            Biometrics=$gamerWeb.FindName('GamerWebBiometrics')
            Discovery=$gamerWeb.FindName('GamerWebDiscovery')
            Hibernate=$gamerWeb.FindName('GamerWebHibernate')
            Virtualization=$gamerWeb.FindName('GamerWebVirtualization')
        }
        if($null -eq $gamerWebApply){throw 'Controle GamerWebApply não foi materializado pelo XAML.'}
        foreach($p in @($gamerCtx.PSObject.Properties)){
            if($null -eq $p.Value){throw ('Controle do perfil Gamer + Navegador não foi materializado: '+$p.Name)}
        }
        $gamerWebApply.Tag=$gamerCtx
        $gamerWebApply.Add_Click({
            param($sender,$eventArgs)
            try{
                $ctx=$sender.Tag
                if($null -eq $ctx){throw 'Contexto do perfil Gamer + Navegador não está disponível.'}
                $preserveVirtual=[bool]$ctx.Virtualization.IsChecked
                $preservePrinter=[bool]$ctx.Printer.IsChecked
                $data=[pscustomobject]@{
                    AutoRestorePoint=[bool]$ctx.RestorePoint.IsChecked
                    PreservePrinter=$preservePrinter
                    PreserveSearch=[bool]$ctx.Search.IsChecked
                    PreserveOneDrive=[bool]$ctx.OneDrive.IsChecked
                    PreserveRdp=[bool]$ctx.Rdp.IsChecked
                    PreserveVpn=[bool]$ctx.Vpn.IsChecked
                    PreserveHotspot=[bool]$ctx.Hotspot.IsChecked
                    PreserveBiometrics=[bool]$ctx.Biometrics.IsChecked
                    PreserveNetworkDiscovery=[bool]$ctx.Discovery.IsChecked
                    PreserveHibernation=[bool]$ctx.Hibernate.IsChecked
                    PreserveVirtualization=$preserveVirtual
                }
                $warnings=New-Object System.Collections.Generic.List[string]
                if(-not $preservePrinter){[void]$warnings.Add('IMPRESSORA está DESMARCADA. O Print Spooler será desativado; impressoras e Microsoft Print to PDF podem parar até a restauração.')}
                if(-not $preserveVirtual){[void]$warnings.Add('VIRTUALIZAÇÃO está DESMARCADA. VBS/HVCI/Hypervisor do Windows serão desligados e um reinício será recomendado.')}
                $extra=if($warnings.Count -gt 0){"`r`n`r`nATENÇÃO:`r`n- "+($warnings -join "`r`n- ")}else{''}
                Show-Operation -Action 'ProfileGamerBrowser' -Data $data -Title 'Perfil Gamer + Navegador' -Description 'Perfil pessoal com recursos preservados de acordo com as caixas marcadas.' -ConfirmText ('Aplicar o perfil Gamer + Navegador com esta personalização?'+$extra) -Danger (($warnings.Count -gt 0))
                $script:StatusRefreshRequested=$true
            }catch{
                Show-UiError -ErrorRecord $_ -Context 'Perfil Gamer + Navegador - aplicar'
            }
        })
        $PageHost.Children.Add($gamerWeb)|Out-Null

        # RC13.9: o estado ORIGINAL fica visível na própria tela de Perfis.
        # Ele reutiliza RestoreAll; não existe uma segunda implementação de rollback.
        $originalXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="1.2*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0" Margin="0,0,18,0">
      <TextBlock Text="ORIGINAL / ANTES DO SUPER OPTIMIZER" FontSize="18" FontWeight="SemiBold" Foreground="#FBBF24" Margin="0,0,0,8"/>
      <TextBlock Text="Restaura o estado capturado antes da primeira alteração feita pelo Super Optimizer neste computador." FontSize="12" Foreground="#F1F5F9" TextWrapping="Wrap" Margin="0,0,0,8"/>
      <TextBlock Text="Isso não é 'padrão de fábrica': se o PC já possuía um ajuste manual antes do primeiro backup, esse ajuste é o original que será recuperado." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
      <Button x:Name="ProfileRestoreOriginal" Content="Restaurar estado ORIGINAL" Height="46" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </StackPanel>
    <Border Grid.Column="1" Background="#111B31" BorderBrush="#243B63" BorderThickness="1" CornerRadius="8" Padding="14">
      <StackPanel>
        <TextBlock Text="Como funcionam as camadas" FontSize="15" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,8"/>
        <TextBlock Text="ORIGINAL → estado salvo antes das mudanças&#x0a;UNIVERSAL → núcleo gamer compatível&#x0a;AGRESSIVO → Universal + serviços/background/energia&#x0a;EXTREMO → Agressivo + VBS/HVCI/Hypervisor OFF" FontSize="12" Foreground="#F1F5F9" TextWrapping="Wrap" Margin="0,0,0,12"/>
        <TextBlock Text="A pasta State é a memória do rollback. Preserve-a ao atualizar o programa." FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Button x:Name="ProfileAuditState" Grid.Column="0" Content="Auditar State" Height="40" Margin="0,0,6,0" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
          <Button x:Name="ProfileOpenState" Grid.Column="1" Content="Abrir pasta State" Height="40" Margin="6,0,0,0" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
        </Grid>
      </StackPanel>
    </Border>
  </Grid>
</Border>
"@
        $originalCard=New-UiFragment -Xaml $originalXaml
        $originalCard.FindName('ProfileRestoreOriginal').Add_Click({
            Show-Operation -Action 'RestoreAll' -Data ([pscustomobject]@{}) -Title 'Restaurar estado ORIGINAL' -Description 'Restaura os backups capturados antes das primeiras alterações do Super Optimizer neste computador.' -ConfirmText 'Restaurar Registro, serviços, tarefas, energia, Defender, VBS/Hypervisor e demais estados salvos para o ORIGINAL deste computador?' -Danger $true
            $script:StatusRefreshRequested=$true
        })
        $originalCard.FindName('ProfileAuditState').Add_Click({
            Show-Operation -Action 'StateAudit' -Data ([pscustomobject]@{}) -Title 'Auditoria do State' -Description 'Valida backups e identidade dos arquivos persistidos sem alterar o Windows.'
        })
        $originalCard.FindName('ProfileOpenState').Add_Click({
            try{Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $State)}catch{Show-UiError -ErrorRecord $_ -Context 'Pasta State'}
        })
        $PageHost.Children.Add($originalCard)|Out-Null
    } catch {Show-UiError -ErrorRecord $_ -Context 'Perfis'}
}

function Show-Maintenance {
    try {
        $script:CurrentPage = 'Maintenance'
        Clear-Page
        Add-PageHeader -Title 'Manutenção do Windows' -Subtitle 'Diagnóstico, integridade, reparo e armazenamento. Limpezas ficam exclusivamente na aba Limpeza para evitar duplicidade.'

        # RC13.3: layout composto em XAML estático. No Windows PowerShell 5.1,
        # subseções anexadas dinamicamente após um UniformGrid podiam reservar espaço
        # mas deixar o conteúdo invisível. O fragmento abaixo é medido/renderizado como uma unidade.
        $xaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Diagnóstico e integridade" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Comece pela verificação. Estas opções analisam o sistema sem iniciar reparos pesados." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="MaintHealth" Grid.Column="0" Content="Verificar Integridade" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="MaintDisk" Grid.Column="1" Content="CHKDSK /scan" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="MaintWinsxsAnalyze" Grid.Column="2" Content="Analisar WinSxS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>

    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="Reparo e manutenção avançada" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Use somente quando houver motivo. Estas operações podem demorar." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="MaintWinsxsClean" Grid.Column="0" Content="Limpar WinSxS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="MaintRepair" Grid.Column="1" Content="Reparar Windows" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FB7185" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>

    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="Windows Update e armazenamento" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Analise o armazenamento, abra as telas nativas e faça manutenção do cache de atualização." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="MaintStorageAnalyze" Grid.Row="0" Grid.Column="0" Content="Analisar armazenamento" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="MaintStorageOpen" Grid.Row="0" Grid.Column="1" Content="Abrir Armazenamento" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="MaintUpdateOpen" Grid.Row="1" Grid.Column="0" Content="Abrir Windows Update" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="MaintUpdateCache" Grid.Row="1" Grid.Column="1" Content="Cache Windows Update" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $card=New-UiFragment -Xaml $xaml
        $PageHost.Children.Add($card)|Out-Null

        $card.FindName('MaintHealth').Add_Click({Show-Operation -Action 'HealthScan' -Data ([pscustomobject]@{}) -Title 'Verificar Integridade' -Description 'Verifica a imagem e os arquivos protegidos do Windows sem forçar reparo.' -ConfirmText 'Executar DISM CheckHealth + ScanHealth + SFC VerifyOnly? Pode demorar.'})
        $card.FindName('MaintDisk').Add_Click({Show-Operation -Action 'DiskScan' -Data ([pscustomobject]@{}) -Title 'CHKDSK /scan' -Description 'Verifica o volume online; não agenda formatação nem apaga arquivos.' -ConfirmText 'Executar verificação online do disco do sistema?'})
        $card.FindName('MaintWinsxsAnalyze').Add_Click({Show-Operation -Action 'ComponentAnalyze' -Data ([pscustomobject]@{}) -Title 'Analisar WinSxS' -Description 'Executa DISM AnalyzeComponentStore. Apenas analisa o armazenamento de componentes.'})
        $card.FindName('MaintWinsxsClean').Add_Click({Show-Operation -Action 'ComponentCleanup' -Data ([pscustomobject]@{}) -Title 'Limpar WinSxS' -Description 'Não usa /ResetBase. Também faz parte da Limpeza Final.' -ConfirmText 'Executar DISM StartComponentCleanup? Pode demorar e remover componentes substituídos.' -Danger $true})
        $card.FindName('MaintRepair').Add_Click({Show-Operation -Action 'RepairWindows' -Data ([pscustomobject]@{}) -Title 'Reparar Windows' -Description 'Use se a verificação encontrar corrupção ou se o Windows apresentar erros.' -ConfirmText 'Executar DISM RestoreHealth + SFC ScanNow? Pode levar bastante tempo.' -Danger $true})
        $card.FindName('MaintStorageAnalyze').Add_Click({Show-CleanupAnalysisUi})
        $card.FindName('MaintStorageOpen').Add_Click({try{Start-Process 'ms-settings:storagesense'}catch{Show-UiError -ErrorRecord $_ -Context 'Armazenamento'}})
        $card.FindName('MaintUpdateOpen').Add_Click({try{Start-Process 'ms-settings:windowsupdate'}catch{Show-UiError -ErrorRecord $_ -Context 'Windows Update'}})
        $card.FindName('MaintUpdateCache').Add_Click({Show-Operation -Action 'UpdateCache' -Data ([pscustomobject]@{}) -Title 'Cache Windows Update' -Description '' -ConfirmText 'Limpar SoftwareDistribution\Download? Não faça durante downloads da Store/Xbox.' -Danger $true})
    } catch {Show-UiError -ErrorRecord $_ -Context 'Manutenção'}
}

function Get-GamingPriorityRows {
    $root='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $mid=$null
    try {
        $mid=((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid -replace '[^a-zA-Z0-9-]','_')
    } catch {}

    $managed=@{}
    if($mid){
        $regDir=Join-Path $State ('Machines\'+$mid+'\Registry')
        foreach($bf in @(Get-ChildItem -LiteralPath $regDir -Filter '*.json' -ErrorAction SilentlyContinue)){
            try{
                $bo=Get-Content -LiteralPath $bf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if($bo.Category -eq 'PerGame' -and $bo.Path -match 'Image File Execution Options\\([^\\]+)\\PerfOptions$'){
                    $managed[$matches[1].ToLowerInvariant()]=$bo
                }
            }catch{}
        }
    }

    $rows=New-Object System.Collections.Generic.List[object]
    if(Test-Path $root){
        foreach($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)){
            $exe=[string]$k.PSChildName
            $perf="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions"
            try{$v=(Get-ItemProperty -LiteralPath $perf -Name CpuPriorityClass -ErrorAction Stop).CpuPriorityClass}catch{continue}
            $label=switch([int]$v){
                1{'IDLE'};2{'NORMAL'};3{'HIGH'};4{'REALTIME'};5{'BELOW NORMAL'};6{'ABOVE NORMAL'};default{'VALOR '+[string]$v}
            }
            $origin='DETECTADO'
            $key=$exe.ToLowerInvariant()
            if($managed.ContainsKey($key)){
                try{
                    $b=$managed[$key]
                    $originalValue=if([bool]$b.Exists){[int]$b.Data}else{$null}
                    if([int]$v -eq 3 -and ((-not [bool]$b.Exists) -or $originalValue -ne 3)){$origin='SUPER OPTIMIZER'}
                    elseif([bool]$b.Exists -and [int]$v -eq $originalValue){$origin='ORIGINAL / RESTAURADO'}
                    else{$origin='ALTERADO APÓS BACKUP'}
                }catch{$origin='BACKUP INVÁLIDO'}
            }
            [void]$rows.Add([pscustomobject]@{Executable=$exe;Priority=$label;Managed=$origin})
        }
    }
    return @($rows|Sort-Object Executable)
}

function Update-GamingPriorityGrid {
    param([Parameter(Mandatory=$true)]$Grid)
    try{
        $Grid.ItemsSource=@(Get-GamingPriorityRows)
    }catch{
        $Grid.ItemsSource=@([pscustomobject]@{
            Executable='Falha ao ler prioridades'
            Priority=''
            Managed=$_.Exception.Message
        })
    }
}

function Show-Gaming {
    try {
        $script:CurrentPage = 'Gaming'
        Clear-Page
        Add-PageHeader -Title 'Gaming / Scheduler' -Subtitle 'Ajustes reversíveis e uma lista separada dos executáveis que já possuem prioridade configurada.'

        $tabs=New-Object System.Windows.Controls.TabControl
        $tabs.Background=$B.Bg
        $tabs.BorderThickness=[Windows.Thickness]::new(0)
        $tabs.Margin=[Windows.Thickness]::new(0,0,0,10)

        $tabAdjust=New-Object System.Windows.Controls.TabItem
        $tabAdjust.Header='Ajustes Gaming'
        $tabAdjust.Style=$Window.FindResource('TabItemStyle')
        $adjustXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,10">
  <StackPanel>
    <TextBlock Text="Gaming" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="As configurações originais são salvas antes da primeira alteração." FontSize="12" Foreground="#94A3B8" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="GameAll" Grid.Row="0" Grid.Column="0" Content="Gaming Completo" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameMode" Grid.Row="0" Grid.Column="1" Content="Game Mode ON" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameDvr" Grid.Row="0" Grid.Column="2" Content="Game DVR OFF" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameMmcss" Grid.Row="1" Grid.Column="0" Content="MMCSS Games" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameForeground" Grid.Row="1" Grid.Column="1" Content="Foreground 0x26" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameMouse" Grid.Row="1" Grid.Column="2" Content="Mouse Accel OFF" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameRestore" Grid.Row="2" Grid.Column="0" Content="Restaurar Gaming" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="Prioridade por jogo" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,5"/>
    <TextBlock Text="Escolha o .exe do jogo. O ajuste usa CpuPriorityClass=High para processos com esse nome; nunca usa Realtime." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="GameChoose" Grid.Column="0" Content="Escolher jogo..." Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameRestoreAll" Grid.Column="1" Content="Restaurar todos os jogos" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $adjustCard=New-UiFragment -Xaml $adjustXaml
        $tabAdjust.Content=$adjustCard
        $tabs.Items.Add($tabAdjust)|Out-Null

        $adjustCard.FindName('GameAll').Add_Click({Show-Operation -Action 'GamingAll' -Data ([pscustomobject]@{}) -Title 'Gaming Completo' -Description 'Pacote gaming sem mexer em VBS ou serviços gerais.' -ConfirmText 'Aplicar Game Mode + DVR OFF + MMCSS + Foreground + Mouse?'})
        $adjustCard.FindName('GameMode').Add_Click({Show-Operation -Action 'GameMode' -Data ([pscustomobject]@{}) -Title 'Game Mode ON' -Description ''})
        $adjustCard.FindName('GameDvr').Add_Click({Show-Operation -Action 'GameDVROff' -Data ([pscustomobject]@{}) -Title 'Game DVR OFF' -Description '' -ConfirmText 'Desativar captura/gravação em segundo plano?'})
        $adjustCard.FindName('GameMmcss').Add_Click({Show-Operation -Action 'MMCSS' -Data ([pscustomobject]@{}) -Title 'MMCSS Games' -Description 'GPU Priority 8 • Priority 6 • Scheduling High • SFIO High'})
        $adjustCard.FindName('GameForeground').Add_Click({Show-Operation -Action 'Foreground' -Data ([pscustomobject]@{}) -Title 'Foreground 0x26' -Description 'Win32PrioritySeparation = 38 decimal (0x26).'})
        $adjustCard.FindName('GameMouse').Add_Click({Show-Operation -Action 'MouseAccelOff' -Data ([pscustomobject]@{}) -Title 'Mouse Accel OFF' -Description '' -ConfirmText 'Desativar a aceleração do ponteiro do Windows?'})
        $adjustCard.FindName('GameRestore').Add_Click({Show-Operation -Action 'GamingRestore' -Data ([pscustomobject]@{}) -Title 'Restaurar Gaming' -Description '' -ConfirmText 'Restaurar os valores de gaming salvos antes da primeira alteração?' -Danger $true})
        $adjustCard.FindName('GameRestoreAll').Add_Click({Show-Operation -Action 'PerGameRestore' -Data ([pscustomobject]@{}) -Title 'Restaurar todos os jogos' -Description '' -ConfirmText 'Restaurar todas as prioridades por executável salvas pelo Super Optimizer?' -Danger $true})
        $adjustCard.FindName('GameChoose').Add_Click({
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $ofd=New-Object System.Windows.Forms.OpenFileDialog
                $ofd.Filter='Executáveis (*.exe)|*.exe'
                $ofd.Title='Escolha o executável do jogo'
                if($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){
                    $exeName=[IO.Path]::GetFileName($ofd.FileName)
                    Show-Operation -Action 'PerGameSet' -Data ([pscustomobject]@{ExeName=$exeName}) -Title 'Prioridade por Jogo' -Description 'Configura CpuPriorityClass=High somente para o executável escolhido.' -ConfirmText ('Aplicar prioridade HIGH para '+$exeName+'?')
                }
            } catch {Show-UiError -ErrorRecord $_ -Context 'Prioridade por jogo'}
        })

        $tabList=New-Object System.Windows.Controls.TabItem
        $tabList.Header='Jogos priorizados'
        $tabList.Style=$Window.FindResource('TabItemStyle')
        $listXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,10">
  <StackPanel>
    <TextBlock Text="Executáveis com CpuPriorityClass configurado" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,5"/>
    <TextBlock Text="SUPER OPTIMIZER = prioridade HIGH aplicada pelo programa. DETECTADO = configuração externa e não é removida automaticamente." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <DataGrid x:Name="GamePriorityGrid" Height="250" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column" SelectionMode="Single"
              Background="#111B31" Foreground="#F1F5F9" RowBackground="#16233E" AlternatingRowBackground="#1A2A49" BorderBrush="#243B63" BorderThickness="1"
              GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#243B63">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Executável" Binding="{Binding Executable}" Width="*"/>
        <DataGridTextColumn Header="Prioridade" Binding="{Binding Priority}" Width="150"/>
        <DataGridTextColumn Header="Origem" Binding="{Binding Managed}" Width="180"/>
      </DataGrid.Columns>
    </DataGrid>
    <Grid Margin="0,8,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="GameListRefresh" Grid.Column="0" Content="Atualizar lista" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="GameListRestore" Grid.Column="1" Content="Restaurar selecionado" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $listCard=New-UiFragment -Xaml $listXaml
        $gameGrid=$listCard.FindName('GamePriorityGrid')
        try{$gameGrid.ColumnHeaderStyle=$Window.FindResource('DarkDataGridHeaderStyle')}catch{}
        try{$gameGrid.CellStyle=$Window.FindResource('DarkDataGridCellStyle')}catch{}
        try{$gameGrid.RowStyle=$Window.FindResource('DarkDataGridRowStyle')}catch{}
        $refreshList=$listCard.FindName('GameListRefresh')
        $removeSelected=$listCard.FindName('GameListRestore')
        $tabList.Content=$listCard
        $tabs.Items.Add($tabList)|Out-Null

        $refreshList.Tag=$gameGrid
        $refreshList.Add_Click({param($sender,$eventArgs);Update-GamingPriorityGrid -Grid $sender.Tag})
        $removeSelected.Tag=$gameGrid
        $removeSelected.Add_Click({
            param($sender,$eventArgs)
            try{
                $row=$sender.Tag.SelectedItem
                if(-not $row){Show-Info 'Selecione um jogo da lista primeiro.' 'Jogos priorizados';return}
                if([string]$row.Managed -ne 'SUPER OPTIMIZER'){
                    Show-Info ('O item selecionado está marcado como: '+[string]$row.Managed+'. Apenas prioridades aplicadas pelo Super Optimizer são restauradas por este botão.') 'Jogos priorizados'
                    return
                }
                Show-Operation -Action 'PerGameRemove' -Data ([pscustomobject]@{ExeName=[string]$row.Executable}) -Title 'Restaurar prioridade' -Description 'Restaura somente o executável selecionado para o estado salvo antes da primeira alteração.' -ConfirmText ('Restaurar '+[string]$row.Executable+'?') -Danger $true
                Update-GamingPriorityGrid -Grid $sender.Tag
            }catch{Show-UiError -ErrorRecord $_ -Context 'Restaurar jogo selecionado'}
        })
        Update-GamingPriorityGrid -Grid $gameGrid
        $PageHost.Children.Add($tabs)|Out-Null
    } catch {Show-UiError -ErrorRecord $_ -Context 'Gaming'}
}

function Get-StudioSelectedModulesUi {
    $mods=@();if(-not $script:StudioUiState){return [string[]]$mods}
    foreach($id in @($script:StudioUiState.Order)){try{if([bool]$script:StudioUiState.Checks[$id].IsChecked){$mods += [string]$id}}catch{}}
    return [string[]]$mods
}
function Show-WindowsStudioStatusUi {
    $script:LastOperationResult=$null;Show-Operation -Action 'WindowsStudioStatus' -Data ([pscustomobject]@{}) -Title 'Estado do Windows Studio' -Description 'Lê o estado atual dos módulos e informa se existe uma sessão reversível.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success -and $script:LastOperationResult.Data){$d=$script:LastOperationResult.Data;$lines=New-Object System.Collections.Generic.List[string];[void]$lines.Add('WINDOWS STUDIO - ESTADO ATUAL');[void]$lines.Add('');[void]$lines.Add(('Desfazer última aplicação disponível: {0}' -f $(if([bool]$d.SessionUndoAvailable){'SIM'}else{'NÃO'})));if($d.SessionCreated){[void]$lines.Add(('Sessão criada: {0}' -f [string]$d.SessionCreated))};if($d.PSObject.Properties['SessionModules'] -and @($d.SessionModules).Count -gt 0){[void]$lines.Add(('Módulos da sessão: {0}' -f (@($d.SessionModules) -join ', ')))};[void]$lines.Add('');foreach($m in @($d.Modules)){[void]$lines.Add(('[{0}] {1}  [{2}]' -f [string]$m.Id,[string]$m.Name,[string]$m.State));[void]$lines.Add(('  Atual: {0}' -f [string]$m.Current));[void]$lines.Add(('  Alvo : {0}' -f [string]$m.Target))};[void]$lines.Add('');[void]$lines.Add([string]$d.Note);Show-TextReport -Title 'Windows Studio - Estado Atual' -Text ($lines -join "`r`n") -Width 860 -Height 620}
}
function Show-DiagnosticQuickUi {
    $script:LastOperationResult=$null;Show-Operation -Action 'DiagnosticQuick' -Data ([pscustomobject]@{}) -Title 'Diagnóstico rápido' -Description 'Lê sistema, RAM, armazenamento, perfis, VBS, WinGet, Windows Update e integridade do State sem alterar o Windows.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success -and $script:LastOperationResult.Data){$d=$script:LastOperationResult.Data;$lines=@('DIAGNÓSTICO RÁPIDO','',('Windows: {0}' -f $d.Windows),('CPU: {0}' -f $d.CPU),('RAM: {0}' -f $d.RAM),('Armazenamento: {0}' -f $d.Disk),'',('Perfil: {0}' -f $d.Profile),('Gaming: {0}' -f $d.Gaming),('VBS/HVCI: {0}' -f $d.VBS),('Serviços do perfil: {0}' -f $d.Services),('Plano de energia: {0}' -f $d.PowerPlan),('Update pausado: {0}' -f $d.WindowsUpdatePaused),('WinGet: {0}' -f $d.WinGet),('Reinício pendente: {0}' -f $d.RebootPending),'',('State: {0} | arquivos={1} | problemas={2}' -f $d.StateHealth,$d.StateFilesChecked,$d.StateIssues),('Última manutenção semanal: {0}' -f $d.LastWeekly),('Última verificação de integridade: {0}' -f $d.LastHealthScan));Show-TextReport -Title 'Diagnóstico Rápido' -Text ($lines -join "`r`n") -Width 820 -Height 600}
}
function Show-StateAuditUi {
    $script:LastOperationResult=$null;Show-Operation -Action 'StateAudit' -Data ([pscustomobject]@{}) -Title 'Verificar backups / State' -Description 'Valida a estrutura e identidade dos backups desta máquina sem alterar o Windows.'
    if($script:LastOperationResult -and $script:LastOperationResult.Data){$d=$script:LastOperationResult.Data;$lines=@('AUDITORIA DO STATE','',('Saúde: {0}' -f $d.Health),('Arquivos verificados: {0}' -f $d.FilesChecked),('Problemas: {0}' -f $d.IssuesCount),'');if(@($d.Issues).Count -gt 0){$lines += @($d.Issues|ForEach-Object {'• '+[string]$_})}else{$lines += 'Nenhum problema estrutural encontrado.'};Show-TextReport -Title 'Auditoria do State' -Text ($lines -join "`r`n") -Width 820 -Height 560}
}
function Start-DiagnosticReportUi {
    $script:LastOperationResult=$null;Show-Operation -Action 'DiagnosticReport' -Data ([pscustomobject]@{}) -Title 'Gerar relatório do PC' -Description 'Gera um relatório técnico local, sem senhas nem conteúdo pessoal de arquivos.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success -and $script:LastOperationResult.Data){$p=[string]$script:LastOperationResult.Data.Path;if($p -and (Test-Path -LiteralPath $p)){try{$txt=Get-Content -LiteralPath $p -Raw -Encoding UTF8;Show-TextReport -Title 'Relatório do PC' -Text $txt -Width 900 -Height 650}catch{Show-Info -Title 'Relatório criado' -Text $p}}}
}

function Update-StudioSelectionSummaryUi {
    try{
        if(-not $script:StudioUiState -or -not $script:StudioUiState.Summary){return}
        $mods=@(Get-StudioSelectedModulesUi);$names=@();foreach($d in @($script:StudioUiState.Defs)){if($mods -contains [string]$d.Id){$names += [string]$d.Name}}
        $total=@($script:StudioUiState.Order).Count
        if($names.Count -eq 0){$script:StudioUiState.Summary.Text=('Nenhuma otimização selecionada. 0/{0}' -f $total);$script:StudioUiState.Summary.Foreground=$B.Yellow}
        else{$script:StudioUiState.Summary.Text=('Selecionadas ({0}/{1}): {2}' -f $names.Count,$total,($names -join ' • '));$script:StudioUiState.Summary.Foreground=$B.Text}
    }catch{}
}

function Add-StudioPresetSelectionUi {
    param([string]$Preset)
    if(-not $script:StudioUiState){ return }
    foreach($d in @($script:StudioUiState.Defs)){
        $match = if($Preset -eq 'Recommended'){ [bool]$d.Default } else { ([string]$d.Preset -eq $Preset) }
        if(-not $match){ continue }
        $id=[string]$d.Id
        if($script:StudioUiState.Checks.ContainsKey($id) -and $null -ne $script:StudioUiState.Checks[$id]){
            # Cumulativo por definição: preset só marca; nunca desmarca o que já estava selecionado.
            $script:StudioUiState.Checks[$id].IsChecked = $true
        }
    }
    Update-StudioSelectionSummaryUi
}

function Show-WindowsStudioChangesUi {
    param([string[]]$Modules=@())
    try{
        $defs=if($script:StudioUiState){@($script:StudioUiState.Defs)}else{@()};$selected=if($Modules -and $Modules.Count -gt 0){@($Modules)}else{@($defs|ForEach-Object {[string]$_.Id})}
        $lines=@('WINDOWS STUDIO / OPTIMIZATION LAB — PRÉVIA','','Cada item abaixo possui backup/rollback. DESFAZER ÚLTIMA APLICAÇÃO usa o snapshot imediatamente anterior.','')
        $n=0
        foreach($d in $defs){if($selected -notcontains [string]$d.Id){continue};$n++;$lines += ('{0}) [{1}] {2}' -f $n,[string]$d.Risk,[string]$d.Name);$lines += ('   Grupo: {0}' -f [string]$d.Group);$lines += ('   Alvo : {0}' -f [string]$d.Target);$lines += ('   {0}' -f [string]$d.Desc);$lines += ''}
        $lines += @('FORA DESTE LAB','• VBS/HVCI e Hypervisor: aba Virtualização (impacto de segurança separado).','• DNS: aba DNS / Rede.','• Prefetch não é alterado.','• Defender nunca é desativado; o módulo Defender só limita a carga média de scan.','', 'Módulos EXPERIMENTAIS não entram em nenhum preset recomendado.')
        Show-TextReport -Title 'Optimization Lab - Prévia' -Text ($lines -join "`r`n") -Width 980 -Height 720
    }catch{Show-UiError -ErrorRecord $_ -Context 'Detalhes Windows Studio'}
}

function Select-LastStudioSessionUi {
    try{
        $script:LastOperationResult=$null
        Show-Operation -Action 'WindowsStudioStatus' -Data ([pscustomobject]@{}) -Title 'Ler última sessão do Windows Studio' -Description 'Consulta quais módulos fizeram parte da última aplicação reversível.'
        if(-not $script:LastOperationResult -or -not $script:LastOperationResult.Success -or -not $script:LastOperationResult.Data){return}
        $mods=@($script:LastOperationResult.Data.SessionModules)
        if($mods.Count -eq 0){Show-Info -Title 'Windows Studio' -Text 'Não existe uma sessão anterior com módulos registrados.';return}
        foreach($id in @($script:StudioUiState.Order)){$script:StudioUiState.Checks[$id].IsChecked=($mods -contains $id)}
        Update-StudioSelectionSummaryUi
    }catch{Show-UiError -ErrorRecord $_ -Context 'Selecionar última sessão'}
}


function Update-StudioModuleStatesUi {
    Show-Operation -Action 'WindowsStudioStatus' -Data ([pscustomobject]@{}) -Title 'Atualizar estado dos módulos' -Description 'Somente leitura.'
    if($script:LastOperationResult -and $script:LastOperationResult.Success -and $script:StudioUiState -and $script:StudioUiState.StateRuns){foreach($m in @($script:LastOperationResult.Data.Modules)){if($script:StudioUiState.StateRuns.ContainsKey([string]$m.Id)){$run=$script:StudioUiState.StateRuns[[string]$m.Id];$run.Text=('  ['+[string]$m.State+']');$run.Foreground=switch([string]$m.State){'ATIVO'{$B.Green};'PADRÃO'{$B.Muted};'DIFERENTE'{$B.Yellow};'NÃO SUPORTADO'{$B.Red};default{$B.Muted}}}}}
}

function Show-System {
    try{
        $script:CurrentPage='System';Clear-Page
        Add-PageHeader -Title 'Otimizar Windows • Optimization Lab' -Subtitle '32 otimizações granulares, presets rápidos e rollback. Nada é aplicado só por abrir esta página.'

        $defs=@(
            [pscustomobject]@{Id='GameMode';Name='Modo de Jogo ON';Group='Gaming';Risk='BAIXO';Default=$true;Preset='Gaming';Target='Game Mode automático ON';Desc='Ativa AllowAutoGameMode e AutoGameModeEnabled.'},
            [pscustomobject]@{Id='GameDVR';Name='Capturas / Game DVR OFF';Group='Gaming';Risk='BAIXO';Default=$true;Preset='Gaming';Target='Captura em segundo plano OFF';Desc='Desliga GameDVR, AppCapture e painel inicial da Game Bar sem remover Xbox.'},
            [pscustomobject]@{Id='MMCSS';Name='Prioridade MMCSS Games';Group='Gaming';Risk='MÉDIO';Default=$true;Preset='Gaming';Target='GPU Priority 8 / Priority 6 / High';Desc='Prioridade multimídia para a tarefa Games.'},
            [pscustomobject]@{Id='Foreground';Name='Prioridade de foreground';Group='Gaming';Risk='MÉDIO';Default=$true;Preset='Gaming';Target='Win32PrioritySeparation=0x26';Desc='Favorece o aplicativo em primeiro plano.'},
            [pscustomobject]@{Id='MouseAccel';Name='Aceleração do mouse OFF';Group='Gaming';Risk='BAIXO';Default=$true;Preset='Gaming';Target='MouseSpeed/Thresholds=0';Desc='Desativa a aceleração clássica do ponteiro.'},
            [pscustomobject]@{Id='DefenderScan';Name='Defender: scan médio 20%';Group='Gaming';Risk='MÉDIO';Default=$false;Preset='Gaming';Target='ScanAvgCPULoadFactor=20';Desc='Defender continua ativo; apenas limita carga média de verificação.'},

            [pscustomobject]@{Id='Energy';Name='Plano Energia Gaming';Group='Energia';Risk='BAIXO';Default=$true;Preset='Performance';Target='Plano dedicado para uso na tomada';Desc='CPU máx. AC 100%, USB selective suspend AC OFF e PCIe ASPM AC OFF.'},
            [pscustomobject]@{Id='PowerThrottle';Name='Power Throttling OFF';Group='Energia';Risk='BAIXO';Default=$true;Preset='Performance';Target='PowerThrottlingOff=1';Desc='Reduz throttling de processos em background pelo mecanismo de energia.'},
            [pscustomobject]@{Id='Hibernation';Name='Hibernação OFF';Group='Energia';Risk='MÉDIO';Default=$false;Preset='Performance';Target='powercfg /hibernate off';Desc='Só altera quando o estado original pode ser salvo para rollback.'},

            [pscustomobject]@{Id='Visuals';Name='Efeitos visuais reduzidos';Group='Interface';Risk='BAIXO';Default=$true;Preset='Interface';Target='MinAnimate=0 + TaskbarAnimations=0; tema preservado';Desc='Reduz animação de janelas e da barra de tarefas sem alterar modo Claro/Escuro.'},
            [pscustomobject]@{Id='Transparency';Name='Transparência OFF';Group='Interface';Risk='BAIXO';Default=$false;Preset='Interface';Target='EnableTransparency=0';Desc='Remove transparência do shell.'},
            [pscustomobject]@{Id='StartupDelay';Name='Atraso de inicialização OFF';Group='Interface';Risk='MÉDIO';Default=$false;Preset='Interface';Target='StartupDelayInMSec=0';Desc='Tweak reversível do atraso de inicialização do Explorer.'},
            [pscustomobject]@{Id='Notifications';Name='Notificações Toast OFF';Group='Interface';Risk='MÉDIO';Default=$false;Preset='Interface';Target='ToastEnabled=0';Desc='Silencia notificações Toast; útil só se você realmente não as usa.'},

            [pscustomobject]@{Id='SearchSuggestions';Name='Sugestões da Pesquisa OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='DisableSearchBoxSuggestions=1';Desc='Reduz sugestões/histórico online na pesquisa do Explorer.'},
            [pscustomobject]@{Id='OneDriveSync';Name='OneDrive Sync por política OFF';Group='Background / Privacidade';Risk='MÉDIO';Default=$true;Preset='Privacy';Target='DisableFileSyncNGSC=1';Desc='Impede sincronização do OneDrive por política; reversível.'},
            [pscustomobject]@{Id='Copilot';Name='Copilot OFF por política';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='TurnOffWindowsCopilot=1';Desc='Aplica política quando a build do Windows a reconhece.'},
            [pscustomobject]@{Id='NewsInterests';Name='News / Interests OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='AllowNewsAndInterests=0';Desc='Política opcional; falha não aborta a sessão.'},
            [pscustomobject]@{Id='SuggestedContent';Name='Conteúdo sugerido OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='Sugestões e apps silenciosos OFF';Desc='Desativa SilentInstalledApps, SystemPaneSuggestions e SoftLanding.'},
            [pscustomobject]@{Id='ActivityHistory';Name='Histórico de atividade OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='Activity Feed / Publish / Upload OFF';Desc='Reduz envio/publicação do histórico de atividade.'},
            [pscustomobject]@{Id='EdgeStartup';Name='Edge Startup Boost OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='StartupBoostEnabled=0';Desc='Evita pré-inicialização do Edge quando a política é suportada.'},
            [pscustomobject]@{Id='EdgeBackground';Name='Edge em background OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='Edge BackgroundModeEnabled=0';Desc='Reduz execução do Edge após fechar a janela.'},
            [pscustomobject]@{Id='ChromeBackground';Name='Chrome em background OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='Chrome BackgroundModeEnabled=0';Desc='Reduz execução do Chrome após fechar a janela.'},
            [pscustomobject]@{Id='DeliveryOptimization';Name='Delivery Optimization P2P OFF';Group='Background / Privacidade';Risk='BAIXO';Default=$true;Preset='Privacy';Target='DODownloadMode=0';Desc='Evita distribuição P2P; Windows Update continua funcional.'},

            [pscustomobject]@{Id='TelemetryPolicy';Name='Política de telemetria mínima';Group='Telemetria / Serviços';Risk='MÉDIO';Default=$true;Preset='Services';Target='AllowTelemetry=0 quando aceito';Desc='A edição do Windows pode limitar o efeito da política.'},
            [pscustomobject]@{Id='DiagTrack';Name='DiagTrack OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Default=$true;Preset='Services';Target='DiagTrack=Disabled';Desc='Desativa Connected User Experiences and Telemetry.'},
            [pscustomobject]@{Id='WerSvc';Name='Windows Error Reporting OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Default=$true;Preset='Services';Target='WerSvc=Disabled';Desc='Reduz relatórios de erro em background.'},
            [pscustomobject]@{Id='TelemetryTasks';Name='Tarefas de telemetria OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Default=$true;Preset='Services';Target='Lista curada de tarefas Disabled';Desc='Somente tarefas explicitamente conhecidas pelo Config.json.'},
            [pscustomobject]@{Id='Indexing';Name='Windows Search Indexing OFF';Group='Telemetria / Serviços';Risk='MÉDIO';Default=$false;Preset='Services';Target='WSearch=Disabled';Desc='Pode tornar pesquisas de arquivos menos imediatas.'},
            [pscustomobject]@{Id='SysMainOff';Name='SysMain OFF';Group='Telemetria / Serviços';Risk='EXPERIMENTAL';Default=$false;Preset='Experimental';Target='SysMain=Disabled';Desc='NÃO altera Prefetch. Use apenas se quiser testar no SSD.'},

            [pscustomobject]@{Id='MemoryCompressionOff';Name='Memory Compression OFF';Group='Experimental';Risk='EXPERIMENTAL';Default=$false;Preset='Experimental';Target='Disable-MMAgent -MemoryCompression';Desc='Pode aumentar pressão de memória; não recomendado como padrão.'},
            [pscustomobject]@{Id='HAGSOn';Name='HAGS ON (teste A/B)';Group='Experimental';Risk='EXPERIMENTAL';Default=$false;Preset='Experimental';Target='HwSchMode=2';Desc='Depende da GPU/driver e requer reinício; compare antes/depois.'},
            [pscustomobject]@{Id='MPOOff';Name='MPO OFF (troubleshooting)';Group='Experimental';Risk='EXPERIMENTAL';Default=$false;Preset='Experimental';Target='OverlayTestMode=5';Desc='Somente para flicker/stutter relacionado a compositor/driver.'}
        )

        $intro=New-Card;$is=New-Object System.Windows.Controls.StackPanel
        $is.Children.Add((New-Text -Text 'LABORATÓRIO DE OTIMIZAÇÃO REVERSÍVEL' -Size 16 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,0,0,5))))|Out-Null
        $is.Children.Add((New-Text -Text 'Marque o que quiser. Antes de aplicar, o programa salva somente o estado que aquela seleção pode alterar. Risco MÉDIO aparece em amarelo; EXPERIMENTAL em vermelho e nunca entra nos presets recomendados.' -Size 12 -Color $B.Muted))|Out-Null
        $intro.Child=$is;$PageHost.Children.Add($intro)|Out-Null

        $checks=@{};$stateRuns=@{};$order=@();$groups=@('Gaming','Energia','Interface','Background / Privacidade','Telemetria / Serviços','Experimental')
        foreach($g in $groups){
            $card=New-Card;$st=New-Object System.Windows.Controls.StackPanel
            $st.Children.Add((New-Text -Text $g.ToUpperInvariant() -Size 15 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,0,0,9))))|Out-Null
            foreach($d in @($defs|Where-Object {$_.Group -eq $g})){
                # RC12 UI audit: o próprio CheckBox carrega o rótulo. Isso evita a regressão
                # observada no Windows PowerShell 5.1, onde o checkbox aparecia mas o StackPanel
                # de texto separado podia virar uma grande área vazia.
                $cb=New-Object System.Windows.Controls.CheckBox
                # O rótulo continua DENTRO do CheckBox (correção RC12), mas o nível de risco
                # ganha destaque visual sem pintar o nome inteiro da otimização.
                $labelHost=New-Object System.Windows.Controls.TextBlock
                $nameRun=New-Object System.Windows.Documents.Run
                $nameRun.Text=[string]$d.Name
                $nameRun.Foreground=$B.Text
                [void]$labelHost.Inlines.Add($nameRun)
                if([string]$d.Risk -ne 'BAIXO'){
                    $riskRun=New-Object System.Windows.Documents.Run
                    $riskRun.Text=(' [{0}]' -f [string]$d.Risk)
                    $riskRun.FontWeight='Bold'
                    if([string]$d.Risk -eq 'MÉDIO'){$riskRun.Foreground=$B.Yellow}else{$riskRun.Foreground=$B.Red}
                    [void]$labelHost.Inlines.Add($riskRun)
                }
                $cb.Content=$labelHost
                $cb.ToolTip=("Descrição: {0}`r`nAlvo: {1}`r`nRisco: {2}" -f [string]$d.Desc,[string]$d.Target,[string]$d.Risk)
                $cb.IsChecked=[bool]$d.Default
                $cb.Foreground=$B.Text
                $cb.FontSize=12
                $cb.FontWeight='SemiBold'
                $cb.VerticalAlignment='Center'
                $cb.Margin=[Windows.Thickness]::new(2,3,2,5)
                $cb.Padding=[Windows.Thickness]::new(2)
                $cb.Add_Click({Update-StudioSelectionSummaryUi})
                $st.Children.Add($cb)|Out-Null
                $checks[[string]$d.Id]=$cb;$stateRuns[[string]$d.Id]=$stateRun;$order += [string]$d.Id
            }
            $card.Child=$st;$PageHost.Children.Add($card)|Out-Null
        }
        $summary=New-Text -Text '' -Size 11 -Color $B.Text -Bold -Margin ([Windows.Thickness]::new(4,8,0,8));$PageHost.Children.Add($summary)|Out-Null
        $script:StudioUiState=[pscustomobject]@{Checks=$checks;StateRuns=$stateRuns;Order=[string[]]$order;Defs=$defs;Summary=$summary};Update-StudioSelectionSummaryUi

        $presets=New-GridActionCard -Title 'Presets de seleção' -Subtitle 'Os presets são cumulativos: você pode combinar Gaming + Interface + Privacidade, por exemplo. Nada é aplicado até clicar em APLICAR SELECIONADOS. Use Limpar seleção para começar do zero.' -Columns 3
        foreach($spec in @(@('RECOMENDADOS','Recommended'),@('Gaming','Gaming'),@('Performance','Performance'),@('Privacidade','Privacy'),@('Interface','Interface'),@('Serviços','Services'))){
            $btn=New-Button -Text ([string]$spec[0]) -Accent $B.Cyan -Width 0
            $btn.Tag=[string]$spec[1]
            $btn.Add_Click({param($sender,$e);Add-StudioPresetSelectionUi -Preset ([string]$sender.Tag)})
            Add-GridButton -Grid $presets.Grid -Button $btn
        }
        $safe=New-Button -Text 'Todos não-experimentais' -Accent $B.Cyan -Width 0;$safe.Add_Click({foreach($d in @($script:StudioUiState.Defs)){$script:StudioUiState.Checks[[string]$d.Id].IsChecked=([string]$d.Risk -ne 'EXPERIMENTAL')};Update-StudioSelectionSummaryUi});Add-GridButton -Grid $presets.Grid -Button $safe
        $none=New-Button -Text 'Limpar seleção' -Accent $B.Cyan -Width 0;$none.Add_Click({foreach($id in @($script:StudioUiState.Order)){$script:StudioUiState.Checks[$id].IsChecked=$false};Update-StudioSelectionSummaryUi});Add-GridButton -Grid $presets.Grid -Button $none
        $last=New-Button -Text 'Selecionar última sessão' -Accent $B.Cyan -Width 0;$last.Add_Click({Select-LastStudioSessionUi});Add-GridButton -Grid $presets.Grid -Button $last
        $PageHost.Children.Add($presets.Card)|Out-Null
        $manageXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Configuração / Perfis personalizados" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Exporte a seleção para JSON, importe depois ou salve combinações recorrentes no State desta máquina." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="StudioExportButton" Grid.Row="0" Grid.Column="0" Content="Exportar seleção JSON" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StudioImportButton" Grid.Row="0" Grid.Column="1" Content="Importar seleção JSON" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StudioStatesButton" Grid.Row="0" Grid.Column="2" Content="Atualizar estados dos módulos" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StudioSaveCustomButton" Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="1" Content="Salvar perfil personalizado" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="StudioLoadCustomButton" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Content="Carregar perfil personalizado" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $manageCard=New-UiFragment -Xaml $manageXaml
        $manageCard.FindName('StudioExportButton').Add_Click({Export-StudioSelectionUi})
        $manageCard.FindName('StudioImportButton').Add_Click({Import-StudioSelectionUi})
        $manageCard.FindName('StudioSaveCustomButton').Add_Click({Save-CustomProfileUi})
        $manageCard.FindName('StudioLoadCustomButton').Add_Click({Load-CustomProfileUi})
        $manageCard.FindName('StudioStatesButton').Add_Click({Update-StudioModuleStatesUi})
        $PageHost.Children.Add($manageCard)|Out-Null

        # Os dois cards abaixo ficam em XAML estático. No Windows real, controles montados
        # dinamicamente nestes pontos chegaram a manter apenas o quadrado do CheckBox.
        $applyXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Aplicar / inspecionar" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="A prévia mostra cada alteração. O snapshot da sessão é escopado exatamente aos módulos marcados." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="LabApplyButton" Grid.Row="0" Grid.Column="0" Content="APLICAR SELECIONADOS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="LabPreviewButton" Grid.Row="0" Grid.Column="1" Content="PRÉVIA DOS SELECIONADOS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="LabStatusButton" Grid.Row="0" Grid.Column="2" Content="Ver estado atual" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="LabCatalogButton" Grid.Row="1" Grid.Column="0" Content="Ver catálogo completo" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
    <CheckBox x:Name="LabRestorePointCheck" Content="Criar ponto de restauração antes de aplicar" IsChecked="True" Foreground="#94A3B8" FontSize="12" Margin="6,10,6,2" VerticalContentAlignment="Center"/>
  </StackPanel>
</Border>
"@
        $applyCard=New-UiFragment -Xaml $applyXaml
        $apply=$applyCard.FindName('LabApplyButton')
        $preview=$applyCard.FindName('LabPreviewButton')
        $status=$applyCard.FindName('LabStatusButton')
        $details=$applyCard.FindName('LabCatalogButton')
        $restoreCheck=$applyCard.FindName('LabRestorePointCheck')
        $script:StudioUiState|Add-Member -NotePropertyName RestorePointCheck -NotePropertyValue $restoreCheck
        $PageHost.Children.Add($applyCard)|Out-Null

        $rollbackXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Desfazer / restaurar" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="DESFAZER volta exatamente ao estado anterior à última aplicação. RESTAURAR SELECIONADOS usa o primeiro backup original conhecido de cada módulo." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="LabUndoButton" Grid.Column="0" Content="DESFAZER ÚLTIMA APLICAÇÃO" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="LabRestoreSelectedButton" Grid.Column="1" Content="RESTAURAR SELECIONADOS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="LabRestoreAllButton" Grid.Column="2" Content="RESTAURAR TODOS AO ORIGINAL" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FB7185" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $rollbackCard=New-UiFragment -Xaml $rollbackXaml
        $undo=$rollbackCard.FindName('LabUndoButton')
        $restoreSelected=$rollbackCard.FindName('LabRestoreSelectedButton')
        $restoreAll=$rollbackCard.FindName('LabRestoreAllButton')
        $PageHost.Children.Add($rollbackCard)|Out-Null
        $undo.Add_Click({Show-Operation -Action 'WindowsStudioUndo' -Data ([pscustomobject]@{}) -Title 'DESFAZER ÚLTIMA APLICAÇÃO' -Description '' -ConfirmText 'Desfazer exatamente a última aplicação do Optimization Lab?' -Danger $true})
        $restoreAll.Add_Click({Show-Operation -Action 'WindowsStudioRestoreOriginal' -Data ([pscustomobject]@{}) -Title 'RESTAURAR TODOS AO ORIGINAL' -Description '' -ConfirmText 'Restaurar todos os módulos conhecidos para seus backups originais?' -Danger $true})

        $preview.Add_Click({$mods=@(Get-StudioSelectedModulesUi);if($mods.Count -eq 0){Show-Info -Title 'Optimization Lab' -Text 'Marque pelo menos uma opção.'}else{Show-WindowsStudioChangesUi -Modules ([string[]]$mods)}})
        $details.Add_Click({Show-WindowsStudioChangesUi -Modules ([string[]]@($script:StudioUiState.Order))});$status.Add_Click({Show-WindowsStudioStatusUi})
        $apply.Add_Click({$mods=@(Get-StudioSelectedModulesUi);if($mods.Count -eq 0){Show-Info -Title 'Optimization Lab' -Text 'Marque pelo menos uma opção para aplicar.';return};$experimental=@($script:StudioUiState.Defs|Where-Object {$mods -contains [string]$_.Id -and [string]$_.Risk -eq 'EXPERIMENTAL'});$extra=if($experimental.Count -gt 0){"`r`n`r`nATENÇÃO: a seleção inclui EXPERIMENTAIS: "+(($experimental|ForEach-Object {$_.Name}) -join ', ')}else{''};Show-Operation -Action 'WindowsStudioApplySelection' -Data ([pscustomobject]@{Modules=[string[]]$mods;AutoRestorePoint=[bool]$script:StudioUiState.RestorePointCheck.IsChecked}) -Title 'Aplicar Optimization Lab' -Description ('Selecionados: '+($mods -join ', ')) -ConfirmText ("Aplicar {0} otimização(ões)?{1}" -f $mods.Count,$extra) -Danger $true})
        $restoreSelected.Add_Click({$mods=@(Get-StudioSelectedModulesUi);if($mods.Count -eq 0){Show-Info -Title 'Optimization Lab' -Text 'Marque pelo menos uma opção para restaurar.';return};if(-not(Confirm-SO -Text ("Restaurar estes módulos aos backups originais conhecidos?`r`n`r`n"+($mods -join ', ')) -Danger $true)){return};Show-Operation -Action 'WindowsStudioRestoreSelection' -Data ([pscustomobject]@{Modules=[string[]]$mods}) -Title 'Restaurar selecionados' -Description ('Selecionados: '+($mods -join ', '))})
    }catch{Show-UiError -ErrorRecord $_ -Context 'Optimization Lab'}
}

function Show-Services {
    try {
        $script:CurrentPage='Services'
        Clear-Page
        Add-PageHeader -Title 'Serviços' -Subtitle 'Perfil curado para o uso gamer conhecido. Não é aplicado no Perfil Universal. Serviços em modo Manual não são parados à força.'

        $cfg=Get-Content -LiteralPath (Join-Path $AppRoot 'Config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $xaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Serviços do perfil" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="A lista abaixo é a seleção curada do Super Optimizer. Recursos essenciais usados pelo sistema permanecem fora do alvo." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <DataGrid x:Name="ServicesGrid" Height="360" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column"
              Background="#111B31" Foreground="#F1F5F9" RowBackground="#16233E" AlternatingRowBackground="#1A2A49" BorderBrush="#243B63" BorderThickness="1"
              GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#243B63">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Serviço" Binding="{Binding name}" Width="170"/>
        <DataGridTextColumn Header="Alvo" Binding="{Binding mode}" Width="110"/>
        <DataGridTextColumn Header="Descrição" Binding="{Binding label}" Width="*"/>
        <DataGridTextColumn Header="Risco" Binding="{Binding risk}" Width="90"/>
      </DataGrid.Columns>
    </DataGrid>
    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="Ações dos serviços" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Aplicar usa somente a lista curada acima. Restaurar retorna cada serviço ao estado salvo antes da primeira alteração." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="ServicesRestoreButton" Grid.Column="0" Content="Restaurar serviços" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="ServicesApplyButton" Grid.Column="1" Content="Aplicar perfil de serviços" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FB7185" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $card=New-UiFragment -Xaml $xaml
        $grid=$card.FindName('ServicesGrid')
        $grid.ItemsSource=@($cfg.services)
        try{$grid.ColumnHeaderStyle=$Window.FindResource('DarkDataGridHeaderStyle')}catch{}
        try{$grid.CellStyle=$Window.FindResource('DarkDataGridCellStyle')}catch{}
        try{$grid.RowStyle=$Window.FindResource('DarkDataGridRowStyle')}catch{}
        $PageHost.Children.Add($card)|Out-Null
        $card.FindName('ServicesRestoreButton').Add_Click({Show-Operation -Action 'ServicesRestore' -Data ([pscustomobject]@{}) -Title 'Restaurar serviços' -Description '' -ConfirmText 'Restaurar os estados salvos dos serviços?' -Danger $true})
        $card.FindName('ServicesApplyButton').Add_Click({Show-Operation -Action 'ServicesApply' -Data ([pscustomobject]@{}) -Title 'Aplicar perfil de serviços' -Description 'O estado original de cada serviço é salvo por máquina.' -ConfirmText 'Aplicar o perfil curado de serviços? Pode afetar recursos que você usa.' -Danger $true})
    }catch{Show-UiError -ErrorRecord $_ -Context 'Serviços'}
}

function Show-GpuNet {
    try {
        $script:CurrentPage='GpuNet';Clear-Page
        Add-PageHeader -Title 'GPU / Windows Update' -Subtitle 'GPU e Windows Update ficam isolados nesta área. DNS, rollback de DNS e benchmark via DNS Jumper ficam na aba DNS / Rede.'

        $card=New-GridActionCard -Title 'GPU / Update' -Subtitle 'HAGS e MPO variam conforme GPU e driver. Use como teste A/B e restaure se piorar.' -Columns 3
        $open=New-Button -Text 'Abrir Windows Update' -Accent $B.Cyan -Width 0
        $open.Add_Click({try{Start-Process -FilePath 'ms-settings:windowsupdate'}catch{Show-UiError -ErrorRecord $_ -Context 'Windows Update'}})
        foreach($b in @(
            (New-ActionButton -Text 'Reativar Update' -Action 'UpdateStart' -Accent $B.Green),
            (New-ActionButton -Text 'HAGS ON' -Action 'HAGSOn' -Accent $B.Cyan -Confirm 'Solicitar Hardware-Accelerated GPU Scheduling ON? Reinicie e teste.'),
            (New-ActionButton -Text 'HAGS OFF' -Action 'HAGSOff' -Accent $B.Cyan -Confirm 'Solicitar HAGS OFF? Reinicie e teste.'),
            $open,
            (New-ActionButton -Text 'MPO OFF (Teste)' -Action 'MPOOff' -Accent $B.Yellow -Confirm 'MPO OFF é experimental e serve para troubleshooting de flicker/stutter. Aplicar?' -Danger $true),
            (New-ActionButton -Text 'Restaurar GPU' -Action 'GPURestore' -Accent $B.Yellow -Confirm 'Restaurar os valores de GPU salvos?' -Danger $true),
            (New-ActionButton -Text 'Parar Update (agora)' -Action 'UpdateStop' -Accent $B.Red -Confirm 'Parar Windows Update/BITS/DoSvc agora? O Windows pode reativar serviços por Trigger Start. Não faça durante downloads.' -Danger $true)
        )){Add-GridButton -Grid $card.Grid -Button $b}
        $PageHost.Children.Add($card.Card)|Out-Null
    }catch{Show-UiError -ErrorRecord $_ -Context 'GPU / Windows Update'}
}

function Show-Virtualization {
    try {
        $script:CurrentPage='Virtualization';Clear-Page
        Add-PageHeader -Title 'VBS / Virtualização' -Subtitle 'AMD-V/SVM da BIOS não é desativado. O Extremo altera somente a camada de virtualização e segurança do Windows.'
        $xaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Virtualização do Windows" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Desativar o hypervisor do Windows pode afetar WSL2, Docker baseado em Hyper-V, Hyper-V e Windows Sandbox." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="VirtRestore" Grid.Column="0" Content="Restaurar VBS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="VirtOff" Grid.Column="1" Content="VBS/HVCI/Hypervisor OFF" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FB7185" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="VirtualBox e segurança" FontSize="15" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,5"/>
    <TextBlock Text="VirtualBox pode usar AMD-V/SVM diretamente quando o hypervisor do Windows está desligado. Esta opção reduz uma camada de segurança; use somente quando você entende essa troca." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap"/>
  </StackPanel>
</Border>
"@
        $card=New-UiFragment -Xaml $xaml
        $PageHost.Children.Add($card)|Out-Null
        $card.FindName('VirtRestore').Add_Click({Show-Operation -Action 'VBSRestore' -Data ([pscustomobject]@{}) -Title 'Restaurar VBS' -Description '' -ConfirmText 'Restaurar os estados de VBS/Hypervisor salvos?' -Danger $true})
        $card.FindName('VirtOff').Add_Click({Show-Operation -Action 'VBSOff' -Data ([pscustomobject]@{}) -Title 'VBS/HVCI/Hypervisor OFF' -Description '' -ConfirmText 'Desativar VBS, Integridade de Memória e hypervisor do Windows?' -Danger $true})
    }catch{Show-UiError -ErrorRecord $_ -Context 'Virtualização'}
}

function Show-Rollback {
    try {
        $script:CurrentPage='Rollback';Clear-Page
        Add-PageHeader -Title 'Rollback' -Subtitle 'Backups são separados por MachineGuid. Copiar a pasta para outro PC não mistura o estado salvo entre máquinas.'
        $xaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Restaurar configurações" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="O rollback usa o estado capturado antes da primeira alteração de cada item." FontSize="12" Foreground="#94A3B8" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="RbGaming" Grid.Row="0" Grid.Column="0" Content="Gaming" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbBackground" Grid.Row="0" Grid.Column="1" Content="Background" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbPower" Grid.Row="0" Grid.Column="2" Content="Energia" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbServices" Grid.Row="1" Grid.Column="0" Content="Serviços" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbVbs" Grid.Row="1" Grid.Column="1" Content="VBS" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbGpu" Grid.Row="1" Grid.Column="2" Content="GPU" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbGames" Grid.Row="2" Grid.Column="0" Content="Prioridades de jogos" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="RbAll" Grid.Row="2" Grid.Column="1" Content="RESTAURAR TUDO" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FB7185" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="Backups e estado salvo" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,5"/>
    <TextBlock Text="A pasta State guarda os backups e informações usados pelo rollback deste computador. Normalmente você não precisa editar nada manualmente." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Button x:Name="RbOpenState" Content="Abrir pasta de backups (State)" Height="44" Width="300" HorizontalAlignment="Left" Margin="6,0,6,2" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
  </StackPanel>
</Border>
"@
        $card=New-UiFragment -Xaml $xaml
        $PageHost.Children.Add($card)|Out-Null
        $map=@(
            @('RbGaming','GamingRestore','Gaming','Restaurar Gaming?'),
            @('RbBackground','PrivacyRestore','Background','Restaurar background/telemetria?'),
            @('RbPower','PowerRestore','Energia','Restaurar energia?'),
            @('RbServices','ServicesRestore','Serviços','Restaurar serviços?'),
            @('RbVbs','VBSRestore','VBS','Restaurar VBS/Hypervisor?'),
            @('RbGpu','GPURestore','GPU','Restaurar GPU?'),
            @('RbGames','PerGameRestore','Prioridades de jogos','Restaurar prioridades por jogo?')
        )
        foreach($m in $map){
            $b=$card.FindName([string]$m[0]);$b.Tag=[pscustomobject]@{Action=$m[1];Title=$m[2];Confirm=$m[3]}
            $b.Add_Click({param($sender,$e);$t=$sender.Tag;Show-Operation -Action ([string]$t.Action) -Data ([pscustomobject]@{}) -Title ([string]$t.Title) -Description '' -ConfirmText ([string]$t.Confirm) -Danger $true})
        }
        $card.FindName('RbAll').Add_Click({Show-Operation -Action 'RestoreAll' -Data ([pscustomobject]@{}) -Title 'RESTAURAR TUDO' -Description 'Registro, serviços, tarefas, energia, Defender, GPU e hypervisor.' -ConfirmText 'Restaurar todos os estados salvos para ESTE computador?' -Danger $true})
        $card.FindName('RbOpenState').Add_Click({try{Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $State)}catch{Show-UiError -ErrorRecord $_ -Context 'Pasta State'}})
    }catch{Show-UiError -ErrorRecord $_ -Context 'Rollback'}
}

function Show-SelfTestDialog {
    $script:LastOperationResult = $null
    try {
        if(Test-ActiveOperation){
            Show-Info -Title 'Auto-teste' -Text ('Aguarde a operação ativa terminar antes do Auto-Teste: '+[string]$script:ActiveOperationAction)
            return
        }
        $id = [guid]::NewGuid().ToString('N')
        $output = Join-Path $Runtime ($id + '.selftest.txt')
        $stdout = Join-Path $Runtime ($id + '.selftest.stdout.txt')
        $stderr = Join-Path $Runtime ($id + '.selftest.stderr.txt')
        $exe = Join-Path $PSHOME 'powershell.exe'
        $args = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "{0}" -OutputFile "{1}"' -f $SelfTest,$output
        $proc = Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $script:ActiveOperationProcess=$proc
        $script:ActiveOperationAction='AutoTest'
        $script:ActiveOperationFiles=$null
        $script:ActiveOperationStarted=Get-Date

        $dlg = New-Object System.Windows.Window
        $dlg.Title = 'Auto-teste'
        $dlg.Width = 900
        $dlg.Height = 650
        $dlg.Owner = $Window
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
        $dlg.Background = $B.Bg

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = [Windows.Thickness]::new(20)
        $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [Windows.GridLength]::Auto
        $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
        $r3 = New-Object System.Windows.Controls.RowDefinition; $r3.Height = [Windows.GridLength]::Auto
        [void]$grid.RowDefinitions.Add($r1);[void]$grid.RowDefinitions.Add($r2);[void]$grid.RowDefinitions.Add($r3)

        $status = New-Text -Text 'Executando parser, validações e dry-run...' -Size 13 -Color $B.Yellow -Margin ([Windows.Thickness]::new(0,0,0,12))
        [Windows.Controls.Grid]::SetRow($status,0);$grid.Children.Add($status)|Out-Null

        $box = New-Object System.Windows.Controls.TextBox
        $box.IsReadOnly=$true;$box.AcceptsReturn=$true;$box.VerticalScrollBarVisibility='Auto';$box.HorizontalScrollBarVisibility='Auto'
        $box.Background=$B.Panel;$box.Foreground=$B.Text;$box.FontFamily=New-Object System.Windows.Media.FontFamily('Consolas');$box.FontSize=12;$box.Padding=[Windows.Thickness]::new(10)
        [Windows.Controls.Grid]::SetRow($box,1);$grid.Children.Add($box)|Out-Null

        $close=New-Button -Text 'Fechar' -Accent $B.Red -Width 150
        $close.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right
        [Windows.Controls.Grid]::SetRow($close,2);$grid.Children.Add($close)|Out-Null
        $close.Tag=[pscustomobject]@{Window=$dlg;Process=$proc}
        $close.Add_Click({
            param($sender,$eventArgs)
            try{
                if(-not $sender.Tag.Process.HasExited){
                    $answer=[System.Windows.MessageBox]::Show(
                        'O Auto-Teste ainda está executando. Fechar a janela não encerra o processo de teste. Deseja ocultar mesmo assim?',
                        'Auto-Teste em andamento',
                        [System.Windows.MessageBoxButton]::YesNo,
                        [System.Windows.MessageBoxImage]::Warning
                    )
                    if($answer -ne [System.Windows.MessageBoxResult]::Yes){return}
                }
                $sender.Tag.Window.Close()
            }catch{}
        })

        $dlg.Content=$grid
        $timer=New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval=[TimeSpan]::FromMilliseconds(400)
        $timer.Tag=[pscustomobject]@{Output=$output;StdOut=$stdout;StdErr=$stderr;Box=$box;Process=$proc;Status=$status;Started=(Get-Date);Finished=$false}
        $tick={
            param($sender,$eventArgs)
            $ctx=$sender.Tag

            try{
                if(Test-Path -LiteralPath $ctx.Output){
                    $txt=Get-Content -LiteralPath $ctx.Output -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if($txt -and $txt -ne $ctx.Box.Text){$ctx.Box.Text=$txt;$ctx.Box.ScrollToEnd()}
                }
            }catch{}

            # Auto-teste não deve ficar eternamente preso. 180 s é muito acima do normal.
            if(-not $ctx.Process.HasExited -and ((Get-Date)-$ctx.Started).TotalSeconds -gt 180){
                try{$ctx.Process.Kill()}catch{}
                $ctx.Status.Text='AUTO-TESTE excedeu 180 segundos e foi interrompido.'
                $ctx.Status.Foreground=$B.Red
                if(-not $ctx.Box.Text){$ctx.Box.Text='Timeout do processo de Auto-Teste. Consulte State\\Runtime e Logs.'}
                $sender.Stop()
                return
            }

            if($ctx.Process.HasExited -and -not $ctx.Finished){
                $ctx.Finished=$true

                # Se o script falhou antes de criar o relatório, mostre stderr/stdout em vez de tela vazia.
                if(-not $ctx.Box.Text){
                    $fallback=''
                    try{if(Test-Path $ctx.StdErr){$fallback += (Get-Content $ctx.StdErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)}}catch{}
                    try{if(Test-Path $ctx.StdOut){$fallback += (Get-Content $ctx.StdOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)}}catch{}
                    if([string]::IsNullOrWhiteSpace($fallback)){$fallback='O processo terminou sem gerar saída. Consulte State\\Runtime.'}
                    $ctx.Box.Text=$fallback
                    $ctx.Box.ScrollToEnd()
                }

                $exitCode=$null
                try{$ctx.Process.WaitForExit();$ctx.Process.Refresh();$exitCode=[int]$ctx.Process.ExitCode}catch{}
                $report=''
                try{if(Test-Path -LiteralPath $ctx.Output){$report=[string](Get-Content -LiteralPath $ctx.Output -Raw -Encoding UTF8 -ErrorAction Stop)}}catch{}
                $outcome=Get-SelfTestOutcome -Report $report -ExitCode $exitCode
                $ctx.Status.Text=$outcome.Message
                $ctx.Status.Foreground=switch($outcome.State){'Passed'{$B.Green};'Failed'{$B.Red};default{$B.Yellow}}
                Sync-ActiveOperationState
                $sender.Stop()
            }
        }
        $timer.Add_Tick($tick);$timer.Start()
        [void]$dlg.ShowDialog()
        # O Tick continua monitorando o processo oculto até concluir ou atingir 180 s.
    } catch {
        Show-UiError -ErrorRecord $_ -Context 'Auto-teste'
    }
}

function Get-UiDiagnosticErrorSummary {
    $parts=@()
    foreach($spec in @(
        [pscustomobject]@{Name='Inicialização';Path=(Join-Path $Logs 'startup_last_error.txt')},
        [pscustomobject]@{Name='Interface';Path=(Join-Path $Logs 'ui_last_error.txt')}
    )){
        try{
            if(Test-Path -LiteralPath $spec.Path -PathType Leaf){
                $fi=Get-Item -LiteralPath $spec.Path -ErrorAction Stop
                $txt=Get-Content -LiteralPath $spec.Path -Raw -Encoding UTF8 -ErrorAction Stop
                if(-not [string]::IsNullOrWhiteSpace($txt)){
                    $short=$txt.Trim();if($short.Length -gt 420){$short=$short.Substring(0,420)+'...'}
                    $parts += ('{0} ({1}): {2}' -f $spec.Name,$fi.LastWriteTime.ToString('dd/MM HH:mm'),$short)
                }
            }
        }catch{}
    }
    if($parts.Count -eq 0){return 'Nenhum erro persistente de inicialização/interface registrado.'}
    return ($parts -join "`r`n`r`n")
}

function Show-Diagnostics {
    try{
        $script:CurrentPage='Diagnostics';Clear-Page
        Add-PageHeader -Title 'Diagnóstico / Auto-teste' -Subtitle 'Resumo do PC, erros recentes, State, relatório completo e Auto-Teste ficam concentrados aqui.'

        $summary=New-Card;$sumStack=New-Object System.Windows.Controls.StackPanel
        $sumStack.Children.Add((New-Text -Text 'RESUMO ATUAL DO PC' -Size 16 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,0,0,8))))|Out-Null
        if($script:LastStatus){
            $s=$script:LastStatus
            $txt=@(
                ('Windows: {0}' -f $s.Windows),('CPU: {0}' -f $s.CPU),
                ('RAM: {0} GB total • {1} GB livre • {2}% em uso' -f $s.RAMTotalGB,$s.RAMFreeGB,$s.RAMUsedPercent),
                ('Disco: {0} GB livre de {1} GB • {2}% livre' -f $s.DiskFreeGB,$s.DiskTotalGB,$s.DiskFreePercent),
                ('Perfil: {0} • VBS/HVCI: {1} • Serviços: {2}' -f $s.Profile,$s.VBS,$s.Services),
                ('Plano: {0} • WinGet: {1} • Reinício pendente: {2}' -f $s.PowerPlanName,$(if([bool]$s.WingetAvailable){'SIM'}else{'NÃO'}),$(if([bool]$s.RebootPending){'SIM'}else{'NÃO'}))
            ) -join "`r`n"
            $sumStack.Children.Add((New-Text -Text $txt -Size 12 -Color $B.Text))|Out-Null
        }else{
            $fallback=@(('Administrador: SIM'),('PowerShell: {0}' -f $PSVersionTable.PSVersion),('Computador: {0}' -f $env:COMPUTERNAME),('State: {0}' -f $State),'','Status detalhado ainda está sendo lido em segundo plano. Use CARREGAR DIAGNÓSTICO para consultar imediatamente.') -join "`r`n"
            $sumStack.Children.Add((New-Text -Text $fallback -Size 12 -Color $B.Yellow))|Out-Null;$script:StatusRefreshRequested=$true
        }
        $sumStack.Children.Add((New-Text -Text 'ERROS RECENTES REGISTRADOS' -Size 15 -Color $B.Cyan -Bold -Margin ([Windows.Thickness]::new(0,16,0,7))))|Out-Null
        $sumStack.Children.Add((New-Text -Text (Get-UiDiagnosticErrorSummary) -Size 11 -Color $B.Muted))|Out-Null
        $summary.Child=$sumStack;$PageHost.Children.Add($summary)|Out-Null

        $xaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Leitura e testes" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="CARREGAR DIAGNÓSTICO é somente leitura. AUTO-TESTE valida parser, rotas, Worker/IPC e arquitetura em DRY-RUN." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="DiagQuick" Grid.Row="0" Grid.Column="0" Content="CARREGAR DIAGNÓSTICO" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagSelfTest" Grid.Row="0" Grid.Column="1" Content="Executar AUTO-TESTE" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagRefresh" Grid.Row="1" Grid.Column="0" Content="Atualizar status em segundo plano" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagRestorePoint" Grid.Row="1" Grid.Column="1" Content="Criar ponto agora" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
    <Border Height="1" Background="#243B63" Margin="6,14,6,14"/>
    <TextBlock Text="Relatórios e State" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Gere um relatório legível, audite os backups e abra as pastas quando precisar investigar algum problema." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="DiagReport" Grid.Row="0" Grid.Column="0" Content="Gerar + visualizar relatório" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagState" Grid.Row="0" Grid.Column="1" Content="Verificar backups / State" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagReportsOpen" Grid.Row="0" Grid.Column="2" Content="Abrir Relatórios" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagLogsOpen" Grid.Row="1" Grid.Column="0" Content="Abrir Logs" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagReadme" Grid.Row="1" Grid.Column="1" Content="Abrir README" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagLogsCleanup" Grid.Row="1" Grid.Column="2" Content="Limpar logs antigos (30 dias)" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $card=New-UiFragment -Xaml $xaml
        $PageHost.Children.Add($card)|Out-Null
        $extraXaml=@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#16233E" BorderBrush="#243B63" BorderThickness="1" CornerRadius="12" Padding="18" Margin="0,0,0,16">
  <StackPanel>
    <TextBlock Text="Exportação &amp; suporte" FontSize="16" FontWeight="SemiBold" Foreground="#22D3EE" Margin="0,0,0,4"/>
    <TextBlock Text="Gere relatórios portáteis e abra inteligência persistente do State." FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Button x:Name="DiagExportTxtButton" Grid.Row="0" Grid.Column="0" Content="Exportar diagnóstico TXT" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagExportJsonButton" Grid.Row="0" Grid.Column="1" Content="Exportar diagnóstico JSON" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#22D3EE" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagHistoryButton" Grid.Row="1" Grid.Column="0" Content="Histórico de alterações" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#34D399" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
      <Button x:Name="DiagStateManagerButton" Grid.Row="1" Grid.Column="1" Content="Backup / State Manager" Height="44" Margin="6" Foreground="#F1F5F9" Background="#111B31" BorderBrush="#FBBF24" BorderThickness="1.5" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Border>
"@
        $extraCard=New-UiFragment -Xaml $extraXaml
        $extraCard.FindName('DiagExportTxtButton').Add_Click({Show-Operation -Action 'DiagnosticExportTxt' -Data ([pscustomobject]@{}) -Title 'Exportar diagnóstico TXT' -Description 'Gera relatório portátil em texto dentro de State\Reports.'})
        $extraCard.FindName('DiagExportJsonButton').Add_Click({Show-Operation -Action 'DiagnosticExportJson' -Data ([pscustomobject]@{}) -Title 'Exportar diagnóstico JSON' -Description 'Gera relatório estruturado dentro de State\Reports.'})
        $extraCard.FindName('DiagHistoryButton').Add_Click({Show-HistoryUi})
        $extraCard.FindName('DiagStateManagerButton').Add_Click({Show-StateManagerUi})
        $PageHost.Children.Add($extraCard)|Out-Null
        $card.FindName('DiagQuick').Add_Click({Show-DiagnosticQuickUi})
        $card.FindName('DiagSelfTest').Add_Click({Show-SelfTestDialog})
        $card.FindName('DiagRefresh').Add_Click({$script:StatusRefreshRequested=$true;$HeaderStatus.Text='ADMIN • ATUALIZANDO';Show-Info -Title 'Diagnóstico' -Text 'Atualização solicitada. O novo status aparecerá no Dashboard e ao reabrir esta aba.'})
        $card.FindName('DiagRestorePoint').Add_Click({Show-Operation -Action 'CreateRestorePoint' -Data ([pscustomobject]@{}) -Title 'Criar ponto agora' -Description 'Cria um ponto de restauração do Windows, se a Proteção do Sistema estiver habilitada.'})
        $card.FindName('DiagReport').Add_Click({Start-DiagnosticReportUi})
        $card.FindName('DiagState').Add_Click({Show-StateAuditUi})
        $card.FindName('DiagReportsOpen').Add_Click({try{$rp=Get-UiReportsPath;New-Item -ItemType Directory -Force -Path $rp|Out-Null;Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $rp)}catch{Show-UiError -ErrorRecord $_ -Context 'Relatórios'}})
        $card.FindName('DiagLogsOpen').Add_Click({try{Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $Logs)}catch{Show-UiError -ErrorRecord $_ -Context 'Logs'}})
        $card.FindName('DiagReadme').Add_Click({try{Start-Process -FilePath (Join-Path $AppRoot 'Docs\README.html')}catch{Show-UiError -ErrorRecord $_ -Context 'README'}})
        $card.FindName('DiagLogsCleanup').Add_Click({Show-Operation -Action 'LogsCleanup' -Data ([pscustomobject]@{}) -Title 'Limpar logs antigos (30 dias)' -Description '' -ConfirmText 'Excluir somente arquivos .log com mais de 30 dias?' -Danger $true})
    }catch{Show-UiError -ErrorRecord $_ -Context 'Diagnóstico'}
}

function Show-Page {
    param([string]$Page)
    try {
        switch ($Page) {
            'Dashboard' { Show-Dashboard }
            'Profiles' { Show-Profiles }
            'Cleanup' { Show-Cleanup }
            'Maintenance' { Show-Maintenance }
            'Gaming' { Show-Gaming }
            'System' { Show-System }
            'DnsLab' { Show-DnsLab }
            'Services' { Show-Services }
            'GpuNet' { Show-GpuNet }
            'Virtualization' { Show-Virtualization }
            'Rollback' { Show-Rollback }
            'Diagnostics' { Show-Diagnostics }
            default { Show-Dashboard }
        }
    } catch {
        Show-UiError -ErrorRecord $_ -Context ('Navegação ' + $Page)
    }
}

# Navigation. Grid columns in XAML ensure content can never sit under the sidebar.
$nav = @(
    @('Dashboard','Dashboard'),
    @('Perfis','Profiles'),
    @('Limpeza / Armazenamento','Cleanup'),
    @('Manutenção','Maintenance'),
    @('Otimizar Windows','System'),
    @('DNS / Rede','DnsLab'),
    @('Gaming','Gaming'),
    @('Serviços','Services'),
    @('GPU / Update','GpuNet'),
    @('Virtualização','Virtualization'),
    @('Rollback','Rollback'),
    @('Diagnóstico','Diagnostics')
)

foreach ($item in $nav) {
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $item[0]
    $button.Tag = $item[1]
    $button.Style = $Window.FindResource('NavButtonStyle')
    $button.Add_Click({
        param($sender,$eventArgs)
        Show-Page -Page ([string]$sender.Tag)
    })
    $NavHost.Children.Add($button) | Out-Null
}

$CloseButton.Add_Click({ $Window.Close() })

# Segunda abertura do atalho/BAT apenas traz esta janela para frente.
$ActivationTimer = New-Object System.Windows.Threading.DispatcherTimer
$ActivationTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$ActivationTimer.Add_Tick({
    try{
        if($script:ActivationEvent -and $script:ActivationEvent.WaitOne(0)){
            if($Window.WindowState -eq [System.Windows.WindowState]::Minimized){
                $Window.WindowState=[System.Windows.WindowState]::Normal
            }
            if(-not $Window.IsVisible){$Window.Show()}
            [void]$Window.Activate()
            $Window.Topmost=$true
            $Window.Topmost=$false
            [void]$Window.Focus()
        }
    }catch{}
})

# Status poller with timeout so a broken CIM/WMI query cannot leave "status" spinning forever.
$StatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$StatusTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$StatusTimer.Add_Tick({
    try {
        $hadActive=Test-ActiveOperation
        if($hadActive){$HeaderStatus.Text=('ADMIN • EXECUTANDO '+[string]$script:ActiveOperationAction)}
        if ($script:StatusRefreshRequested -and -not $script:StatusProcess -and -not $hadActive) {
            $script:StatusRefreshRequested = $false
            Start-StatusRefresh
        }
        if ($script:StatusProcess) {
            if ($script:StatusProcess.HasExited) {
                try {
                    if (Test-Path -LiteralPath $script:StatusFiles.Result) {
                        $result = Get-Content -LiteralPath $script:StatusFiles.Result -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($result.Success) {
                            $script:LastStatus = $result.Data
                            $script:LastStatusError = $null
                        } else {
                            $script:LastStatusError = [string]$result.Message
                        }
                    } else {
                        $script:LastStatusError = 'Worker de status terminou sem arquivo de resultado.'
                    }
                } catch {
                    $script:LastStatusError = $_.Exception.Message
                }
                $script:StatusProcess = $null
                $script:StatusStarted = $null
                Update-DashboardStatus
            } elseif ($script:StatusStarted -and ((Get-Date) - $script:StatusStarted).TotalSeconds -gt 20) {
                try { $script:StatusProcess.Kill() } catch {}
                $script:StatusProcess = $null
                $script:StatusStarted = $null
                $script:LastStatusError = 'Timeout de 20 segundos ao consultar o Windows.'
                Update-DashboardStatus
            }
        }
    } catch {
        Write-UiError -ErrorRecord $_ -Context 'StatusTimer'
        $script:StatusProcess = $null
        $script:LastStatusError = $_.Exception.Message
        Update-DashboardStatus
    }
})

$Window.Add_Loaded({
    try {
        Show-Dashboard
        $script:StatusRefreshRequested = $true
        $StatusTimer.Start()
        $ActivationTimer.Start()
    } catch {
        Show-UiError -ErrorRecord $_ -Context 'Loaded'
    }
})

$Window.Add_Closing({
    param($sender,$eventArgs)
    try{
        if(Test-ActiveOperation){
            $answer=[System.Windows.MessageBox]::Show(
                ('A operação "{0}" ainda está em execução. Fechar o Super Optimizer não cancela o processo.`r`n`r`nDeseja fechar mesmo assim?' -f $script:ActiveOperationAction),
                'Operação em andamento',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if($answer -ne [System.Windows.MessageBoxResult]::Yes){$eventArgs.Cancel=$true}
        }
    }catch{}
})

$Window.Add_Closed({
    try { $StatusTimer.Stop() } catch {}
    try { $ActivationTimer.Stop() } catch {}
    try { if($script:ActivationEvent){$script:ActivationEvent.Dispose();$script:ActivationEvent=$null} } catch {}
})

try {
    [void]$Window.ShowDialog()
} catch {
    Show-UiError -ErrorRecord $_ -Context 'MainWindow'
}
