param([switch]$Elevated)
$ErrorActionPreference='Stop'

$AppRoot=$PSScriptRoot
$psExe=Join-Path $PSHOME 'powershell.exe'
if(-not(Test-Path -LiteralPath $psExe)){throw "Windows PowerShell não encontrado em $psExe"}
$State=Join-Path $AppRoot 'State'
$Logs=Join-Path $State 'Logs'
New-Item -ItemType Directory -Force -Path $Logs|Out-Null
$StartupLog=Join-Path $Logs 'startup_last_error.txt'

try{Add-Type -AssemblyName System.Windows.Forms}catch{}

function Show-StartupError([string]$Message){
    try{
        [Windows.Forms.MessageBox]::Show(
            ($Message+"`r`n`r`nLog: "+$StartupLog),
            'Super Optimizer V3.9.0 DEV - Erro ao iniciar',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        )|Out-Null
    }catch{}
}

function Show-StartupInfo([string]$Message){
    try{
        [Windows.Forms.MessageBox]::Show(
            $Message,
            'Super Optimizer V3.9.0 DEV',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        )|Out-Null
    }catch{}
}

function New-StartupSplash {
    try{
        $f=New-Object Windows.Forms.Form;$f.Text='Super Optimizer';$f.Width=480;$f.Height=155;$f.StartPosition='CenterScreen';$f.FormBorderStyle='FixedDialog';$f.MaximizeBox=$false;$f.MinimizeBox=$false;$f.TopMost=$true;$f.BackColor=[Drawing.Color]::FromArgb(15,29,51)
        $title=New-Object Windows.Forms.Label;$title.Text='SUPER OPTIMIZER';$title.ForeColor=[Drawing.Color]::White;$title.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold);$title.AutoSize=$true;$title.Left=20;$title.Top=16;$f.Controls.Add($title)
        $lab=New-Object Windows.Forms.Label;$lab.Text='Iniciando...';$lab.ForeColor=[Drawing.Color]::FromArgb(110,215,255);$lab.Font=New-Object Drawing.Font('Segoe UI',9);$lab.AutoSize=$false;$lab.Width=430;$lab.Height=25;$lab.Left=22;$lab.Top=58;$f.Controls.Add($lab)
        $bar=New-Object Windows.Forms.ProgressBar;$bar.Style='Marquee';$bar.MarqueeAnimationSpeed=25;$bar.Left=22;$bar.Top=89;$bar.Width=425;$bar.Height=14;$f.Controls.Add($bar)
        $f.Tag=$lab;$f.Show();[Windows.Forms.Application]::DoEvents();return $f
    }catch{return $null}
}
function Set-StartupStage([object]$Form,[string]$Text){try{if($Form -and -not $Form.IsDisposed){$Form.Tag.Text=$Text;[Windows.Forms.Application]::DoEvents()}}catch{}}
function Close-StartupSplash([object]$Form){try{if($Form -and -not $Form.IsDisposed){$Form.Close();$Form.Dispose()}}catch{}}

function Test-IsAdmin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if(-not(Test-IsAdmin)){
    try{
        $arg='-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Elevated' -f $PSCommandPath
        Start-Process -FilePath $psExe -ArgumentList $arg -Verb RunAs -WindowStyle Hidden
    }catch{
        $_|Out-String|Set-Content $StartupLog -Encoding UTF8
        Show-StartupError 'Não foi possível solicitar permissão de Administrador.'
    }
    exit
}

# Uma única instância evita duas interfaces alterando Registro/serviços ao mesmo tempo.
# Se o usuário abrir novamente, sinalizamos a janela já existente em vez de mostrar um falso "erro ao iniciar".
$script:InstanceMutex=$null
$script:OwnsMutex=$false
$script:ActivationEvent=$null
$activationEventName='Local\SuperOptimizer_ActivateExisting'
try{
    $created=$false
    $script:InstanceMutex=[System.Threading.Mutex]::new($true,'Local\SuperOptimizer_SingleInstance',[ref]$created)
    $script:OwnsMutex=$created
    if(-not $created){
        $signaled=$false
        try{
            $existingEvent=[System.Threading.EventWaitHandle]::OpenExisting($activationEventName)
            try{$signaled=$existingEvent.Set()}finally{$existingEvent.Dispose()}
        }catch{}
        if(-not $signaled){
            Show-StartupInfo 'O Super Optimizer já está aberto nesta sessão. Use a janela que já está em execução.'
        }
        exit 0
    }

    $eventCreated=$false
    $script:ActivationEvent=[System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        $activationEventName,
        [ref]$eventCreated
    )
}catch{
    $_|Out-String|Set-Content $StartupLog -Encoding UTF8
    Show-StartupError 'Não foi possível criar a trava de instância única.'
    exit 5
}

$startupSplash=New-StartupSplash
$startupStarted=Get-Date
Set-StartupStage $startupSplash 'Validando arquivos essenciais...'

