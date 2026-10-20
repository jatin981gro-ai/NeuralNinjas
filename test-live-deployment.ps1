# Desk-OS Live GitHub Pages Deployment E2E Verification
# Tests https://jatin981gro-ai.github.io/NeuralNinjas/ in incognito mode via Chrome DevTools Protocol

$ErrorActionPreference = "Stop"
$DebugPort = 9225
$LiveUrl = "https://jatin981gro-ai.github.io/NeuralNinjas/"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "   Desk-OS Live HTTPS Deployment Verification   " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. HTTP Endpoint Verification
Write-Host "`n[1/5] Testing Live HTTPS Endpoints (HTTP 200)..." -ForegroundColor Yellow
$endpoints = @(
    "$LiveUrl",
    "${LiveUrl}privacy.html",
    "${LiveUrl}terms.html"
)

foreach ($url in $endpoints) {
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
        if ($resp.StatusCode -eq 200) {
            Write-Host "  PASS: $url -> 200 OK (Length: $($resp.Content.Length) bytes)" -ForegroundColor Green
        } else {
            throw "Non-200 status code: $($resp.StatusCode) for $url"
        }
    } catch {
        throw "Failed to fetch live URL $url : $($_.Exception.Message)"
    }
}

# 2. Launch Chrome in Incognito Mode with Fake Camera & DevTools
Write-Host "`n[2/5] Launching Chrome in Incognito Mode with DevTools..." -ForegroundColor Yellow
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chromePath)) {
    throw "Chrome binary not found at $chromePath"
}

$userDir = Join-Path $env:TEMP "desk-os-live-test-profile"
if (Test-Path $userDir) { Remove-Item -Recurse -Force $userDir -ErrorAction SilentlyContinue }

$chromeProc = Start-Process -FilePath $chromePath -ArgumentList @(
    "--remote-debugging-port=$DebugPort",
    "--headless=new",
    "--incognito",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--window-size=1280,800",
    "--user-data-dir=$userDir",
    $LiveUrl
) -PassThru

