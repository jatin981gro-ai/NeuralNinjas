# Desk-OS Multi-Breakpoint Responsive & Touch Target Verification Suite
# Tests 375px, 428px, 768px, 1024px, and 1280px via Chrome DevTools Protocol

$ErrorActionPreference = "Stop"
$DebugPort = 9226
$TargetUrl = "http://localhost:8000/"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "   Desk-OS Mobile & Laptop Responsive Suite      " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. Verify Viewport Meta Tag
Write-Host "`n[1/6] Verifying Viewport Meta Tag..." -ForegroundColor Yellow
$htmlContent = Get-Content "index.html" -Raw
if ($htmlContent -notmatch '<meta\s+name=["'']viewport["'']\s+content=["'']width=device-width,\s*initial-scale=1') {
    throw "FAIL: <meta name='viewport' content='width=device-width, initial-scale=1'> not found in index.html!"
}
Write-Host "PASS: Viewport meta tag is present and configured correctly!" -ForegroundColor Green

# 2. Launch Chrome with Fake Video and Remote Debugging
Write-Host "`n[2/6] Launching Chrome Headless for Multi-Viewport Testing..." -ForegroundColor Yellow
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$userDir = Join-Path $env:TEMP "desk-os-responsive-test-profile"
if (Test-Path $userDir) { Remove-Item -Recurse -Force $userDir -ErrorAction SilentlyContinue }

$chromeProc = Start-Process -FilePath $chromePath -ArgumentList @(
    "--remote-debugging-port=$DebugPort",
    "--headless=new",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--window-size=1280,800",
    "--user-data-dir=$userDir",
    $TargetUrl
) -PassThru

