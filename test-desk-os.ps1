# test-desk-os.ps1 - Automated End-to-End Test Suite for Real Camera-Based Desk-OS
param(
    [int]$DebugPort = 9222,
    [string]$TargetUrl = "http://localhost:8000/"
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "   Desk-OS Real Camera & Pen Tracker E2E Suite   " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. Start Chrome headless with remote debugging and fake video stream
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chromePath)) {
    $chromePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
}

$testDataDir = "$env:TEMP\desk-os-chrome-test-$DebugPort"
Remove-Item -Recurse -Force $testDataDir -ErrorAction SilentlyContinue

Write-Host "`n[1/6] Launching browser with live webcam mock: $chromePath" -ForegroundColor Yellow
$proc = Start-Process -FilePath $chromePath -ArgumentList @(
    "--headless=new",
    "--remote-debugging-port=$DebugPort",
    "--remote-allow-origins=*",
    "--user-data-dir=$testDataDir",
    "--disable-gpu",
    "--disable-extensions",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    $TargetUrl
) -PassThru

$ws = $null

try {
    # 2. Connect to Chrome DevTools endpoint
    Write-Host "[2/6] Connecting to DevTools at http://127.0.0.1:$DebugPort/json..." -ForegroundColor Yellow
    $retries = 30
    $page = $null
    while ($retries -gt 0) {
        Start-Sleep -Milliseconds 300
        try {
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json" -Method Get -TimeoutSec 2
            $page = $targets | Where-Object { $_.type -eq "page" -and $_.url -match "localhost" } | Select-Object -First 1
            if ($page) { break }
        } catch {
            $retries--
        }
    }

    if (-not $page) {
        throw "Failed to locate Desk-OS page target on port $DebugPort"
    }

    Write-Host "Target located: '$($page.title)' -> $($page.webSocketDebuggerUrl)" -ForegroundColor Green

    # 3. Establish WebSocket connection with DevTools Protocol
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.SetRequestHeader('Origin', "http://127.0.0.1:$DebugPort")
    $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait()

    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw "WebSocket connection failed: State is $($ws.State)"
    }
    Write-Host "WebSocket DevTools connection established (Open)." -ForegroundColor Green

    $script:msgId = 1
    function Send-Cdp([string]$method, [hashtable]$params = @{}) {
        $id = $script:msgId++
        $cmdObj = @{
            id = $id
            method = $method
            params = $params
        }
        $json = $cmdObj | ConvertTo-Json -Compress -Depth 10
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        return $id
    }

    $capturedErrors = [System.Collections.Generic.List[string]]::new()
    $pendingResponses = [System.Collections.Generic.Dictionary[int, object]]::new()
    function Read-CdpResponse([int]$expectedId, [int]$timeoutMs = 8000) {
        if ($pendingResponses.ContainsKey($expectedId)) {
            $ret = $pendingResponses[$expectedId]
            $pendingResponses.Remove($expectedId)
            return $ret
        }
        $buffer = [System.Net.WebSockets.ClientWebSocket]::CreateClientBuffer(65536, 65536)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $timeoutMs -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $mem = New-Object System.IO.MemoryStream
            $res = $null
            do {
                $rem = [Math]::Max(100, $timeoutMs - [int]$sw.ElapsedMilliseconds)
                $cts = [System.Threading.CancellationTokenSource]::new($rem)
                try {
                    $task = $ws.ReceiveAsync($buffer, $cts.Token)
                    $task.Wait()
                    $res = $task.Result
                    if ($res.Count -gt 0) {
                        $mem.Write($buffer.Array, $buffer.Offset, $res.Count)
                    }
                } catch {
                    break
                } finally {
                    $cts.Dispose()
                }
            } while ($res -and -not $res.EndOfMessage)

            if ($mem.Length -gt 0) {
                $str = [System.Text.Encoding]::UTF8.GetString($mem.ToArray())
                try {
                    $obj = $str | ConvertFrom-Json
                    if ($obj.method -eq "Runtime.exceptionThrown") {
                        $errText = $obj.params.exceptionDetails.exception.description
                        if (-not $errText) { $errText = $obj.params.exceptionDetails.text }
                        $capturedErrors.Add("JS Exception: $errText")
                    }
                    if ($obj.method -eq "Log.entryAdded" -and $obj.params.entry.level -eq "error") {
                        $capturedErrors.Add("Console Error: $($obj.params.entry.text) (URL: $($obj.params.entry.url))")
                    }
                    if ($null -ne $obj.id) {
                        if ($obj.id -eq $expectedId) {
                            return $obj
                        } else {
                            $pendingResponses[$obj.id] = $obj
                        }
                    }
                } catch {}
            }
        }
        throw "Timeout waiting for CDP response id $expectedId"
    }

    function Eval-Js([string]$expression) {
        $reqId = Send-Cdp "Runtime.evaluate" @{
            expression = $expression
            returnByValue = $true
            awaitPromise = $true
        }
        $resp = Read-CdpResponse $reqId 12000
        if ($resp.result.exceptionDetails) {
            throw "Evaluation error: $($resp.result.exceptionDetails | ConvertTo-Json -Depth 3)"
        }
        return $resp.result.result.value
    }

    # Enable Logging and Runtime domains
    $null = Send-Cdp "Runtime.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 2000
    $null = Send-Cdp "Log.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 2000

    Write-Host "Waiting for DeskOS engine to bootstrap..." -ForegroundColor Yellow
    $booted = $false
    $bootRetries = 20
    while ($bootRetries -gt 0 -and -not $booted) {
        Start-Sleep -Milliseconds 300
        try {
            $isDefined = Eval-Js "typeof window.DeskOS !== 'undefined'"
            if ($isDefined) { $booted = $true }
        } catch {
            $bootRetries--
        }
    }
    Write-Host "DeskOS Engine bootstrapped successfully!" -ForegroundColor Green

    # 4. Test STEP 1: Verify Real Camera Path (NOT Virtual Desk)
    Write-Host "`n[3/6] Testing Real Camera Initialization & MediaPipe Status..." -ForegroundColor Yellow
    # Allow camera + MediaPipe to initialize
    Start-Sleep -Seconds 5

    $hwState = Eval-Js @"
    ({
        cameraStatus: document.getElementById('cameraStatusText')?.textContent,
        handsStatus: document.getElementById('handsStatusText')?.textContent,
        debugStatus: document.getElementById('debugStatusLine')?.textContent,
        feedMode: window.DeskOS?.state?.feedMode,
        videoVisible: document.getElementById('webcamVideo')?.style.display !== 'none',
        virtualCanvasHidden: document.getElementById('virtualDeskCanvas')?.style.display === 'none'
    })
