

# ----------------------------
# Configuration
# ----------------------------
$qlikServer = "qlik.company.com"
$virtualProxy = "/dev"
$appId = "<APP_ID>"

# Simple load script
$loadScript = @"
LOAD * INLINE [
    Name, Age
    Alice, 30
    Bob, 25
];
"@

# XRF key
$xrfkey = "abcdefghijklmnop"

# ----------------------------
# 1️⃣ Request a Ticket
# ----------------------------
$ticketPayload = @{
    "UserId" = "$env:USERNAME"
    "UserDirectory" = "<YOUR_DOMAIN>"
} | ConvertTo-Json

$ticketUrl = "https://$qlikServer$virtualProxy/ticket?xrfkey=$xrfkey"
$headers = @{
    "X-Qlik-Xrfkey" = $xrfkey
    "Content-Type"  = "application/json"
}

$ticketResponse = Invoke-RestMethod -Method Post -Uri $ticketUrl -Headers $headers -Body $ticketPayload
$ticket = $ticketResponse.Ticket
Write-Host "Ticket received: $ticket"

# ----------------------------
# 2️⃣ Create session cookie
# ----------------------------
$hubUrl = "https://$qlikServer$virtualProxy/hub?qlikTicket=$ticket"
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Invoke-WebRequest -Uri $hubUrl -WebSession $session -MaximumRedirection 0 -ErrorAction SilentlyContinue

$cookie = $session.Cookies.GetCookies("https://$qlikServer") | Where-Object { $_.Name -eq "X-Qlik-Session" }
$sessionId = $cookie.Value
Write-Host "Session ID: $sessionId"

# ----------------------------
# 3️⃣ Connect to Engine via WebSocket
# ----------------------------
Add-Type -AssemblyName System.Net.WebSockets.Client

$uri = [Uri] "wss://$qlikServer$virtualProxy/app/$appId?xrfkey=$xrfkey"

$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.Options.SetRequestHeader("Cookie", "X-Qlik-Session=$sessionId")
$ws.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait()
Write-Host "WebSocket connected"

# Helper function to send JSON RPC
function Send-JsonRpc {
    param($socket, $obj)
    $json = ($obj | ConvertTo-Json -Compress)
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

# ----------------------------
# 4️⃣ Open the app
# ----------------------------
Send-JsonRpc -socket $ws -obj @{
    method = "OpenDoc"
    handle = -1
    params = @($appId)
    id = 1
}

# ----------------------------
# 5️⃣ Set load script
# ----------------------------
Send-JsonRpc -socket $ws -obj @{
    method = "SetScript"
    handle = 1
    params = @($loadScript)
    id = 2
}

Write-Host "Load script set successfully"

# ----------------------------
# 6️⃣ Close WebSocket
# ----------------------------
$ws.Dispose()
Write-Host "WebSocket closed"