try {
    Start-Sleep -Seconds 2
    $pageList = (Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json")
    $page = $pageList | Where-Object { $_.type -eq "page" -and $_.url -match "8000" } | Select-Object -First 1
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
        $resp = Read-CdpResponse $reqId 12000
        if ($resp.result.exceptionDetails) {
            throw "Evaluation error: $($resp.result.exceptionDetails | ConvertTo-Json -Depth 3)"
        }
        return $resp.result.result.value
    }

    function Set-Viewport([int]$width, [int]$height, [double]$deviceScaleFactor = 1.0, [bool]$mobile = $false) {
        $reqId = Send-Cdp "Emulation.setDeviceMetricsOverride" @{
            width = $width
            height = $height
            deviceScaleFactor = $deviceScaleFactor
            mobile = $mobile
        }
        $null = Read-CdpResponse $reqId 5000
        Start-Sleep -Milliseconds 400
    }

    $null = Send-Cdp "Runtime.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 2000
    $null = Send-Cdp "Log.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 2000

    Write-Host "Waiting for DeskOS engine to bootstrap..." -ForegroundColor Yellow
    $booted = $false
    $bootRetries = 25
    while ($bootRetries -gt 0 -and -not $booted) {
        Start-Sleep -Milliseconds 300
        try {
            $isDefined = Eval-Js "typeof window.DeskOS !== 'undefined'"
            if ($isDefined) { $booted = $true }
        } catch {
            $bootRetries--
        }
    }
    if (-not $booted) { throw "Timeout waiting for DeskOS to bootstrap!" }
    Write-Host "DeskOS Engine bootstrapped successfully!" -ForegroundColor Green

    # 3. Test Multi-Breakpoint Layout Reflow & Zero Horizontal Overflow
    Write-Host "`n[3/6] Auditing Breakpoints for Overflow and Layout Reflow..." -ForegroundColor Yellow
    $testBreakpoints = @(
        @{ name = "Small Phone (iPhone SE)"; width = 375; height = 667; mobile = $true; shouldStack = $true },
        @{ name = "Large Phone (iPhone 14 Pro Max)"; width = 428; height = 926; mobile = $true; shouldStack = $true },
        @{ name = "Tablet (iPad Mini)"; width = 768; height = 1024; mobile = $true; shouldStack = $true },
        @{ name = "Tablet Landscape / Small Laptop"; width = 1024; height = 768; mobile = $false; shouldStack = $true },
        @{ name = "Laptop / Desktop (Standard)"; width = 1280; height = 800; mobile = $false; shouldStack = $false }
    )

    foreach ($bp in $testBreakpoints) {
        Write-Host "  -> Testing $($bp.name) [Width: $($bp.width)px]..." -ForegroundColor Cyan
        Set-Viewport $bp.width $bp.height 2.0 $bp.mobile

        $metrics = Eval-Js @'
        (() => {
            const doc = document.documentElement;
            const scrollW = doc.scrollWidth;
            const clientW = doc.clientWidth;
            const hasHOverflow = scrollW > clientW + 1;

            const main = document.querySelector('main');
            const mainStyle = window.getComputedStyle(main);
            const gridCols = mainStyle.gridTemplateColumns;
            const isStacked = gridCols.split(' ').length === 1;

            const viewportCol = document.getElementById('howItWorks');
            const panelCol = document.getElementById('features');
            const vpRect = viewportCol.getBoundingClientRect();
            const panelRect = panelCol.getBoundingClientRect();
            const panelBelowViewport = panelRect.top >= vpRect.bottom - 10;

            const video = document.getElementById('webcamVideo');
            const feedWrapper = document.getElementById('feedContainer');
            const demoWrapper = document.querySelector('.demo-media-wrapper');

            const videoOverflow = video ? video.offsetWidth > feedWrapper.offsetWidth + 2 : false;
            const feedOverflow = feedWrapper ? feedWrapper.offsetWidth > doc.clientWidth : false;
            const demoOverflow = demoWrapper ? demoWrapper.offsetWidth > doc.clientWidth : false;

            return {
                scrollW,
                clientW,
                hasHOverflow,
                isStacked,
                panelBelowViewport,
                videoOverflow,
                feedOverflow,
                demoOverflow
            };
        })()
'@

        if ($metrics.hasHOverflow) {
            throw "FAIL on $($bp.name): Horizontal scrollbar detected! scrollWidth=$($metrics.scrollW) > clientWidth=$($metrics.clientW)"
        }
        if ($metrics.videoOverflow -or $metrics.feedOverflow -or $metrics.demoOverflow) {
            throw "FAIL on $($bp.name): Media elements overflow container!"
        }

        if ($bp.shouldStack) {
            if (-not $metrics.isStacked) {
                throw "FAIL on $($bp.name): Expected stacked 1-column layout, but found multi-column grid!"
            }
            if (-not $metrics.panelBelowViewport) {
                throw "FAIL on $($bp.name): Expected AR Node panel to stack cleanly BELOW camera viewport!"
            }
        } else {
            if ($metrics.isStacked) {
                throw "FAIL on $($bp.name): Expected side-by-side layout on desktop width ($($bp.width)px)!"
            }
        }

        Write-Host "     PASS: Zero horizontal scroll (scrollW: $($metrics.scrollW)px == clientW: $($metrics.clientW)px), stacked=$($metrics.isStacked)" -ForegroundColor Green
    }

    # 4. Test Touch Target Sizes (Minimum 44x44px on Mobile <= 768px)
    Write-Host "`n[4/6] Auditing Touch Targets (Minimum 44x44px on Mobile Viewports)..." -ForegroundColor Yellow
    Set-Viewport 375 667 2.0 $true

    $touchTargets = Eval-Js @'
    (() => {
        const results = [];

        function checkTarget(el, name, minH = 44, minW = 44) {
            if (!el) return;
            const rect = el.getBoundingClientRect();
            const isVisible = rect.width > 0 && rect.height > 0 && window.getComputedStyle(el).display !== 'none';
            if (!isVisible) return;
            results.push({
                name,
                width: Math.round(rect.width * 10) / 10,
                height: Math.round(rect.height * 10) / 10,
                pass: rect.height >= (minH - 1) && rect.width >= (minW - 1)
            });
        }

        // Header controls
        checkTarget(document.getElementById('mobileMenuBtn'), 'Mobile Menu Button');
        checkTarget(document.getElementById('themeToggleBtn'), 'Theme Toggle Button');
        checkTarget(document.querySelector('.nav-cta-btn'), 'Watch Demo CTA Button', 44, 44);

        // Utility strip controls
        checkTarget(document.getElementById('demoModeBtn'), 'Demo Mode Button', 44, 44);
        checkTarget(document.getElementById('resetDemoBtn'), 'Reset Demo Button', 44, 44);
        checkTarget(document.getElementById('voiceAnnounceToggleBtn'), 'Voice Toggle Button', 44, 44);
        checkTarget(document.getElementById('sfxToggleBtn'), 'SFX Toggle Button', 44, 44);
        checkTarget(document.getElementById('settingsBtn'), 'Settings Button', 44, 44);

        // Viewport controls
        checkTarget(document.getElementById('feedWebcamBtn'), 'Live Webcam Switch Button', 44, 44);
        checkTarget(document.getElementById('feedVirtualBtn'), 'Virtual Desk Switch Button', 44, 44);

        // Pen timer buttons
        checkTarget(document.getElementById('timerToggleBtn'), 'Timer Start/Pause Button', 44, 44);
        checkTarget(document.getElementById('timerResetBtn'), 'Timer Reset Button', 44, 44);

        // Navigation links inside open mobile menu
        const menuBtn = document.getElementById('mobileMenuBtn');
        const siteNav = document.getElementById('siteNav');
        siteNav.classList.add('is-open');
        const navLinks = document.querySelectorAll('.site-nav-link');
        navLinks.forEach((link, idx) => {
            checkTarget(link, `Mobile Nav Link: ${link.textContent.trim()}`, 44, 44);
        });
        siteNav.classList.remove('is-open');

        // Footer links
        const footerLinks = document.querySelectorAll('.footer-link');
        footerLinks.forEach((link, idx) => {
            checkTarget(link, `Footer Link: ${link.textContent.trim()}`, 44, 44);
        });

        return results;
    })()
'@

    foreach ($tt in $touchTargets) {
        Write-Host "  -> $($tt.name): $($tt.width)x$($tt.height)px (Pass: $($tt.pass))" -ForegroundColor Cyan
        if (-not $tt.pass) {
            throw "FAIL: Touch target $($tt.name) is too small: $($tt.width)x$($tt.height)px (Minimum 44x44px required)!"
        }
    }
    Write-Host "PASS: All inspected interactive controls satisfy minimum 44x44px touch target!" -ForegroundColor Green

    # 5. Verify Hardware Camera Advisory Notice
    Write-Host "`n[5/6] Verifying Hardware Camera Advisory Notice (Step 7)..." -ForegroundColor Yellow
    $noticeData = Eval-Js @'
    (() => {
        const notice = document.getElementById('hardwareNotice');
        if (!notice) return null;
        const text = notice.textContent.trim();
        const isVisible = window.getComputedStyle(notice).display !== 'none';
        const isModal = window.getComputedStyle(notice).position === 'fixed';
        return {
            exists: true,
            text,
            isVisible,
            isModal
        };
    })()
'@

    if (-not $noticeData.exists -or -not $noticeData.isVisible) {
        throw "FAIL: Hardware camera advisory notice (#hardwareNotice) not visible in UI!"
    }
    if ($noticeData.isModal) {
        throw "FAIL: Hardware advisory should be an inline informative note, not a blocking modal!"
    }
    Write-Host "  Advisory Text: '$($noticeData.text)'" -ForegroundColor Cyan
    Write-Host "PASS: Non-blocking hardware performance notice is present and properly placed!" -ForegroundColor Green

    # 6. Verify Mobile Menu Interactive Toggle at 375px
    Write-Host "`n[6/6] Testing Mobile Menu Toggle at 375px Viewport..." -ForegroundColor Yellow
    $menuTest = Eval-Js @'
    (() => {
        const menuBtn = document.getElementById('mobileMenuBtn');
        const siteNav = document.getElementById('siteNav');
        const initialOpen = siteNav.classList.contains('is-open');

        menuBtn.click();
        const opened = siteNav.classList.contains('is-open');
        const openedExpanded = menuBtn.getAttribute('aria-expanded');

        menuBtn.click();
        const closed = !siteNav.classList.contains('is-open');

        return {
            initialOpen,
            opened,
            openedExpanded,
            closed
        };
    })()
'@

    if ($menuTest.initialOpen -or -not $menuTest.opened -or $menuTest.openedExpanded -ne "true" -or -not $menuTest.closed) {
        throw "FAIL: Mobile menu failed toggle test: initialOpen=$($menuTest.initialOpen), opened=$($menuTest.opened), closed=$($menuTest.closed)"
    }
    Write-Host "PASS: Mobile menu opens, manages aria-expanded, and closes cleanly!" -ForegroundColor Green

    # Summary Check for Console Errors
    Write-Host "`n[Summary] Checking Console Errors..." -ForegroundColor Yellow
    if ($capturedErrors.Count -gt 0) {
        throw "FAIL: Captured console errors during responsive suite:`n$($capturedErrors -join "`n")"
    }
    Write-Host "PASS: Zero console errors throughout execution!" -ForegroundColor Green

    Write-Host "`n=================================================" -ForegroundColor Green
    Write-Host "   RESPONSIVE DESIGN SUITE PASSED (100%)         " -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green

} finally {
    if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [System.Threading.CancellationToken]::None).Wait()
    }
    if ($chromeProc -and -not $chromeProc.HasExited) {
        Stop-Process -Id $chromeProc.Id -Force -ErrorAction SilentlyContinue
    }
}