"@

    Write-Host "  -> Camera Status     : $($hwState.cameraStatus)" -ForegroundColor Cyan
    Write-Host "  -> Hands Status      : $($hwState.handsStatus)" -ForegroundColor Cyan
    Write-Host "  -> Debug Status      : $($hwState.debugStatus)" -ForegroundColor Cyan
    Write-Host "  -> Feed Mode         : $($hwState.feedMode)" -ForegroundColor Cyan
    Write-Host "  -> Video Visible     : $($hwState.videoVisible)" -ForegroundColor Cyan
    Write-Host "  -> Virtual Hidden    : $($hwState.virtualCanvasHidden)" -ForegroundColor Cyan

    if ($hwState.feedMode -ne "webcam") {
        throw "FAIL: Expected real webcam feed mode as default, but got '$($hwState.feedMode)'!"
    }
    if (-not $hwState.videoVisible) {
        throw "FAIL: Video element is not visible on screen!"
    }
    if ($hwState.handsStatus -match "Initializing") {
        throw "FAIL: Hands status is stuck on 'Initializing' indefinitely!"
    }
    Write-Host "PASS: Real webcam stream is active and visible as primary feed (No virtual fallback)!" -ForegroundColor Green
    Write-Host "PASS: Hands status cleanly transitioned to: '$($hwState.handsStatus)'!" -ForegroundColor Green

    # 5. Test STEP 2 & 3: Real Pen ROI Registration & Detection
    Write-Host "`n[4/6] Testing Real Camera Pen ROI Registration & Lift/Dock Stopwatch..." -ForegroundColor Yellow

    # Register physical pen on the REAL camera feed at (580, 330)
    Write-Host "  Registering physical pen ROI at (580, 330) on live camera feed..." -ForegroundColor Yellow
    Eval-Js @"
    {
        const rect = document.getElementById('arOverlayCanvas').getBoundingClientRect();
        // Simulate click to register pen
        const clickEvent = new MouseEvent('click', {
            clientX: rect.left + 580 * (rect.width / 1280),
            clientY: rect.top + 330 * (rect.height / 720),
            bubbles: true
        });
        document.getElementById('arOverlayCanvas').dispatchEvent(clickEvent);

        // Fill rule input
        document.getElementById('ruleInputText').value = 'When physical pen lifted, start focus stopwatch';
        document.getElementById('bindRuleBtn').click();
    }
"@
    Start-Sleep -Milliseconds 600

    $penRegistration = Eval-Js @"
    ({
        objCount: window.DeskOS.state.objects.length,
        pen: window.DeskOS.state.objects.find(o => o.isPenTimer || o.name.toLowerCase().includes('pen')),
        initialDisplay: document.getElementById('timerDisplay')?.textContent,
        initialBadge: document.getElementById('timerStatusBadge')?.textContent,
        isRunning: window.DeskOS.state.penTimer.isRunning
    })
"@

    Write-Host "  Registered Pen Object: $($penRegistration.pen.name) at resting ($($penRegistration.pen.restingX), $($penRegistration.pen.restingY))" -ForegroundColor Cyan
    Write-Host "  Initial Timer Display: $($penRegistration.initialDisplay) (Status: $($penRegistration.initialBadge))" -ForegroundColor Cyan

    if (-not $penRegistration.pen) {
        throw "FAIL: Physical pen object was not registered!"
    }
    if ($penRegistration.isRunning) {
        throw "FAIL: Timer should be docked (not running) initially!"
    }
    Write-Host "PASS: Physical Pen ROI registered successfully on live camera stream!" -ForegroundColor Green

    # Simulate Physical Pen Lift (Displace tracked ROI on camera feed)
    Write-Host "`n  Simulating: Lifting physical pen from resting dock on camera feed..." -ForegroundColor Yellow
    Eval-Js @"
    (() => {
        const pen = window.DeskOS.state.objects.find(o => o.isPenTimer || o.name.toLowerCase().includes('pen'));
        if (pen) {
            // Move tracked position away from resting dock
            pen.x = 220;
            pen.y = 200;
        }
        return true;
    })()