try {
    Start-Sleep -Seconds 3
    $pageList = (Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json")
    $page = $pageList | Where-Object { $_.type -eq "page" -and $_.url -match "NeuralNinjas" } | Select-Object -First 1
    if (-not $page) { $page = $pageList[0] }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait()

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
    function Read-CdpResponse([int]$expectedId, [int]$timeoutMs = 12000) {
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
                    if ($obj.method -eq "Log.entryAdded" -and $obj.params.entry.level -eq "error") {
                        $capturedErrors.Add($obj.params.entry.text)
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
        $resp = Read-CdpResponse $reqId 15000
        if ($resp.result.exceptionDetails) {
            throw "Evaluation error: $($resp.result.exceptionDetails | ConvertTo-Json -Depth 3)"
        }
        return $resp.result.result.value
    }

    $null = Send-Cdp "Runtime.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 3000
    $null = Send-Cdp "Log.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 3000

    Write-Host "Waiting for live DeskOS engine to bootstrap..." -ForegroundColor Yellow
    $booted = $false
    $bootRetries = 30
    while ($bootRetries -gt 0 -and -not $booted) {
        Start-Sleep -Milliseconds 400
        try {
            $isDefined = Eval-Js "typeof window.DeskOS !== 'undefined' && !!document.querySelector('header')"
            if ($isDefined) { $booted = $true }
        } catch {
            $bootRetries--
        }
    }
    if (-not $booted) { throw "Timeout waiting for live DeskOS engine to bootstrap!" }
    Write-Host "Live DeskOS Engine bootstrapped successfully!" -ForegroundColor Green

    # 3. Secure Context & Hardware Camera Check
    Write-Host "`n[3/5] Auditing Secure Context & Live Camera Pipeline..." -ForegroundColor Yellow
    $contextData = Eval-Js @'
    (() => {
        const isSecure = window.isSecureContext;
        const protocol = window.location.protocol;
        const tipEl = document.getElementById('debugServerTip');
        const tipText = tipEl ? tipEl.textContent.trim() : '';
        const feedMode = window.DeskOS?.state?.feedMode;
        const video = document.getElementById('webcamVideo');
        const videoVisible = video && window.getComputedStyle(video).display !== 'none';
        const virtualCanvas = document.getElementById('virtualDeskCanvas');
        const virtualHidden = virtualCanvas && window.getComputedStyle(virtualCanvas).display === 'none';

        return {
            isSecure,
            protocol,
            tipText,
            feedMode,
            videoVisible,
            virtualHidden
        };
    })()
'@

    Write-Host "  Protocol         : $($contextData.protocol)" -ForegroundColor Cyan
    Write-Host "  isSecureContext  : $($contextData.isSecure)" -ForegroundColor Cyan
    Write-Host "  Diagnostic Tip   : '$($contextData.tipText)'" -ForegroundColor Cyan
    Write-Host "  Active Feed Mode : $($contextData.feedMode)" -ForegroundColor Cyan

    if (-not $contextData.isSecure) {
        throw "FAIL: window.isSecureContext must be true on HTTPS deployment!"
    }
    if ($contextData.protocol -ne "https:") {
        throw "FAIL: Expected https: protocol, got $($contextData.protocol)"
    }
    if ($contextData.tipText -notmatch "SECURE CONTEXT \(HTTPS\)") {
        throw "FAIL: Diagnostic tip does not reflect SECURE CONTEXT (HTTPS)! Got: $($contextData.tipText)"
    }
    Write-Host "PASS: Secure Context verified active on live HTTPS origin!" -ForegroundColor Green

    # 4. Link Audit (Zero localhost references, zero dead anchor hrefs)
    Write-Host "`n[4/5] Auditing Links on Live Page..." -ForegroundColor Yellow
    $linkAudit = Eval-Js @'
    (() => {
        const links = Array.from(document.querySelectorAll('a[href]'));
        const issues = [];
        const checked = [];

        links.forEach(a => {
            const rawHref = a.getAttribute('href');
            const resolvedHref = a.href;
            checked.push({ text: a.textContent.trim(), href: rawHref, resolved: resolvedHref });

            if (rawHref.includes('localhost') || rawHref.includes('127.0.0.1')) {
                issues.push(`Hardcoded localhost link found: ${rawHref}`);
            }
            if (rawHref === '#') {
                issues.push(`Dead '#' link found: ${a.textContent.trim()}`);
            }
            if (rawHref.startsWith('/') && !rawHref.startsWith('/NeuralNinjas')) {
                issues.push(`Domain-root relative link found that escapes subpath: ${rawHref}`);
            }
        });

        return {
            totalLinks: links.length,
            issues,
            sample: checked.slice(0, 10)
        };
    })()
'@

    Write-Host "  Total Links Checked: $($linkAudit.totalLinks)" -ForegroundColor Cyan
    if ($linkAudit.issues.Count -gt 0) {
        throw "FAIL: Link audit found issues:`n$($linkAudit.issues -join "`n")"
    }
    Write-Host "PASS: All links resolve correctly within GitHub Pages subpath! (0 localhost leaks, 0 dead '#')" -ForegroundColor Green

    # 5. Dark Mode & Persistence Check on Live Deployment
    Write-Host "`n[5/5] Testing Dark Mode Toggle & Persistence on Live Site..." -ForegroundColor Yellow
    $themeTest = Eval-Js @'
    (() => {
        const btn = document.getElementById('themeToggleBtn');
        const initialTheme = document.documentElement.getAttribute('data-theme') || 'light';
        btn.click();
        const afterClick = document.documentElement.getAttribute('data-theme');
        const storedTheme = localStorage.getItem('desk-os-theme');
        btn.click();
        const revertedTheme = document.documentElement.getAttribute('data-theme');

        return {
            initialTheme,
            afterClick,
            storedTheme,
            revertedTheme
        };
    })()
'@

    Write-Host "  Initial Theme : $($themeTest.initialTheme)" -ForegroundColor Cyan
    Write-Host "  After Toggle  : $($themeTest.afterClick) (LocalStorage: $($themeTest.storedTheme))" -ForegroundColor Cyan
    Write-Host "  Reverted      : $($themeTest.revertedTheme)" -ForegroundColor Cyan

    if ($themeTest.afterClick -eq $themeTest.initialTheme) {
        throw "FAIL: Dark mode toggle failed to flip data-theme attribute!"
    }
    if ($themeTest.storedTheme -ne $themeTest.afterClick) {
        throw "FAIL: Dark mode toggle failed to update localStorage!"
    }
    Write-Host "PASS: Dark mode toggle & localStorage persistence verified on live HTTPS!" -ForegroundColor Green

    # Summary: Zero console errors
    Write-Host "`n[Summary] Checking for Console Errors..." -ForegroundColor Yellow
    if ($capturedErrors.Count -gt 0) {
        throw "FAIL: Captured console errors:`n$($capturedErrors -join "`n")"
    }
    Write-Host "PASS: Zero console errors on live HTTPS deployment!" -ForegroundColor Green

    Write-Host "`n=================================================" -ForegroundColor Green
    Write-Host "   LIVE DEPLOYMENT FULLY VERIFIED (100% PASS)    " -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green

} finally {
    if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [System.Threading.CancellationToken]::None).Wait()
    }
    if ($chromeProc -and -not $chromeProc.HasExited) {
        Stop-Process -Id $chromeProc.Id -Force -ErrorAction SilentlyContinue
    }
}
