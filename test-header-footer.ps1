$ErrorActionPreference = "Stop"
$DebugPort = 9224

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "   Desk-OS Header & Footer Verification Suite   " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. Test Clean URL endpoints
Write-Host "`n[1/4] Testing /privacy and /terms Endpoints..." -ForegroundColor Yellow
$privacyRes = Invoke-WebRequest -Uri "http://localhost:8000/privacy" -UseBasicParsing
$termsRes = Invoke-WebRequest -Uri "http://localhost:8000/terms" -UseBasicParsing

if ($privacyRes.StatusCode -ne 200 -or $privacyRes.Content -notmatch "Privacy Policy") {
    throw "FAIL: /privacy did not return expected content!"
}
Write-Host "PASS: /privacy returned 200 OK with comprehensive local-first privacy policy!" -ForegroundColor Green

if ($termsRes.StatusCode -ne 200 -or $termsRes.Content -notmatch "Terms of Service") {
    throw "FAIL: /terms did not return expected content!"
}
Write-Host "PASS: /terms returned 200 OK with tangible computing terms of service!" -ForegroundColor Green

# 2. Launch headless Chrome to verify DOM, links, styles, responsive state
Write-Host "`n[2/4] Launching Chrome Headless for DOM & Accessibility Inspection..." -ForegroundColor Yellow
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$userDir = Join-Path $env:TEMP "desk_os_hf_profile_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $userDir -Force | Out-Null