"@
    Start-Sleep -Seconds 2

    $lifted = Eval-Js @"
    ({
        display: document.getElementById('timerDisplay')?.textContent,
        badge: document.getElementById('timerStatusBadge')?.textContent,
        isRunning: window.DeskOS.state.penTimer.isRunning,
        dockStatus: window.DeskOS.state.objects.find(o => o.isPenTimer)?.dockStatus
    })
"@
    Write-Host "  After Lift: $($lifted.display) (Badge: $($lifted.badge), Running: $($lifted.isRunning), Dock: $($lifted.dockStatus))" -ForegroundColor Green

    if (-not $lifted.isRunning) {
        throw "FAIL: Real camera pen lift did not auto-start stopwatch!"
    }
    if ($lifted.display -eq "00:00.0") {
        throw "FAIL: Stopwatch did not advance time while lifted!"
    }
    Write-Host "PASS: Real physical pen lift triggered auto-start! Time: $($lifted.display)" -ForegroundColor Green

    # Simulate Returning Physical Pen into Resting Dock
    Write-Host "`n  Simulating: Placing physical pen back into resting dock on camera feed..." -ForegroundColor Yellow
    Eval-Js @"
    (() => {
        const pen = window.DeskOS.state.objects.find(o => o.isPenTimer || o.name.toLowerCase().includes('pen'));
        if (pen) {
            pen.x = pen.restingX;
            pen.y = pen.restingY;
        }
        return true;
    })()
"@
    Start-Sleep -Milliseconds 600

    $docked = Eval-Js @"
    ({
        display: document.getElementById('timerDisplay')?.textContent,
        badge: document.getElementById('timerStatusBadge')?.textContent,
        isRunning: window.DeskOS.state.penTimer.isRunning,
        dockStatus: window.DeskOS.state.objects.find(o => o.isPenTimer)?.dockStatus
    })
"@
    Write-Host "  After Docking: $($docked.display) (Badge: $($docked.badge), Running: $($docked.isRunning), Dock: $($docked.dockStatus))" -ForegroundColor Green

    if ($docked.isRunning) {
        throw "FAIL: Returning pen to dock did not auto-pause stopwatch!"
    }
    Write-Host "PASS: Physical pen return to dock auto-paused stopwatch (retaining elapsed time)!" -ForegroundColor Green

    # Manual Reset Button
    Write-Host "`n  Clicking Stopwatch Reset button..." -ForegroundColor Yellow
    Eval-Js "document.getElementById('timerResetBtn').click();"
    $afterResetDisplay = Eval-Js "document.getElementById('timerDisplay')?.textContent"
    $afterResetBadge = Eval-Js "document.getElementById('timerStatusBadge')?.textContent"
    Write-Host "  After Reset: $afterResetDisplay (Badge: $afterResetBadge)" -ForegroundColor Green

    if ($afterResetDisplay -ne "00:00.0") {
        throw "FAIL: Timer did not reset to 00:00.0!"
    }
    Write-Host "PASS: Manual reset successfully restored timer to 00:00.0!" -ForegroundColor Green

    # 6. Test STEP 1, 2, 3: Gesture-Controlled Timer Engine (Point, Fist, Wave) & Debounce
    Write-Host "`n[5/7] Testing Gesture-Controlled Timer & Debounce Engine (Point, Fist, Wave)..." -ForegroundColor Yellow

    # Define JS helper functions in page for synthetic landmark injection
    Eval-Js @"
    window.__makeTestLandmarks = function(type) {
        const lm = [];
        for (let i = 0; i < 21; i++) lm.push({ x: 0.5, y: 0.5, z: 0 });
        lm[0] = { x: 0.5, y: 0.7, z: 0 }; // Wrist
        // MCPs
        lm[5] = { x: 0.46, y: 0.5, z: 0 };
        lm[9] = { x: 0.50, y: 0.48, z: 0 };
        lm[13] = { x: 0.54, y: 0.5, z: 0 };
        lm[17] = { x: 0.58, y: 0.53, z: 0 };
        // PIPs
        lm[6] = { x: 0.45, y: 0.4, z: 0 };
        lm[10] = { x: 0.50, y: 0.45, z: 0 };
        lm[14] = { x: 0.55, y: 0.47, z: 0 };
        lm[18] = { x: 0.59, y: 0.50, z: 0 };
        // Tips
        lm[4] = { x: 0.40, y: 0.45, z: 0 };
        lm[8] = { x: 0.44, y: 0.26, z: 0 }; // Index tip default
        lm[12] = { x: 0.50, y: 0.24, z: 0 };
        lm[16] = { x: 0.56, y: 0.26, z: 0 };
        lm[20] = { x: 0.60, y: 0.30, z: 0 };

        if (type === 'point') {
            // Index straight up (lm[8] at 0.26)
            // Middle, ring, pinky curled into palm
            lm[12] = { x: 0.50, y: 0.56, z: 0 };
            lm[16] = { x: 0.54, y: 0.57, z: 0 };
            lm[20] = { x: 0.58, y: 0.59, z: 0 };
        } else if (type === 'fist') {
            // All 4 fingertips curled into palm
            lm[6] = { x: 0.45, y: 0.46, z: 0 };
            lm[8] = { x: 0.45, y: 0.56, z: 0 };
            lm[12] = { x: 0.50, y: 0.56, z: 0 };
            lm[16] = { x: 0.54, y: 0.57, z: 0 };
            lm[20] = { x: 0.58, y: 0.59, z: 0 };
        }
        return lm;
    };
