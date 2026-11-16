param([int]$Port = 8765)

# Run on Windows after starting KindleDeck.ahk. Does not launch any apps.
$ErrorActionPreference = 'Stop'
$HostHeader = "127.0.0.1:$Port"

function Send-DeckRequest {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        [string]$Body = '',
        [string]$RequestHost = $HostHeader,
        [string]$ContentType = 'application/x-www-form-urlencoded',
        [switch]$Fragmented
    )
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        $request = "$Method $Path HTTP/1.1`r`nHost: $RequestHost`r`nConnection: close`r`n"
        if ($Method -eq 'POST') {
            $request += "Content-Type: $ContentType`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($Body))`r`n"
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($request + "`r`n" + $Body)
        if ($Fragmented) {
            # Force a header/body wait across multiple 30ms server timer ticks.
            $cut = $bytes.Length - 3
            $stream.Write($bytes, 0, $cut)
            Start-Sleep -Milliseconds 120
            $stream.Write($bytes, $cut, 3)
        } else {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally {
        $client.Dispose()
    }
}

function Assert-Status {
    param([string]$Response, [int]$Expected, [string]$Name)
    if ($Response -notmatch "^HTTP/1\.1 $Expected ") {
        throw "$Name failed. Expected HTTP $Expected. Received: $Response"
    }
    Write-Host "PASS: $Name"
}

$deckPage = Send-DeckRequest
Assert-Status $deckPage 200 'Home page'
$match = [regex]::Match($deckPage, 'name="token" value="([0-9a-f]{64})"')
if (-not $match.Success) { throw 'Home page has no valid form token.' }
$formToken = $match.Groups[1].Value
foreach ($command in 'discord', 'notepad', 'apple-music') {
    if ($deckPage -notmatch ('name="command" value="' + $command + '"')) {
        throw "Missing button: $command"
    }
}
Write-Host 'PASS: All three buttons and the form token'
Assert-Status (Send-DeckRequest -Path '/launch') 405 'GET cannot launch an app'
Assert-Status (Send-DeckRequest -Path '/missing') 404 'Unknown route'
Assert-Status (Send-DeckRequest -RequestHost "untrusted.example:$Port") 403 'Unknown Host rejected'
$wrongToken = '0' * 64
if ($wrongToken -ceq $formToken) { $wrongToken = '1' * 64 }
Assert-Status (Send-DeckRequest -Method POST -Path '/launch' -Body "token=$wrongToken&command=discord") 403 'Wrong token rejected'
Assert-Status (Send-DeckRequest -Method POST -Path '/launch' -Body "token=$formToken&command=unknown") 400 'Unknown command rejected'
Assert-Status (Send-DeckRequest -Method POST -Path '/launch' -Body "token=$formToken&command=unknown" -Fragmented) 400 'Fragmented request read completely'
Assert-Status (Send-DeckRequest -Method POST -Path '/launch' -Body "token=$formToken&command=discord" -ContentType 'text/plain') 415 'Wrong content type rejected'
Assert-Status (Send-DeckRequest -Method POST -Path '/launch' -Body 'command=discord') 400 'Missing token rejected'
Assert-Status (Send-DeckRequest -Method POST -Path '/launch' -Body ('x' * 1025)) 413 'Oversized body rejected'
Assert-Status (Send-DeckRequest -Path '/?status=discord') 200 'Result page is a safe GET'
Write-Host 'Server smoke checks passed. Now test the three buttons manually and then on the Kindle.'
