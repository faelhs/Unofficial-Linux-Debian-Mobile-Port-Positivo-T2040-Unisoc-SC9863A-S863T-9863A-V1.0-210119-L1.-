# Instalador do Debian 13 + Phosh no Positivo T2040 (Unisoc SC9863A).
# Chamado pelo instalar.cmd. Desbloqueia o bootloader, grava o boot do Linux no slot B
# e envia o sistema pela USB para o modo instalacao do tablet.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Ferr = $PSScriptRoot
$Raiz = Split-Path $Ferr -Parent
$Dados = Join-Path $Raiz 'arquivos'
$Release = 'https://github.com/faelhs/Unofficial-Linux-Debian-Mobile-Port-Positivo-T2040-Unisoc-SC9863A-S863T-9863A-V1.0-210119-L1.-/releases/download/v0.2-experimental'
$UnlockZip = 'https://github.com/patrislav1/unisoc-unlock/archive/a4eaa5e3258c4a15b794b60647ff8c371eac4275.zip'
$PlatformTools = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

$BootImg = 't2040-boot.sparse.img'
$BootSha = '43273cc19ee461c4b5be7ef2d418ed9ea151bc106617a5cb16be2ce25ac48633'
$RootImg = 't2040-debian13-phosh.img.xz'
$RootSha = '9e6d7e1c839a45737eac41ddb604da2abd0daeeb2f10bf151c4bab440cf1b7b1'
$RootRawSha = '0e54311416fb1098dbff4f45c915b9754323af887444e7971c23c0d3087037bf'

$IpTablet = '192.168.42.1'
$PortaImg = 2040
$PortaRes = 2041

function Passo($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Aviso($t) { Write-Host $t -ForegroundColor Yellow }
function Falha($t) { Write-Host ''; Write-Host "ERRO: $t" -ForegroundColor Red; exit 1 }

# Roda um programa e devolve codigo + saida (stdout e stderr juntos), sem o PowerShell 5.1
# transformar o stderr em erro.
function Rodar($exe, [string]$argumentos) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argumentos
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $e = $p.StandardError.ReadToEndAsync()
    $o = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return @{ Codigo = $p.ExitCode; Saida = ($o + $e.Result) }
}

function PortaAberta($porta, $ms = 1500) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($IpTablet, $porta)
        return ($t.Wait($ms) -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

function Baixar($url, $destino) {
    Write-Host "baixando $url"
    & curl.exe -L --fail --retry 3 -o "$destino.parcial" $url
    if ($LASTEXITCODE -ne 0) { Falha "nao consegui baixar $url" }
    Move-Item -Force "$destino.parcial" $destino
}

function Conferir($arq, $sha) {
    Write-Host "conferindo $(Split-Path $arq -Leaf)..."
    $h = (Get-FileHash -Algorithm SHA256 $arq).Hash.ToLower()
    if ($h -ne $sha) { Remove-Item $arq; Falha "$(Split-Path $arq -Leaf) corrompido (SHA-256 $h). Rode de novo para baixar outra vez." }
}

# ------------------------------------------------------------------ preparo
Passo 'Preparando as ferramentas'
New-Item -ItemType Directory -Force $Dados | Out-Null

$Fastboot = Join-Path $Ferr 'platform-tools\fastboot.exe'
$Adb = Join-Path $Ferr 'platform-tools\adb.exe'
if (-not (Test-Path $Fastboot)) {
    $z = Join-Path $Ferr 'platform-tools.zip'
    Baixar $PlatformTools $z
    Expand-Archive -Force $z $Ferr
    Remove-Item $z
}

$Py = $null
foreach ($c in @('py', 'python')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) {
        $r = Rodar $cmd.Source '-c "import sys; print(sys.version_info[0]*100+sys.version_info[1])"'
        if ($r.Codigo -eq 0 -and [int]$r.Saida.Trim() -ge 308) { $Py = $cmd.Source; break }
    }
}
$Venv = Join-Path $Ferr 'venv'
$VenvPy = Join-Path $Venv 'Scripts\python.exe'
if (-not (Test-Path $VenvPy)) {
    if (-not $Py) {
        Falha "Python 3.8 ou mais novo nao encontrado. Instale de https://www.python.org/downloads/windows/ (marque 'Add python.exe to PATH') e rode de novo."
    }
    & $Py -m venv $Venv
    if ($LASTEXITCODE -ne 0) { Falha 'nao consegui criar o ambiente Python' }
}
$r = Rodar $VenvPy '-c "import unisoc_unlock"'
if ($r.Codigo -ne 0) {
    & $VenvPy -m pip install --disable-pip-version-check -q $UnlockZip
    if ($LASTEXITCODE -ne 0) { Falha 'nao consegui instalar o unisoc-unlock' }
}