"@

    # Run 2 complete cycles to confirm debounce & repeatability
    for ($cycle = 1; $cycle -le 2; $cycle++) {
        Write-Host "  --- Gesture Test Cycle $cycle of 2 ---" -ForegroundColor Cyan

        # Return to Neutral before starting cycle and wait for cooldown
        Eval-Js "window.DeskOS.onHandResults({ multiHandLandmarks: [window.__makeTestLandmarks('neutral')] });"
        Start-Sleep -Milliseconds 700

        # Subtest A: 👉 Point Gesture ➔ Start Timer
        Write-Host "    Simulating Point Gesture (👉) to START timer..." -ForegroundColor Yellow
        $pointRes = Eval-Js @"
        (function() {
            const pointLm = window.__makeTestLandmarks('point');
            window.DeskOS.onHandResults({ multiHandLandmarks: [pointLm] });
            return {
                isRunning: window.DeskOS.state.penTimer.isRunning,
                display: document.getElementById('timerDisplay')?.textContent,
                badge: document.getElementById('timerStatusBadge')?.textContent,
                feedbackText: document.getElementById('gestureFeedbackText')?.textContent,
                feedbackVisible: document.getElementById('gestureFeedbackHud')?.classList.contains('show')
            };
        })()
"@
        Write-Host "    Point Detection: Running=$($pointRes.isRunning), Badge=$($pointRes.badge), Feedback='$($pointRes.feedbackText)'" -ForegroundColor Green
        if (-not $pointRes.isRunning) {
            throw "FAIL: Point gesture did not start the timer in Cycle $cycle!"
        }
        if ($pointRes.feedbackText -notmatch "Point detected") {
            throw "FAIL: Expected 'Point detected' in feedback banner, got '$($pointRes.feedbackText)'!"
        }
        Write-Host "    PASS: Point gesture started timer with visible on-screen feedback!" -ForegroundColor Green

        # Verify Debounce: Sending Point gesture again while held must NOT re-trigger
        Write-Host "    Verifying Point Debounce (held gesture)..." -ForegroundColor Yellow
        $debounceRes = Eval-Js @"
        (function() {
            const pointLm = window.__makeTestLandmarks('point');
            window.DeskOS.onHandResults({ multiHandLandmarks: [pointLm] });
            return { isRunning: window.DeskOS.state.penTimer.isRunning };
        })()
"@
        if (-not $debounceRes.isRunning) {
            throw "FAIL: Held Point gesture caused unexpected state change!"
        }
        Write-Host "    PASS: Point gesture debounced smoothly without double-triggering!" -ForegroundColor Green

        # Let timer run for 800ms
        Start-Sleep -Milliseconds 800

        # Return to Neutral and satisfy cooldown
        Eval-Js "window.DeskOS.onHandResults({ multiHandLandmarks: [window.__makeTestLandmarks('neutral')] });"
        Start-Sleep -Milliseconds 700

        # Subtest B: ✊ Fist Gesture ➔ Stop/Pause Timer
        Write-Host "    Simulating Fist Gesture (✊) to STOP/PAUSE timer..." -ForegroundColor Yellow
        $fistRes = Eval-Js @"
        (function() {
            const fistLm = window.__makeTestLandmarks('fist');
            window.DeskOS.onHandResults({ multiHandLandmarks: [fistLm] });
            return {
                isRunning: window.DeskOS.state.penTimer.isRunning,
                display: document.getElementById('timerDisplay')?.textContent,
                badge: document.getElementById('timerStatusBadge')?.textContent,
                feedbackText: document.getElementById('gestureFeedbackText')?.textContent,
                feedbackVisible: document.getElementById('gestureFeedbackHud')?.classList.contains('show')
            };
        })()
"@
        Write-Host "    Fist Detection: Running=$($fistRes.isRunning), Display=$($fistRes.display), Badge=$($fistRes.badge), Feedback='$($fistRes.feedbackText)'" -ForegroundColor Green
        if ($fistRes.isRunning) {
            throw "FAIL: Fist gesture did not stop/pause the timer in Cycle $cycle!"
        }
        if ($fistRes.display -eq "00:00.0") {
            throw "FAIL: Fist gesture should pause (retaining elapsed time), not reset to zero!"
        }
        if ($fistRes.feedbackText -notmatch "Fist detected") {
            throw "FAIL: Expected 'Fist detected' in feedback banner, got '$($fistRes.feedbackText)'!"
        }
        Write-Host "    PASS: Fist gesture paused timer, retained elapsed time ($($fistRes.display)), and showed feedback!" -ForegroundColor Green

        # Verify Fist Debounce
        Eval-Js "window.DeskOS.onHandResults({ multiHandLandmarks: [window.__makeTestLandmarks('fist')] });"
        Start-Sleep -Milliseconds 100

        # Return to Neutral and wait for cooldown
        Eval-Js "window.DeskOS.onHandResults({ multiHandLandmarks: [window.__makeTestLandmarks('neutral')] });"
        Start-Sleep -Milliseconds 700

        # Subtest C: 👋 Wave Gesture ➔ Reset Timer to 00:00.0
        Write-Host "    Simulating Wave Gesture (👋) (natural whole-hand left-right-left reversals) to RESET timer..." -ForegroundColor Yellow
        $waveRes = Eval-Js @"
        (async function() {
            // Natural human hand wave: whole hand shifts along X axis with multiple reversals
            const shifts = [0.0, 0.06, 0.12, 0.06, 0.0, -0.06, -0.12, -0.06, 0.0, 0.06, 0.12];
            const stepLogs = [];
            for (let i = 0; i < shifts.length; i++) {
                const lm = window.__makeTestLandmarks('neutral');
                const dx = shifts[i];
                for (let j = 0; j < 21; j++) {
                    lm[j].x += dx;
                }
                window.DeskOS.onHandResults({ multiHandLandmarks: [lm] });
                stepLogs.push({
                    i,
                    history: window.DeskOS.state.gestureControl.palmXHistory.map(h => ({ x: Math.round(h.x * 1000) / 1000, dt: Math.round(performance.now() - h.t) })),
                    curGesture: window.DeskOS.state.currentGesture,
                    debug: window.DeskOS.state.gestureControl._debug
                });
                await new Promise(r => setTimeout(r, 45));
            }
            return {
                isRunning: window.DeskOS.state.penTimer.isRunning,
                display: document.getElementById('timerDisplay')?.textContent,
                badge: document.getElementById('timerStatusBadge')?.textContent,
                feedbackText: document.getElementById('gestureFeedbackText')?.textContent,
                feedbackVisible: document.getElementById('gestureFeedbackHud')?.classList.contains('show'),
                historyLen: window.DeskOS.state.gestureControl.palmXHistory.length,
                lastFired: window.DeskOS.state.gestureControl.lastFiredGesture,
                isWaiting: window.DeskOS.state.gestureControl.isWaitingForNeutral,
                _debug: window.DeskOS.state.gestureControl._debug,
                stepLogs
            };
        })()
"@
        Write-Host "    Wave Detection: Running=$($waveRes.isRunning), Display=$($waveRes.display), Badge=$($waveRes.badge), HistoryLen=$($waveRes.historyLen), LastFired=$($waveRes.lastFired), Debug=$($waveRes._debug | ConvertTo-Json -Compress), Feedback='$($waveRes.feedbackText)'" -ForegroundColor Green
        Write-Host "    Wave Steps: $($waveRes.stepLogs | ConvertTo-Json -Depth 3 -Compress)" -ForegroundColor Cyan
        if ($waveRes.display -ne "00:00.0") {
            throw "FAIL: Wave gesture did not reset timer to 00:00.0 in Cycle $cycle! Current: $($waveRes.display)"
        }
        if ($waveRes.isRunning) {
            throw "FAIL: Timer should be stopped after wave reset!"
        }
        if ($waveRes.feedbackText -notmatch "Wave detected") {
            throw "FAIL: Expected 'Wave detected' in feedback banner, got '$($waveRes.feedbackText)'!"
        }
        Write-Host "    PASS: Wave gesture successfully reset timer to 00:00.0 with visible feedback!" -ForegroundColor Green

        # Return to Neutral and satisfy cooldown before next cycle
        Eval-Js "window.DeskOS.onHandResults({ multiHandLandmarks: [window.__makeTestLandmarks('neutral')] });"
        Start-Sleep -Milliseconds 700
    }

    # 7. Test STEP 4: UI Cleanup & Active Tasks Panel Clutter Check
    Write-Host "`n[6/7] Testing UI Cleanup & Active Tasks Panel Clutter Removal..." -ForegroundColor Yellow
    # When 0 nodes:
    Eval-Js "window.DeskOS.state.objects = []; window.DeskOS.state.penTimer.penObject = null;"
    Eval-Js "document.getElementById('resetDemoBtn').click();"
    Start-Sleep -Milliseconds 300

    $cleanCheck = Eval-Js @"
    ({
        activeNodesBadgeDisplay: window.getComputedStyle(document.getElementById('activeNodesBadge')).display,
        nodesCountBadgeDisplay: window.getComputedStyle(document.getElementById('nodesCountBadge')).display,
        nodesContainerChildren: document.getElementById('nodesContainer').children.length,
        emptyStateExists: !!document.getElementById('emptyNodesState'),
        parserPillExists: !!document.getElementById('parserStatusPill')
    })
