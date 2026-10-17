# Quick diagnostic for DeskOS gestures
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$target = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json")[0].webSocketDebuggerUrl
$ws.ConnectAsync([System.Uri]::new($target), [System.Threading.CancellationToken]::None).Wait()

function Eval-Js([string]$expression) {
    $cmdObj = @{
        id = 9999
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
    
    $buffer = [System.Net.WebSockets.ClientWebSocket]::CreateClientBuffer(65536, 65536)
    $mem = New-Object System.IO.MemoryStream
    do {
        $task = $ws.ReceiveAsync($buffer, [System.Threading.CancellationToken]::None)
        $task.Wait()
        $res = $task.Result
        $mem.Write($buffer.Array, $buffer.Offset, $res.Count)
    } while (-not $res.EndOfMessage)
    
    $resp = [System.Text.Encoding]::UTF8.GetString($mem.ToArray()) | ConvertFrom-Json
    return $resp.result.result.value
}

$diag = Eval-Js @"
(async function() {
    const logs = [];
    const makeHand = (shiftX) => {
        const lm = window.__makeTestLandmarks('neutral');
        for (let i = 0; i < 21; i++) {
            lm[i].x += shiftX;
        }
        return lm;
    };

    // First ensure neutral and cooldown expired
    window.DeskOS.state.gestureControl.lastFiredTime = 0;
    window.DeskOS.state.gestureControl.isWaitingForNeutral = false;
    window.DeskOS.state.gestureControl.palmXHistory = [];

    // Wave shifts: 0 -> +0.10 -> -0.10 -> +0.10
    const shifts = [0.0, 0.03, 0.07, 0.10, 0.06, 0.0, -0.06, -0.10, -0.05, 0.0, 0.06, 0.10];
    for (let i = 0; i < shifts.length; i++) {
        const lm = makeHand(shifts[i]);
        window.DeskOS.onHandResults({ multiHandLandmarks: [lm] });
        logs.push({
            i,
            shift: shifts[i],
            palmX: lm[9].x,
            historyLen: window.DeskOS.state.gestureControl.palmXHistory.length,
            gesture: window.DeskOS.state.currentGesture,
            timerRunning: window.DeskOS.state.penTimer.isRunning,
            timerDisplay: document.getElementById('timerDisplay')?.textContent,
            lastFired: window.DeskOS.state.gestureControl.lastFiredGesture
        });
        await new Promise(r => setTimeout(r, 50));
    }
    return logs;
})()
"@

$diag | Format-Table -AutoSize
$ws.Dispose()