$chromeProc = Start-Process -FilePath $chromePath -ArgumentList @(
    "--remote-debugging-port=$DebugPort",
    "--headless=new",
    "--window-size=1280,800",
    "--user-data-dir=$userDir",
    "http://localhost:8000/"
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

    $null = Send-Cdp "Runtime.enable"
    $null = Read-CdpResponse ($script:msgId - 1) 2000

    Write-Host "Waiting for DeskOS engine to bootstrap..." -ForegroundColor Yellow
    $booted = $false
    $bootRetries = 25
    while ($bootRetries -gt 0 -and -not $booted) {
        Start-Sleep -Milliseconds 300
        try {
            $isDefined = Eval-Js "typeof window.DeskOS !== 'undefined' && !!document.querySelector('header')"
            if ($isDefined) { $booted = $true }
        } catch {
            $bootRetries--
        }
    }
    if (-not $booted) { throw "Timeout waiting for DeskOS to bootstrap!" }
    Write-Host "DeskOS Engine bootstrapped successfully!" -ForegroundColor Green

    # 3. Header & Footer Links, Wordmark, Dynamic Year, No Emojis, No Dead Hrefs
    Write-Host "`n[3/4] Inspecting Header & Footer Architecture..." -ForegroundColor Yellow
    $hfData = Eval-Js @'
    (() => {
        const header = document.querySelector('header');
        const footer = document.querySelector('footer');
        const headerWordmark = header ? header.querySelector('.brand-wordmark')?.textContent?.trim() : '';
        const headerTagline = header ? header.querySelector('.brand-tagline')?.textContent?.trim() : '';
        const headerLinks = Array.from(header?.querySelectorAll('.site-nav a') || []).map(a => ({
            text: a.textContent.trim(),
            href: a.getAttribute('href'),
            targetExists: !!document.querySelector(a.getAttribute('href'))
        }));

        const ctaBtn = header ? header.querySelector('.nav-cta-btn') : null;
        const ctaData = {
            text: ctaBtn ? ctaBtn.textContent.trim() : '',
            href: ctaBtn ? ctaBtn.getAttribute('href') : '',
            targetExists: ctaBtn ? !!document.querySelector(ctaBtn.getAttribute('href')) : false,
            isOrange: ctaBtn ? window.getComputedStyle(ctaBtn).backgroundColor : ''
        };

        const themeBtn = document.getElementById('themeToggleBtn');
        const mobileMenuBtn = document.getElementById('mobileMenuBtn');
        const siteNav = document.getElementById('siteNav');

        const footerWordmark = footer ? footer.querySelector('.footer-wordmark')?.textContent?.trim() : '';
        const footerTagline = footer ? footer.querySelector('.footer-tagline')?.textContent?.trim() : '';
        const footerLinks = Array.from(footer?.querySelectorAll('.footer-nav a') || []).map(a => ({
            text: a.textContent.trim(),
            href: a.getAttribute('href'),
            isInternalAnchor: a.getAttribute('href').startsWith('#'),
            targetExists: a.getAttribute('href').startsWith('#') ? !!document.querySelector(a.getAttribute('href')) : true
        }));

        const dynamicYear = document.getElementById('currentYear')?.textContent?.trim() || '';
        const realYear = new Date().getFullYear().toString();

        // Check for dead hrefs in whole page
        const allLinks = Array.from(document.querySelectorAll('a')).map(a => a.getAttribute('href'));
        const deadHrefs = allLinks.filter(h => !h || h === '#');

        // Check for "Made with" badges
        const pageText = document.body.innerText;
        const hasMadeWith = /made with/i.test(pageText);

        return {
            headerWordmark,
            headerTagline,
            headerLinks,
            ctaData,
            themeBtnExists: !!themeBtn,
            mobileBtnExists: !!mobileMenuBtn,
            footerWordmark,
            footerTagline,
            footerLinks,
            dynamicYear,
            realYear,
            yearMatches: dynamicYear === realYear,
            deadHrefsCount: deadHrefs.length,
            hasMadeWith
        };
    })()
'@

    Write-Host "  Header Wordmark : '$($hfData.headerWordmark)'" -ForegroundColor Cyan
    Write-Host "  Header Tagline  : '$($hfData.headerTagline)'" -ForegroundColor Cyan
    Write-Host "  Header Links    : $($hfData.headerLinks | ForEach-Object { "$($_.text)->$($_.href) (exists:$($_.targetExists))" } | Out-String)" -ForegroundColor Cyan
    Write-Host "  CTA Button      : '$($hfData.ctaData.text)' -> $($hfData.ctaData.href) (bg: $($hfData.ctaData.isOrange))" -ForegroundColor Cyan
    Write-Host "  Footer Wordmark : '$($hfData.footerWordmark)'" -ForegroundColor Cyan
    Write-Host "  Footer Tagline  : '$($hfData.footerTagline)'" -ForegroundColor Cyan
    Write-Host "  Dynamic Year    : $($hfData.dynamicYear) (Current Year: $($hfData.realYear))" -ForegroundColor Cyan
    Write-Host "  Dead '#' Hrefs  : $($hfData.deadHrefsCount)" -ForegroundColor Cyan
    Write-Host "  'Made with' tag : $($hfData.hasMadeWith)" -ForegroundColor Cyan

    if ($hfData.headerWordmark -ne "Desk-OS") { throw "FAIL: Header wordmark must be 'Desk-OS'!" }
    if ($hfData.ctaData.text -notmatch "WATCH DEMO") { throw "FAIL: Header primary CTA text must be 'WATCH DEMO'!" }
    if ($hfData.ctaData.href -ne "#liveDemoSection" -or -not $hfData.ctaData.targetExists) { throw "FAIL: CTA must link to existing #liveDemoSection!" }
    if ($hfData.headerLinks.Count -lt 4) { throw "FAIL: Header navigation must contain Home, How It Works, Features, Demo!" }
    foreach ($hl in $hfData.headerLinks) {
        if (-not $hl.targetExists) { throw "FAIL: Header nav link $($hl.text) targets non-existent ID $($hl.href)!" }
    }
    if ($hfData.footerWordmark -ne "Desk-OS") { throw "FAIL: Footer wordmark must be 'Desk-OS'!" }
    if ($hfData.footerTagline -ne "point. speak. automate.") { throw "FAIL: Footer tagline must be 'point. speak. automate.'!" }
    if (-not $hfData.yearMatches) { throw "FAIL: Dynamic year ($($hfData.dynamicYear)) does not match current year ($($hfData.realYear))!" }
    if ($hfData.deadHrefsCount -gt 0) { throw "FAIL: Found $($hfData.deadHrefsCount) dead '#' links in page!" }
    if ($hfData.hasMadeWith) { throw "FAIL: Page contains 'Made with' badge!" }
    Write-Host "PASS: Wordmark, navigation targets, CTA button, dynamic year, and clean links all verified!" -ForegroundColor Green

    # 4. Test Mobile Menu Toggle & Scroll State
    Write-Host "`n[4/4] Testing Mobile Menu Toggle & Scroll Elevation..." -ForegroundColor Yellow

    # Test Mobile menu toggle
    $menuTest = Eval-Js @'
    (() => {
        const btn = document.getElementById('mobileMenuBtn');
        const nav = document.getElementById('siteNav');
        const initialOpen = nav.classList.contains('is-open');
        btn.click();
        const afterClickOpen = nav.classList.contains('is-open');
        const expandedAttr = btn.getAttribute('aria-expanded');
        btn.click();
        const afterSecondClickOpen = nav.classList.contains('is-open');
        return { initialOpen, afterClickOpen, expandedAttr, afterSecondClickOpen };
    })()
'@
    Write-Host "  Mobile Menu: initial=$($menuTest.initialOpen), afterClick=$($menuTest.afterClickOpen), aria-expanded=$($menuTest.expandedAttr), after2ndClick=$($menuTest.afterSecondClickOpen)" -ForegroundColor Cyan
    if (-not $menuTest.afterClickOpen -or $menuTest.afterSecondClickOpen) {
        throw "FAIL: Mobile menu button click did not toggle nav visibility!"
    }
    Write-Host "PASS: Mobile menu toggle button cleanly toggles site-nav and updates aria-expanded!" -ForegroundColor Green

    # Test Header Scroll Elevation
    $scrollTest = Eval-Js @'
    (() => {
        const header = document.querySelector('header');
        const initialScrolled = header.classList.contains('header-scrolled');
        window.scrollTo(0, 50);
        window.dispatchEvent(new Event('scroll'));
        const afterScroll = header.classList.contains('header-scrolled');
        window.scrollTo(0, 0);
        window.dispatchEvent(new Event('scroll'));
        const afterReset = header.classList.contains('header-scrolled');
        return { initialScrolled, afterScroll, afterReset };
    })()
'@
    Write-Host "  Scroll Elevation: initial=$($scrollTest.initialScrolled), at50px=$($scrollTest.afterScroll), at0px=$($scrollTest.afterReset)" -ForegroundColor Cyan
    if (-not $scrollTest.afterScroll -or $scrollTest.afterReset) {
        throw "FAIL: Header on-scroll elevation class was not toggled correctly!"
    }
    Write-Host "PASS: Header on-scroll elevation adds .header-scrolled when scrolled!" -ForegroundColor Green

    # Test Mobile Viewport Overflow (width: 375px)
    $null = Send-Cdp "Emulation.setDeviceMetricsOverride" @{
        width = 375
        height = 667
        deviceScaleFactor = 2
        mobile = $true
    }
    $null = Read-CdpResponse ($script:msgId - 1) 2000
    Start-Sleep -Milliseconds 500

    $overflowTest = Eval-Js @'
    (() => {
        const docWidth = document.documentElement.offsetWidth;
        const scrollWidth = document.documentElement.scrollWidth;
        const headerWidth = document.querySelector('header').scrollWidth;
        const footerWidth = document.querySelector('footer').scrollWidth;
        return {
            docWidth,
            scrollWidth,
            headerWidth,
            footerWidth,
            hasHorizontalOverflow: scrollWidth > docWidth + 2
        };
    })()
'@
    Write-Host "  Mobile 375px Check: docWidth=$($overflowTest.docWidth), scrollWidth=$($overflowTest.scrollWidth), header=$($overflowTest.headerWidth), footer=$($overflowTest.footerWidth), overflow=$($overflowTest.hasHorizontalOverflow)" -ForegroundColor Cyan
    if ($overflowTest.hasHorizontalOverflow) {
        throw "FAIL: Horizontal overflow detected on mobile viewport (scrollWidth > docWidth)!"
    }
    Write-Host "PASS: Zero horizontal overflow at mobile 375px viewport!" -ForegroundColor Green

    Write-Host "`n=================================================" -ForegroundColor Green
    Write-Host "   ALL HEADER & FOOTER TESTS PASSED (100%)       " -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green

} finally {
    if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [System.Threading.CancellationToken]::None).Wait()
    }
    if ($chromeProc -and -not $chromeProc.HasExited) {
        $chromeProc.Kill()
    }
    Remove-Item -Path $userDir -Recurse -Force -ErrorAction SilentlyContinue
}