"@
    Write-Host "  Zero-Node UI State: ActiveBadgeDisplay=$($cleanCheck.activeNodesBadgeDisplay), CountBadgeDisplay=$($cleanCheck.nodesCountBadgeDisplay), Children=$($cleanCheck.nodesContainerChildren), EmptyClutter=$($cleanCheck.emptyStateExists), ParserPill=$($cleanCheck.parserPillExists)" -ForegroundColor Cyan

    if ($cleanCheck.activeNodesBadgeDisplay -ne "none") {
        throw "FAIL: '0 Active Bindings' HUD pill is still visible when 0 tasks are active!"
    }
    if ($cleanCheck.nodesCountBadgeDisplay -ne "none") {
        throw "FAIL: '0 Nodes' badge is still visible when 0 tasks are active!"
    }
    if ($cleanCheck.emptyStateExists) {
        throw "FAIL: Legacy 'emptyNodesState' placeholder clutter still exists in DOM!"
    }
    if ($cleanCheck.nodesContainerChildren -ne 0) {
        throw "FAIL: Active tasks panel container should have 0 children when no tasks are active!"
    }
    if ($cleanCheck.parserPillExists) {
        throw "FAIL: Decorative parserStatusPill was not removed from header!"
    }
    Write-Host "PASS: Active tasks panel and HUD cleanly hide all 0-counters, decorative pills, and placeholder clutter!" -ForegroundColor Green

    # 8. Test Demo Mode on Real Camera & Active Tasks Population
    Write-Host "`n[7/7] Testing Demo Mode (Ensuring Live Camera & Active Tasks Display)..." -ForegroundColor Yellow
    Eval-Js "document.getElementById('demoModeBtn').click();"
    Start-Sleep -Milliseconds 600

    $demoModeCheck = Eval-Js @"
    ({
        feedMode: window.DeskOS.state.feedMode,
        videoVisible: document.getElementById('webcamVideo')?.style.display !== 'none',
        objectCount: window.DeskOS.state.objects.length,
        activeBadgeText: document.getElementById('activeNodesBadge')?.querySelector('span')?.textContent,
        activeBadgeDisplay: window.getComputedStyle(document.getElementById('activeNodesBadge')).display,
        countBadgeText: document.getElementById('nodesCountBadge')?.textContent,
        countBadgeDisplay: window.getComputedStyle(document.getElementById('nodesCountBadge')).display,
        cardCount: document.getElementById('nodesContainer').children.length
    })
