$ErrorActionPreference = "Stop"
$DebugPort = 9226

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "     Desk-OS Typography System Verification      " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$userDir = Join-Path $env:TEMP "desk_os_typo_profile_$([guid]::NewGuid().ToString('N'))"
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
        $cmdObj = @{ id = $id; method = $method; params = $params }
        $json = $cmdObj | ConvertTo-Json -Compress -Depth 10
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        return $id
    }

    $pendingResponses = [System.Collections.Generic.Dictionary[int, object]]::new()
    function Read-CdpResponse([int]$expectedId, [int]$timeoutMs = 10000) {
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
                } catch { break } finally { $cts.Dispose() }
            } while ($res -and -not $res.EndOfMessage)

            if ($mem.Length -gt 0) {
                $str = [System.Text.Encoding]::UTF8.GetString($mem.ToArray())
                try {
                    $obj = $str | ConvertFrom-Json
                    if ($null -ne $obj.id) {
                        if ($obj.id -eq $expectedId) { return $obj }
                        else { $pendingResponses[$obj.id] = $obj }
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

    # Wait for web fonts to load
    Write-Host "`n[1/4] Checking Google Fonts Loading Status..." -ForegroundColor Yellow
    $fontStatus = Eval-Js @'
    (async () => {
        try {
            await document.fonts.ready;
            const fontsLoaded = [];
            for (const font of document.fonts) {
                fontsLoaded.push({
                    family: font.family,
                    weight: font.weight,
                    status: font.status
                });
            }
            return {
                ready: true,
                count: fontsLoaded.length,
                fonts: fontsLoaded,
                hasSpaceGrotesk: document.fonts.check('700 16px "Space Grotesk"') || Array.from(document.fonts).some(f => f.family.includes('Space Grotesk') && f.status === 'loaded'),
                hasIBMPlexSans: document.fonts.check('16px "IBM Plex Sans"') || Array.from(document.fonts).some(f => f.family.includes('IBM Plex Sans') && f.status === 'loaded')
            };
        } catch(e) {
            return { error: e.message };
        }
    })()
'@

    Write-Host "  document.fonts.ready   : $($fontStatus.ready)" -ForegroundColor Cyan
    Write-Host "  Loaded Font Count      : $($fontStatus.count)" -ForegroundColor Cyan
    Write-Host "  Font Families Present  : $(($fontStatus.fonts | ForEach-Object { "$($_.family):$($_.weight):$($_.status)" } | Select-Object -Unique) -join ', ')" -ForegroundColor Cyan
    Write-Host "  'Space Grotesk' Active : $($fontStatus.hasSpaceGrotesk)" -ForegroundColor Cyan
    Write-Host "  'IBM Plex Sans' Active : $($fontStatus.hasIBMPlexSans)" -ForegroundColor Cyan

    if (-not $fontStatus.hasSpaceGrotesk) {
        throw "FAIL: Space Grotesk font is not loaded or active in document.fonts!"
    }
    if (-not $fontStatus.hasIBMPlexSans) {
        throw "FAIL: IBM Plex Sans font is not loaded or active in document.fonts!"
    }
    Write-Host "PASS: Space Grotesk and IBM Plex Sans loaded successfully from Google Fonts!" -ForegroundColor Green

    # 2. Inspect computed font families across all semantic UI elements
    Write-Host "`n[2/4] Auditing Font System Across Heading and Body Elements..." -ForegroundColor Yellow
    $typographyAudit = Eval-Js @'
    (() => {
        const getStyle = (sel) => {
            const el = document.querySelector(sel);
            if (!el) return null;
            const cs = window.getComputedStyle(el);
            return {
                fontFamily: cs.fontFamily,
                fontSize: cs.fontSize,
                fontWeight: cs.fontWeight,
                lineHeight: cs.lineHeight,
                letterSpacing: cs.letterSpacing
            };
        };

        return {
            body: getStyle('body'),
            brandWordmark: getStyle('.brand-wordmark'),
            demoHeading: getStyle('.demo-heading'),
            panelTitle: getStyle('.panel-title'),
            settingsTitle: getStyle('.settings-title'),
            footerWordmark: getStyle('.footer-wordmark'),
            siteNavLink: getStyle('.site-nav-link'),
            ctaBtn: getStyle('.nav-cta-btn'),
            btn: getStyle('.btn'),
            timerDisplay: getStyle('.timer-display'),
            footerSubdesc: getStyle('.footer-subdesc'),
            ruleInput: getStyle('.rule-input')
        };
    })()
'@

    Write-Host "  Body Computed Font     : $($typographyAudit.body.fontFamily) (size: $($typographyAudit.body.fontSize))" -ForegroundColor Cyan
    Write-Host "  Headings Font (Wordmark): $($typographyAudit.brandWordmark.fontFamily) (weight: $($typographyAudit.brandWordmark.fontWeight))" -ForegroundColor Cyan
    Write-Host "  Headings Font (Demo)   : $($typographyAudit.demoHeading.fontFamily) (weight: $($typographyAudit.demoHeading.fontWeight))" -ForegroundColor Cyan
    Write-Host "  Headings Font (Panel)  : $($typographyAudit.panelTitle.fontFamily) (weight: $($typographyAudit.panelTitle.fontWeight))" -ForegroundColor Cyan
    Write-Host "  Footer Wordmark        : $($typographyAudit.footerWordmark.fontFamily) (weight: $($typographyAudit.footerWordmark.fontWeight))" -ForegroundColor Cyan
    Write-Host "  Subdesc (Body copy)    : $($typographyAudit.footerSubdesc.fontFamily) (size: $($typographyAudit.footerSubdesc.fontSize))" -ForegroundColor Cyan

    if ($typographyAudit.body.fontFamily -notmatch "IBM Plex Sans") {
        throw "FAIL: Body copy must use 'IBM Plex Sans' font!"
    }
    if ($typographyAudit.brandWordmark.fontFamily -notmatch "Space Grotesk") {
        throw "FAIL: Wordmark must use 'Space Grotesk' heading font!"
    }
    if ($typographyAudit.demoHeading.fontFamily -notmatch "Space Grotesk") {
        throw "FAIL: Demo Heading must use 'Space Grotesk' heading font!"
    }
    if ($typographyAudit.panelTitle.fontFamily -notmatch "Space Grotesk") {
        throw "FAIL: Panel Title must use 'Space Grotesk' heading font!"
    }
    if ($typographyAudit.footerWordmark.fontFamily -notmatch "Space Grotesk") {
        throw "FAIL: Footer Wordmark must use 'Space Grotesk' heading font!"
    }
    Write-Host "PASS: All headings inherit Space Grotesk and body elements inherit IBM Plex Sans!" -ForegroundColor Green

    # 3. Check for generic 'Inter' leaks
    Write-Host "`n[3/4] Checking for 'Inter' / Generic Font Leaks..." -ForegroundColor Yellow
    $leakAudit = Eval-Js @'
    (() => {
        const allElements = document.querySelectorAll('*');
        const leaks = [];
        for (const el of allElements) {
            const font = window.getComputedStyle(el).fontFamily;
            if (/inter/i.test(font)) {
                leaks.push({
                    tag: el.tagName,
                    class: el.className,
                    id: el.id,
                    font
                });
            }
        }
        return { leakCount: leaks.length, leaks: leaks.slice(0, 5) };
    })()
'@
    Write-Host "  Elements using 'Inter' : $($leakAudit.leakCount)" -ForegroundColor Cyan
    if ($leakAudit.leakCount -gt 0) {
        throw "FAIL: Found $($leakAudit.leakCount) elements leaking generic 'Inter' font!"
    }
    Write-Host "PASS: Zero generic 'Inter' font leaks found across DOM!" -ForegroundColor Green

    # 4. Check readability at mobile 375px width (body copy >= 14px)
    Write-Host "`n[4/4] Checking Mobile (375px) Body Copy Readability..." -ForegroundColor Yellow
    $null = Send-Cdp "Emulation.setDeviceMetricsOverride" @{
        width = 375
        height = 667
        deviceScaleFactor = 2
        mobile = $true
    }
    $null = Read-CdpResponse ($script:msgId - 1) 2000
    Start-Sleep -Milliseconds 600

    $mobileReadability = Eval-Js @'
    (() => {
        const bodySize = parseFloat(window.getComputedStyle(document.body).fontSize);
        const subdescSize = parseFloat(window.getComputedStyle(document.querySelector('.footer-subdesc')).fontSize);
        const settingsDescSize = parseFloat(window.getComputedStyle(document.querySelector('.settings-desc')).fontSize);
        return {
            bodySize,
            subdescSize,
            settingsDescSize,
            allBodyAbove14: bodySize >= 14 && subdescSize >= 14 && settingsDescSize >= 14
        };
    })()
'@

    Write-Host "  Mobile body font-size         : $($mobileReadability.bodySize)px" -ForegroundColor Cyan
    Write-Host "  Mobile .footer-subdesc size   : $($mobileReadability.subdescSize)px" -ForegroundColor Cyan
    Write-Host "  Mobile .settings-desc size    : $($mobileReadability.settingsDescSize)px" -ForegroundColor Cyan

    if (-not $mobileReadability.allBodyAbove14) {
        throw "FAIL: Body copy dropped below 14px on mobile viewport!"
    }
    Write-Host "PASS: All body copy remains >= 14px on mobile width!" -ForegroundColor Green

    Write-Host "`n=================================================" -ForegroundColor Green
    Write-Host "   TYPOGRAPHY SYSTEM VERIFIED 100% SUCCESSFUL    " -ForegroundColor Green
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
