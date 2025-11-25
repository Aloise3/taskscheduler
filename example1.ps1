# =========================
# Qlik GitOps Workflow
# =========================
# PowerShell 7+
# Uses native .NET WebSocket (no external modules)
# =========================

function Request-Ticket {
    param($Server, $VirtualProxy, $UserDirectory, $UserId)

    $xrfkey = -join ((65..90) + (97..122) | Get-Random -Count 16 | % {[char]$_})
    $ticketPayload = @{
        "UserId" = $UserId
        "UserDirectory" = $UserDirectory
    } | ConvertTo-Json

    $ticketUrl = "https://$Server$VirtualProxy/ticket?xrfkey=$xrfkey"
    $headers = @{
        "X-Qlik-Xrfkey" = $xrfkey
        "Content-Type" = "application/json"
    }

    $ticketResponse = Invoke-RestMethod -Method Post -Uri $ticketUrl -Headers $headers -Body $ticketPayload
    return @{Ticket = $ticketResponse.Ticket; XrfKey = $xrfkey}
}

function Get-SessionCookie {
    param($Server, $VirtualProxy, $Ticket)

    $hubUrl = "https://$Server$VirtualProxy/hub?qlikTicket=$Ticket"
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri $hubUrl -WebSession $session -MaximumRedirection 0 -ErrorAction SilentlyContinue

    $cookie = $session.Cookies.GetCookies("https://$Server") | Where-Object { $_.Name -eq "X-Qlik-Session" }
    return $cookie.Value
}

function Connect-EngineWebSocket {
    param($Server, $VirtualProxy, $AppId, $SessionId, $XrfKey)

    $uri = [Uri] "wss://$Server$VirtualProxy/app/$AppId?xrfkey=$XrfKey"
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader("Cookie", "X-Qlik-Session=$SessionId")
    $ws.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait()
    return $ws
}

function Send-JsonRpc {
    param($Socket, $Object)

    $json = ($Object | ConvertTo-Json -Compress)
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

function Receive-JsonRpc {
    param($Socket)

    $buffer = New-Object byte[] 8192
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None).Wait()
    $json = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $segment.Count)
    return $json | ConvertFrom-Json
}

function Export-AppArtifacts {
    param($Server, $VirtualProxy, $AppId, $UserDirectory, $UserId, $ExportPath)

    # 1. Request ticket
    $ticketInfo = Request-Ticket -Server $Server -VirtualProxy $VirtualProxy -UserDirectory $UserDirectory -UserId $UserId

    # 2. Get session cookie
    $sessionId = Get-SessionCookie -Server $Server -VirtualProxy $VirtualProxy -Ticket $ticketInfo.Ticket

    # 3. Connect WebSocket
    $ws = Connect-EngineWebSocket -Server $Server -VirtualProxy $VirtualProxy -AppId $AppId -SessionId $sessionId -XrfKey $ticketInfo.XrfKey

    # 4. Open the app
    Send-JsonRpc -Socket $ws -Object @{
        method = "OpenDoc"
        handle = -1
        params = @($AppId)
        id = 1
    }
    Receive-JsonRpc -Socket $ws | Out-Null

    # 5. Get load script
    Send-JsonRpc -Socket $ws -Object @{
        method = "GetScript"
        handle = 1
        params = @()
        id = 2
    }
    $response = Receive-JsonRpc -Socket $ws
    $response.result.script | Out-File "$ExportPath/loadscript.json"

    # 6. TODO: Get sheets, variables, objects (similar: use GetProperties)
    # You can loop through GetChildInfos and then GetProperties per object

    $ws.Dispose()
    Write-Host "Exported artifacts for app $AppId to $ExportPath"
}

function Import-AppArtifacts {
    param($Server, $VirtualProxy, $AppId, $UserDirectory, $UserId, $ArtifactPath)

    # Request ticket
    $ticketInfo = Request-Ticket -Server $Server -VirtualProxy $VirtualProxy -UserDirectory $UserDirectory -UserId $UserId
    $sessionId = Get-SessionCookie -Server $Server -VirtualProxy $VirtualProxy -Ticket $ticketInfo.Ticket

    # Connect WebSocket
    $ws = Connect-EngineWebSocket -Server $Server -VirtualProxy $VirtualProxy -AppId $AppId -SessionId $sessionId -XrfKey $ticketInfo.XrfKey

    # Open app
    Send-JsonRpc -Socket $ws -Object @{ method = "OpenDoc"; handle = -1; params = @($AppId); id = 1 }
    Receive-JsonRpc -Socket $ws | Out-Null

    # Set load script
    $script = Get-Content "$ArtifactPath/loadscript.json" -Raw
    Send-JsonRpc -Socket $ws -Object @{ method = "SetScript"; handle = 1; params = @($script); id = 2 }
    Receive-JsonRpc -Socket $ws | Out-Null

    # TODO: Import sheets, variables, objects (similar using SetProperties)

    $ws.Dispose()
    Write-Host "Imported artifacts for app $AppId from $ArtifactPath"
}

# =========================
# Example usage
# =========================

# Export Dev app
Export-AppArtifacts -Server "qlik-dev.company.com" -VirtualProxy "/dev" -AppId "<APP_ID>" -UserDirectory "MYDOMAIN" -UserId "service_account" -ExportPath "C:\GitRepo\apps\App1"

# Commit exported artifacts to Git manually or via script

# Import into Test environment after PR merge
Import-AppArtifacts -Server "qlik-test.company.com" -VirtualProxy "/dev" -AppId "<APP_ID>" -UserDirectory "MYDOMAIN" -UserId "service_account" -ArtifactPath "C:\GitRepo\apps\App1"

# Later, Import into Production similarly