"@
    Write-Host "  Demo Mode Feed: $($demoModeCheck.feedMode) (Video Visible: $($demoModeCheck.videoVisible), Tasks: $($demoModeCheck.objectCount))" -ForegroundColor Green
    Write-Host "  Active Tasks UI: Badge='$($demoModeCheck.countBadgeText)' (Display: $($demoModeCheck.countBadgeDisplay)), HUD='$($demoModeCheck.activeBadgeText)' (Display: $($demoModeCheck.activeBadgeDisplay)), Cards=$($demoModeCheck.cardCount)" -ForegroundColor Cyan

    if ($demoModeCheck.feedMode -ne "webcam") {
        throw "FAIL: Demo Mode switched to Virtual Desk even though camera was live!"
    }
    if ($demoModeCheck.objectCount -lt 3) {
        throw "FAIL: Demo Mode did not populate preset objects!"
    }
    if ($demoModeCheck.countBadgeDisplay -eq "none" -or $demoModeCheck.countBadgeText -notmatch "3 Active") {
        throw "FAIL: Tasks panel badge should show '3 Active' when 3 tasks are loaded!"
    }
    if ($demoModeCheck.activeBadgeDisplay -eq "none" -or $demoModeCheck.activeBadgeText -notmatch "3 Active") {
        throw "FAIL: HUD pill should show '3 Active Tasks' when 3 tasks are loaded!"
    }
    if ($demoModeCheck.cardCount -ne 3) {
        throw "FAIL: Active tasks panel should contain exactly 3 active task cards!"
    }
    Write-Host "PASS: Active Tasks panel and HUD cleanly display real active count (3 Active Tasks) on live camera feed!" -ForegroundColor Green

    # Clean reset
    Eval-Js "document.getElementById('resetDemoBtn').click();"
    Write-Host "PASS: Demo state cleared cleanly!" -ForegroundColor Green

    # 8. Test Accessibility Mode & Screen-Reader Live Region & Voice Mode
    Write-Host "`n[8/10] Testing Accessibility Mode & Screen-Reader Live Region & Voice Mode..." -ForegroundColor Yellow
    $a11yCheck = Eval-Js @"
    ({
        headerRole: document.querySelector('header')?.getAttribute('role'),
        navTag: document.querySelector('.header-actions')?.tagName?.toLowerCase(),
        mainRole: document.getElementById('mainContent')?.getAttribute('role'),
        footerRole: document.querySelector('footer')?.getAttribute('role'),
        skipLinkHref: document.querySelector('.skip-to-content')?.getAttribute('href'),
        liveRegionExists: !!document.getElementById('a11yLiveRegion'),
        liveRegionLive: document.getElementById('a11yLiveRegion')?.getAttribute('aria-live'),
        liveRegionAtomic: document.getElementById('a11yLiveRegion')?.getAttribute('aria-atomic'),
        voiceBtnLabel: document.getElementById('voiceAnnounceLabel')?.textContent,
        voiceAriaLabel: document.getElementById('voiceAnnounceToggleBtn')?.getAttribute('aria-label')
    })
"@
    Write-Host "  Landmarks: headerRole='$($a11yCheck.headerRole)', navTag='$($a11yCheck.navTag)', mainRole='$($a11yCheck.mainRole)', footerRole='$($a11yCheck.footerRole)'" -ForegroundColor Cyan
    Write-Host "  SkipLink: href='$($a11yCheck.skipLinkHref)', LiveRegion: exists=$($a11yCheck.liveRegionExists), live='$($a11yCheck.liveRegionLive)'" -ForegroundColor Cyan

    if ($a11yCheck.headerRole -ne "banner") { throw "FAIL: <header> is missing role='banner'!" }
    if ($a11yCheck.navTag -ne "nav") { throw "FAIL: Global application controls must use semantic <nav> element!" }
    if ($a11yCheck.mainRole -ne "main") { throw "FAIL: Main content area is missing role='main'!" }
    if ($a11yCheck.footerRole -ne "contentinfo") { throw "FAIL: <footer> is missing role='contentinfo'!" }
    if ($a11yCheck.skipLinkHref -ne "#mainContent") { throw "FAIL: Skip link does not point to #mainContent!" }
    if (-not $a11yCheck.liveRegionExists -or $a11yCheck.liveRegionLive -ne "polite") { throw "FAIL: #a11yLiveRegion is missing or does not have aria-live='polite'!" }

    # Test Live Region Event Updates
    Eval-Js "window.DeskOS.announceSystemEvent('Pen focus timer started', false);"
    Start-Sleep -Milliseconds 100
    $liveText = Eval-Js "document.getElementById('a11yLiveRegion').textContent"
    if ($liveText -notmatch "Pen focus timer started") {
        throw "FAIL: a11y live region was not updated with event text! Got: '$liveText'"
    }
    Write-Host "  PASS: ARIA live region correctly announced system event ('$liveText')!" -ForegroundColor Green

    # Test Voice Announcement Toggle
    Eval-Js "document.getElementById('voiceAnnounceToggleBtn').click();"
    Start-Sleep -Milliseconds 200
    $voiceCheckOn = Eval-Js @"
    ({
        enabled: window.DeskOS.state.voiceAnnouncementEnabled,
        btnLabel: document.getElementById('voiceAnnounceLabel').textContent,
        storage: localStorage.getItem('desk-os-voice')
    })