try{
    $required=@(
        'App.ps1',
        'Config.json',
        'UI\MainWindow.xaml',
        'Core\Engine.psm1',
        'Core\Worker.ps1',
        'Core\SelfTest.ps1',
        'Integrity.json'
    )
    foreach($r in $required){
        $p=Join-Path $AppRoot $r
        if(-not(Test-Path -LiteralPath $p)){throw "Arquivo obrigatório ausente: $r"}
    }

    Set-StartupStage $startupSplash 'Conferindo integridade do pacote...'
    # Integridade contra cópia incompleta/corrupção acidental do pacote.
    $manifest=Get-Content -LiteralPath (Join-Path $AppRoot 'Integrity.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    foreach($entry in @($manifest.files)){
        $p=Join-Path $AppRoot ([string]$entry.path)
        if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Arquivo do manifesto ausente: '+[string]$entry.path)}
        $actual=(Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if($actual -ne ([string]$entry.sha256).ToLowerInvariant()){throw ('Falha de integridade em '+[string]$entry.path+'. Extraia o ZIP novamente.')}
    }

    # State precisa ser gravável para backups, rollback, runtime e logs.
    $writeProbe=Join-Path $State ('.launcher_write_'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{'ok'|Set-Content -LiteralPath $writeProbe -Encoding ASCII -ErrorAction Stop;Remove-Item -LiteralPath $writeProbe -Force -ErrorAction Stop}
    catch{throw ('A pasta State não está gravável: '+$_.Exception.Message)}

    Set-StartupStage $startupSplash 'Validando scripts...'
    # Parser oficial do PowerShell para todos os scripts/módulos.
    $parseErrors=@()
    $codeFiles=Get-ChildItem $AppRoot -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1','.psm1') }

    foreach($f in $codeFiles){
        $tok=$null;$err=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$err)
        foreach($e in @($err)){
            $rel=$f.FullName.Substring($AppRoot.Length).TrimStart('\')
            $parseErrors+=('{0} linha {1}, coluna {2}: {3}' -f $rel,$e.Extent.StartLineNumber,$e.Extent.StartColumnNumber,$e.Message)
        }
    }
    if($parseErrors.Count -gt 0){throw ("Falha no parser:`r`n"+($parseErrors -join "`r`n"))}

    Set-StartupStage $startupSplash 'Preparando interface...'
    # Valida JSON e XML antes de carregar a GUI.
    try{[void](Get-Content (Join-Path $AppRoot 'Config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)}
    catch{throw ('Config.json inválido: '+$_.Exception.Message)}

    try{
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName WindowsBase
        [xml]$uiXml=Get-Content (Join-Path $AppRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
        $uiReader=New-Object System.Xml.XmlNodeReader($uiXml)
        try{
            $probe=[Windows.Markup.XamlReader]::Load($uiReader)
            if($probe -is [System.Windows.Window]){$probe.Close()}
        }finally{$uiReader.Close()}
    }catch{throw ('MainWindow.xaml/WPF inválido: '+$_.Exception.Message)}

    # UI callback-scope regression guard.
    $appSource = Get-Content -LiteralPath (Join-Path $AppRoot 'App.ps1') -Raw -Encoding UTF8
    if($appSource.Contains('GetNewClosure')){
        throw 'Preflight UI: App.ps1 contém GetNewClosure. Esta build exige callbacks WPF sem dynamic-module closures.'
    }

    # Abertura rápida: os testes de Engine/Worker/IPC ficam no AUTO-TESTE.
    # Aqui validamos somente arquivos, hashes, parser e XAML — suficiente para não abrir uma build quebrada.
    Set-StartupStage $startupSplash 'Abrindo o Super Optimizer...'

    Remove-Item $StartupLog -Force -ErrorAction SilentlyContinue
    try{('[{0}] Startup pronto em {1:N2}s' -f (Get-Date -Format 'HH:mm:ss'),((Get-Date)-$startupStarted).TotalSeconds)|Add-Content -LiteralPath (Join-Path $Logs 'startup_timing.log') -Encoding UTF8}catch{}
    Close-StartupSplash $startupSplash
    & (Join-Path $AppRoot 'App.ps1') -Elevated
    if($script:ActivationEvent){try{$script:ActivationEvent.Dispose()}catch{};$script:ActivationEvent=$null}
    if($script:OwnsMutex -and $script:InstanceMutex){try{$script:InstanceMutex.ReleaseMutex()}catch{};$script:OwnsMutex=$false}
    if($script:InstanceMutex){$script:InstanceMutex.Dispose();$script:InstanceMutex=$null}
}catch{
    $details=@(
        ('DATA: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('POWERSHELL: {0}' -f $PSVersionTable.PSVersion)
        ''
        ($_|Out-String)
        'STACK:'
        $_.ScriptStackTrace
    ) -join "`r`n"
    Close-StartupSplash $startupSplash
    $details|Set-Content $StartupLog -Encoding UTF8
    Show-StartupError $_.Exception.Message
    if($script:ActivationEvent){try{$script:ActivationEvent.Dispose()}catch{};$script:ActivationEvent=$null}
    if($script:OwnsMutex -and $script:InstanceMutex){try{$script:InstanceMutex.ReleaseMutex()}catch{};$script:OwnsMutex=$false}
    if($script:InstanceMutex){try{$script:InstanceMutex.Dispose()}catch{};$script:InstanceMutex=$null}
    exit 4
}
