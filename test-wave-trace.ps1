# Quick diagnostic script that launches headless Chrome, runs the wave gesture, and prints the exact step-by-step trace
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$port = 9333
$proc = Start-Process -FilePath $chromePath -ArgumentList @(
    "--headless=new",
    "--remote-debugging-port=$port",
    "--no-first-run",
    "--no-default-browser-check",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "http://localhost:8000/"
) -PassThru

Start-Sleep -Seconds 2

try {
    $wsUrl = (Invoke-RestMethod -Uri "http://127.0.0.1:$port/json")[0].webSocketDebuggerUrl
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).Wait()

    $script:cmdId = 1
    function Send-Cdp([string]$expression) {
        $reqId = $script:cmdId++
        $cmdObj = @{
            id = $reqId
            method = "Runtime.evaluate"
            params = @{
                expression = $expression
                returnByValue = $true
                awaitPromise = $true
            }
        }
        $json = $cmdObj | ConvertTo-Json -Compress -Depth 10
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        
        while ($true) {
            $buffer = [System.Net.WebSockets.ClientWebSocket]::CreateClientBuffer(65536, 65536)
            $mem = New-Object System.IO.MemoryStream
            do {
                $task = $ws.ReceiveAsync($buffer, [System.Threading.CancellationToken]::None)
                $task.Wait()
                $res = $task.Result
                $mem.Write($buffer.Array, $buffer.Offset, $res.Count)
            } while (-not $res.EndOfMessage)
            
            $resp = [System.Text.Encoding]::UTF8.GetString($mem.ToArray()) | ConvertFrom-Json
            if ($resp.id -eq $reqId) {
                if ($resp.result.exceptionDetails) {
                    throw "JS Error: $($resp.result.exceptionDetails.exception.description)"
                }
                return $resp.result.result.value
            }
        }
    }

    # Wait for bootstrap
    Write-Host "Waiting for bootstrap..." -ForegroundColor Yellow
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $ready = Send-Cdp "typeof window.DeskOS === 'object' && window.DeskOS.state.isEngineReady"
            if ($ready -eq $true) { break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }

    # Define __makeTestLandmarks
    Send-Cdp @"
    window.__makeTestLandmarks = function(type) {
        const lm = [];
        for (let i = 0; i < 21; i++) lm.push({ x: 0.5, y: 0.5, z: 0 });
        lm[0] = { x: 0.5, y: 0.7, z: 0 };
        lm[5] = { x: 0.46, y: 0.5, z: 0 };
        lm[9] = { x: 0.50, y: 0.48, z: 0 };
        lm[13] = { x: 0.54, y: 0.5, z: 0 };
        lm[17] = { x: 0.58, y: 0.53, z: 0 };
        lm[6] = { x: 0.45, y: 0.4, z: 0 };
        lm[10] = { x: 0.50, y: 0.45, z: 0 };
        lm[14] = { x: 0.55, y: 0.47, z: 0 };
        lm[18] = { x: 0.59, y: 0.50, z: 0 };
        lm[4] = { x: 0.40, y: 0.45, z: 0 };
        lm[8] = { x: 0.44, y: 0.26, z: 0 };
        lm[12] = { x: 0.50, y: 0.24, z: 0 };
        lm[16] = { x: 0.56, y: 0.26, z: 0 };
        lm[20] = { x: 0.60, y: 0.30, z: 0 };
        return lm;
    };
"@

    # Run the exact sequence and collect trace
    $trace = Send-Cdp @"
    (async function() {
        const trace = [];
        window.DeskOS.state.penTimer.isRunning = true;
        window.DeskOS.state.penTimer.elapsedMs = 2500;
        window.DeskOS.state.gestureControl.lastFiredTime = 0;
        window.DeskOS.state.gestureControl.isWaitingForNeutral = false;
        window.DeskOS.state.gestureControl.palmXHistory = [];

        const shifts = [0.0, 0.04, 0.08, 0.04, -0.01, -0.06, -0.10, -0.05, 0.0, 0.06, 0.10];
        for (let i = 0; i < shifts.length; i++) {
            const lm = window.__makeTestLandmarks('neutral');
            const dx = shifts[i];
            for (let j = 0; j < 21; j++) {
                lm[j].x += dx;
            }
            window.DeskOS.onHandResults({ multiHandLandmarks: [lm] });
            trace.push({
                i: i,
                shift: shifts[i],
                palmX: lm[9].x,
                historyLen: window.DeskOS.state.gestureControl.palmXHistory.length,
                currentGesture: window.DeskOS.state.currentGesture,
                lastFired: window.DeskOS.state.gestureControl.lastFiredGesture,
                timerRunning: window.DeskOS.state.penTimer.isRunning,
                timerDisplay: document.getElementById('timerDisplay')?.textContent,
                badge: document.getElementById('timerStatusBadge')?.textContent
            });
            await new Promise(r => setTimeout(r, 45));
        }
        return trace;
    })()
"@

    Write-Host "TRACE RESULTS:" -ForegroundColor Yellow
    $trace | Format-Table -AutoSize
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