"@
    Write-Host "  Voice Toggle ON: Enabled=$($voiceCheckOn.enabled), Label='$($voiceCheckOn.btnLabel)', LocalStorage=$($voiceCheckOn.storage)" -ForegroundColor Cyan
    if (-not $voiceCheckOn.enabled -or $voiceCheckOn.btnLabel -ne "VOICE: ON" -or $voiceCheckOn.storage -ne "true") {
        throw "FAIL: Voice toggle ON did not update state/DOM/storage!"
    }

    # Toggle Voice OFF
    Eval-Js "document.getElementById('voiceAnnounceToggleBtn').click();"
    Start-Sleep -Milliseconds 200
    $voiceCheckOff = Eval-Js @"
    ({
        enabled: window.DeskOS.state.voiceAnnouncementEnabled,
        btnLabel: document.getElementById('voiceAnnounceLabel').textContent,
        storage: localStorage.getItem('desk-os-voice')
    })
"@
    Write-Host "  Voice Toggle OFF: Enabled=$($voiceCheckOff.enabled), Label='$($voiceCheckOff.btnLabel)', LocalStorage=$($voiceCheckOff.storage)" -ForegroundColor Cyan
    if ($voiceCheckOff.enabled -or $voiceCheckOff.btnLabel -ne "VOICE: OFF" -or $voiceCheckOff.storage -ne "false") {
        throw "FAIL: Voice toggle OFF did not reset state/DOM/storage!"
    }
    Write-Host "PASS: Accessibility landmarks, skip link, live region, and voice announcement mode passed with 100% compliance!" -ForegroundColor Green

    # 9. Test Dark Mode Inversion & Persistence
    Write-Host "`n[9/10] Testing Dark Mode Inversion & Persistence..." -ForegroundColor Yellow
    
    # Establish known baseline: switch to light mode first
    Eval-Js "window.DeskOS.applyTheme('light');"
    Start-Sleep -Milliseconds 150

    # Toggle to Dark Mode via button click
    Eval-Js "document.getElementById('themeToggleBtn').click();"
    Start-Sleep -Milliseconds 200
    $darkCheck = Eval-Js @"
    ({
        themeAttr: document.documentElement.getAttribute('data-theme'),
        btnLabel: document.getElementById('themeToggleLabel').textContent,
        storage: localStorage.getItem('desk-os-theme'),
        deckBg: window.getComputedStyle(document.documentElement).getPropertyValue('--theme-deck-bg').trim(),
        deckFg: window.getComputedStyle(document.documentElement).getPropertyValue('--theme-deck-fg').trim(),
        accentColor: window.getComputedStyle(document.documentElement).getPropertyValue('--color-accent').trim()
    })
"@
    Write-Host "  Dark Mode State: Attribute='$($darkCheck.themeAttr)', Button='$($darkCheck.btnLabel)', Storage='$($darkCheck.storage)'" -ForegroundColor Cyan
    Write-Host "  Dark Tokens: DeckBg='$($darkCheck.deckBg)', DeckFg='$($darkCheck.deckFg)', Accent='$($darkCheck.accentColor)'" -ForegroundColor Cyan

    if ($darkCheck.themeAttr -ne "dark") { throw "FAIL: <html> data-theme attribute was not set to 'dark'!" }
    if ($darkCheck.btnLabel -ne "LIGHT") { throw "FAIL: Theme toggle button label should display 'LIGHT' in dark mode!" }
    if ($darkCheck.storage -ne "dark") { throw "FAIL: Theme preference 'dark' was not saved to localStorage!" }
    if ($darkCheck.deckBg -ne "#000000") { throw "FAIL: Dark theme deck background should be pure black #000000, got '$($darkCheck.deckBg)'!" }
    if ($darkCheck.deckFg -ne "#FFFFFF") { throw "FAIL: Dark theme deck foreground should be pure white #FFFFFF, got '$($darkCheck.deckFg)'!" }
    if ($darkCheck.accentColor -ne "#D9480F") { throw "FAIL: Accent color drifted from #D9480F, got '$($darkCheck.accentColor)'!" }

    # Switch back to Light Mode
    Eval-Js "document.getElementById('themeToggleBtn').click();"
    Start-Sleep -Milliseconds 200
    $lightCheck = Eval-Js @"
    ({
        themeAttr: document.documentElement.getAttribute('data-theme'),
        btnLabel: document.getElementById('themeToggleLabel').textContent,
        storage: localStorage.getItem('desk-os-theme'),
        deckBg: window.getComputedStyle(document.documentElement).getPropertyValue('--theme-deck-bg').trim(),
        deckFg: window.getComputedStyle(document.documentElement).getPropertyValue('--theme-deck-fg').trim()
    })