$Boot = Join-Path $Dados $BootImg
$Root = Join-Path $Dados $RootImg
foreach ($par in @(@($Boot, $BootSha), @($Root, $RootSha))) {
    # Arquivo de outra versao (ex.: v0.1 na pasta arquivos): apaga e baixa o desta versao.
    if ((Test-Path $par[0]) -and ((Get-FileHash -Algorithm SHA256 $par[0]).Hash.ToLower() -ne $par[1])) {
        Aviso "$(Split-Path $par[0] -Leaf) e de outra versao; baixando de novo."
        Remove-Item $par[0]
    }
    if (-not (Test-Path $par[0])) { Baixar "$Release/$(Split-Path $par[0] -Leaf)" $par[0] }
    Conferir $par[0] $par[1]
}

# ------------------------------------------------------------------ confirmacao
Write-Host ''
Aviso 'ATENCAO: isto APAGA TUDO o que esta no tablet (fotos, apps, contas) e instala o Linux.'
Aviso 'O Android continua no slot A como reserva, mas os dados dele serao perdidos.'
Aviso 'Mantenha o tablet com mais de 50% de bateria e nao desconecte o cabo durante o processo.'
$resp = Read-Host 'Digite SIM para continuar'
if ($resp -ne 'SIM') { Write-Host 'Cancelado.'; exit 0 }

# ------------------------------------------------------------------ desbloqueio e boot
function EstadoAdb {
    $r = Rodar $Adb 'devices'
    foreach ($l in ($r.Saida -split "`r?`n")) {
        if ($l -match "^\S+\s+(device|unauthorized|recovery)$") { return $Matches[1] }
    }
    return $null
}
function EmFastboot { (Rodar $Fastboot 'devices').Saida -match "\sfastboot" }