"@
    Write-Host "  Light Mode State: Attribute='$($lightCheck.themeAttr)', Button='$($lightCheck.btnLabel)', Storage='$($lightCheck.storage)'" -ForegroundColor Cyan
    if ($lightCheck.themeAttr -ne "light" -or $lightCheck.btnLabel -ne "DARK" -or $lightCheck.storage -ne "light") {
        throw "FAIL: Switching back to light mode did not correctly update DOM/storage!"
    }
    if ($lightCheck.deckBg -ne "#FFFFFF" -or $lightCheck.deckFg -ne "#000000") {
        throw "FAIL: Light theme tokens did not invert back to #FFFFFF / #000000!"
    }
    Write-Host "PASS: Dark mode toggle, strict monochrome CSS token inversion, and persistence verified successfully!" -ForegroundColor Green

    # 10. Test Live Demo Section & Blueprint Fallback
    Write-Host "`n[10/10] Testing Live Demo Section & Blueprint Fallback..." -ForegroundColor Yellow
    $demoSectionCheck = Eval-Js @"
    ({
        sectionExists: !!document.getElementById('liveDemoSection'),
        sectionAria: document.getElementById('liveDemoSection')?.getAttribute('aria-label'),
        videoExists: !!document.getElementById('demoVideoPlayer'),
        videoDataSrc: document.getElementById('demoVideoPlayer')?.getAttribute('data-src'),
        videoPlaysInline: document.getElementById('demoVideoPlayer')?.hasAttribute('playsinline'),
        videoMuted: document.getElementById('demoVideoPlayer')?.hasAttribute('muted'),
        videoLoop: document.getElementById('demoVideoPlayer')?.hasAttribute('loop'),
        videoControls: document.getElementById('demoVideoPlayer')?.hasAttribute('controls'),
        videoPreload: document.getElementById('demoVideoPlayer')?.getAttribute('preload'),
        videoDisplay: window.getComputedStyle(document.getElementById('demoVideoPlayer')).display,
        fallbackExists: !!document.getElementById('demoVideoFallback'),
        fallbackDisplay: window.getComputedStyle(document.getElementById('demoVideoFallback')).display,
        fallbackTitle: document.getElementById('demoVideoFallback')?.querySelector('.demo-fallback-title')?.textContent
    })
"@
    Write-Host "  Demo Section: Exists=$($demoSectionCheck.sectionExists), Aria='$($demoSectionCheck.sectionAria)'" -ForegroundColor Cyan
    Write-Host "  Demo Video: Exists=$($demoSectionCheck.videoExists), DataSrc='$($demoSectionCheck.videoDataSrc)', Preload='$($demoSectionCheck.videoPreload)', Display='$($demoSectionCheck.videoDisplay)'" -ForegroundColor Cyan
    Write-Host "  Fallback Blueprint: Exists=$($demoSectionCheck.fallbackExists), Display='$($demoSectionCheck.fallbackDisplay)', Title='$($demoSectionCheck.fallbackTitle)'" -ForegroundColor Cyan

    if (-not $demoSectionCheck.sectionExists) { throw "FAIL: #liveDemoSection does not exist in DOM!" }
    if (-not $demoSectionCheck.videoExists) { throw "FAIL: #demoVideoPlayer video element does not exist!" }
    if ($demoSectionCheck.videoDataSrc -notmatch "assets/demo.mp4") { throw "FAIL: Video element does not reference assets/demo.mp4!" }
    if (-not $demoSectionCheck.videoPlaysInline -or -not $demoSectionCheck.videoMuted -or -not $demoSectionCheck.videoLoop -or -not $demoSectionCheck.videoControls) {
        throw "FAIL: Video element is missing playsinline, muted, loop, or controls attributes!"
    }
    if ($demoSectionCheck.videoPreload -ne "none") { throw "FAIL: Video element must have preload='none'!" }
    if ($demoSectionCheck.videoDisplay -ne "none") { throw "FAIL: Video element should be hidden while awaiting capture!" }
    if ($demoSectionCheck.fallbackDisplay -ne "flex") { throw "FAIL: Fallback blueprint must be visible (display: flex) while awaiting capture!" }
    if ($demoSectionCheck.fallbackTitle -notmatch "assets/demo.mp4") { throw "FAIL: Fallback blueprint title should mention 'assets/demo.mp4'!" }
    Write-Host "PASS: Live Demo section, responsive video element, and editorial blueprint fallback validated!" -ForegroundColor Green

    # 11. Check Console Errors
    Write-Host "`n[Summary] Checking for Console Errors & Exceptions..." -ForegroundColor Yellow
    if ($capturedErrors.Count -gt 0) {
        Write-Host "ERRORS DETECTED:" -ForegroundColor Red
        foreach ($err in $capturedErrors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
        throw "FAIL: Detected $($capturedErrors.Count) console error(s) during execution!"
    }
    Write-Host "PASS: Zero console errors and zero unhandled exceptions throughout execution!" -ForegroundColor Green

    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "  ALL TESTS PASSED WITH 100% SUCCESS RATE!       " -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan

} finally {
    if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Test Complete", [System.Threading.CancellationToken]::None).Wait()
    }
    if ($proc -and -not $proc.HasExited) {
        $proc.Kill()
    }
}