$desbloqueioTentado = $false
$bootGravado = $false
$aviso = ''
Passo 'Procurando o tablet (cabo USB ligado ao PC)'
while ($true) {
    if (PortaAberta $PortaImg) { break }

    if (EmFastboot) {
        $m = (Rodar $Fastboot 'getvar max-download-size').Saida
        if ($m -match 'max-download-size:\s*0x([0-9a-fA-F]+)') {
            $max = [Convert]::ToInt64($Matches[1], 16)
            if ((Get-Item $Boot).Length -gt $max) { Falha "o boot ($((Get-Item $Boot).Length) bytes) passa do limite do fastboot ($max)" }
        }
        # Este bootloader nao informa se esta desbloqueado (getvar unlocked vem vazio).
        # Bloqueado, ele recusa a gravacao; so entao roda o desbloqueio e tenta de novo.
        Passo 'Gravando o boot do Linux no slot B'
        $r = Rodar $Fastboot "flash boot_b `"$Boot`""
        Write-Host $r.Saida
        if ($r.Codigo -ne 0) {
            if ($desbloqueioTentado) { Falha 'a gravacao do boot_b falhou mesmo depois do desbloqueio. Reinicie o tablet no fastboot e rode de novo.' }
            Passo 'O bootloader recusou a gravacao: desbloqueando'
            Aviso 'Olhe a tela do tablet e CONFIRME o desbloqueio com as teclas de volume, como a tela indicar.'
            Aviso 'O desbloqueio apaga os dados do Android.'
            $desbloqueioTentado = $true
            & $VenvPy -m unisoc_unlock unlock
            if ($LASTEXITCODE -ne 0) { Falha 'o desbloqueio falhou (veja a mensagem acima).' }
            Start-Sleep 5
            $fim = (Get-Date).AddSeconds(90)
            while ((Get-Date) -lt $fim -and -not (EmFastboot)) { Start-Sleep 2 }
            if (-not (EmFastboot)) {
                Aviso 'O tablet saiu do fastboot depois do desbloqueio. Se ele voltou ao Android, ative de novo a Depuracao USB.'
            }
            continue
        }
        # --set-active reinicia o tablet sozinho; o "usb_read failed" que aparece e esse reinicio.
        $r = Rodar $Fastboot '--set-active=b'
        if ($r.Codigo -ne 0 -and $r.Saida -notmatch 'usb_read failed') { Write-Host $r.Saida; Falha 'nao consegui ativar o slot B.' }
        Start-Sleep 5
        if (EmFastboot) { Rodar $Fastboot 'reboot' | Out-Null }
        $bootGravado = $true
        Passo 'Esperando o Linux subir no tablet (ate 5 minutos)'
        Write-Host 'A tela do tablet mostra o log do boot e depois "MODO INSTALACAO".'
        $fim = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $fim -and -not (PortaAberta $PortaImg)) { Start-Sleep 3 }
        if (-not (PortaAberta $PortaImg)) {
            Falha 'o tablet nao respondeu em 192.168.42.1. Veja no Gerenciador de Dispositivos se apareceu "Remote NDIS" e rode o instalar.cmd de novo.'
        }
        break
    }

    $e = EstadoAdb
    if ($e -eq 'device' -or $e -eq 'recovery') {
        Write-Host 'Android encontrado. Reiniciando no modo fastboot...'
        Rodar $Adb 'reboot bootloader' | Out-Null
        $fim = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $fim -and -not (EmFastboot)) { Start-Sleep 2 }
        if (-not (EmFastboot)) {
            Aviso 'O tablet nao apareceu no fastboot. Se a tela dele mostra "fastboot mode", instale o Google USB Driver (veja o README).'
        }
        continue
    }
    if (PortaAberta 22) {
        Falha 'o Debian ja esta instalado e rodando. Para reinstalar, abra o Console no tablet, rode "sudo t2040-reinstalar" e depois este instalar.cmd.'
    }
    $novo = if ($e -eq 'unauthorized') { 'Aceite a pergunta "Permitir depuracao USB?" na tela do tablet.' }
            else { 'Ligue o tablet no Android com a Depuracao USB ativa (veja o README) e conecte o cabo.' }
    if ($novo -ne $aviso) { Aviso $novo; $aviso = $novo }
    Start-Sleep 3
}

# ------------------------------------------------------------------ envio do sistema
Passo "Enviando o Debian para o tablet ($([math]::Round((Get-Item $Root).Length / 1MB)) MB compactados)"
Write-Host 'O tablet descompacta e grava enquanto recebe. Leva de 5 a 15 minutos.'
# o teste de porta acima abre e fecha uma conexao; o tablet leva um instante para voltar a escutar
$cli = $null
$fim = (Get-Date).AddSeconds(60)
while (-not $cli) {
    try { $cli = New-Object System.Net.Sockets.TcpClient($IpTablet, $PortaImg) }
    catch { if ((Get-Date) -gt $fim) { Falha 'nao consegui conectar no modo instalacao do tablet.' }; Start-Sleep 1 }
}
$cli.SendBufferSize = 1MB
$rede = $cli.GetStream()
$arq = [System.IO.File]::OpenRead($Root)
$buf = New-Object byte[] (1MB)
$total = $arq.Length; $enviado = 0; $ultimo = -1
try {
    while (($n = $arq.Read($buf, 0, $buf.Length)) -gt 0) {
        $rede.Write($buf, 0, $n)
        $enviado += $n
        $pct = [int](100 * $enviado / $total)
        if ($pct -ne $ultimo) { Write-Host -NoNewline "`r  $pct%  "; $ultimo = $pct }
    }
    $cli.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
    while ($rede.Read($buf, 0, $buf.Length) -gt 0) { }
} catch {
    Aviso "`nA conexao caiu durante o envio: $($_.Exception.Message)"
} finally { $arq.Close(); $cli.Close() }
Write-Host ''

Passo 'Conferindo a gravacao no tablet'
$resultado = $null
$fim = (Get-Date).AddMinutes(10)
# O tablet entrega o resultado uma unica vez: le direto na primeira conexao, sem testar a porta antes.
while ((Get-Date) -lt $fim -and -not $resultado) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient($IpTablet, $PortaRes)
        $resultado = (New-Object System.IO.StreamReader($c.GetStream())).ReadToEnd().Trim()
        $c.Close()
    } catch { Start-Sleep 2 }
}
if (-not $resultado) { Falha 'o tablet nao informou o resultado. Veja a tela dele e rode o instalar.cmd de novo.' }
$partes = $resultado -split '\s+'
if ($partes[0] -ne 'OK') { Falha "o tablet recusou a imagem ($resultado). Rode o instalar.cmd de novo." }
if ($partes[1] -ne $RootRawSha) { Falha "a imagem gravada nao confere (SHA-256 $($partes[1])). Rode o instalar.cmd de novo." }

Passo 'Pronto!'
Write-Host 'O tablet esta reiniciando no Debian 13 + Phosh. O primeiro boot leva uns 2 minutos.'
Write-Host 'Usuario: t2040    PIN/senha: 1234 (troque em Configuracoes > Usuarios).'
