param(
    [string]$PageUrl = 'http://127.0.0.1:4173/',
    [int]$DriverPort = 9515,
    [ValidateSet('no-preference','reduce')]
    [string]$MotionPreference = 'no-preference'
)

$driverPath = 'C:\Users\Caio\.cache\selenium\chromedriver\win64\153.0.8010.52\chromedriver.exe'
$driverProcess = Start-Process -FilePath $driverPath -ArgumentList "--port=$DriverPort",'--silent' -WindowStyle Hidden -PassThru
$webdriver = "http://127.0.0.1:$DriverPort"
$sessionId = $null

function Invoke-WebDriverScript([string]$Script) {
    $body = @{ script = $Script; args = @() } | ConvertTo-Json -Compress
    return (Invoke-RestMethod -Method Post -Uri "$webdriver/session/$sessionId/execute/sync" -ContentType 'application/json' -Body $body).value
}

try {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        try { $null = Invoke-RestMethod -Uri "$webdriver/status"; break } catch { Start-Sleep -Milliseconds 200 }
    } while ((Get-Date) -lt $deadline)

    $capabilities = @{
        capabilities = @{
            alwaysMatch = @{
                browserName = 'chrome'
                'goog:chromeOptions' = @{
                    args = @('--headless=new','--disable-gpu','--no-sandbox','--disable-dev-shm-usage',"--force-prefers-reduced-motion=$MotionPreference",'--window-size=1440,1000')
                }
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    $session = Invoke-RestMethod -Method Post -Uri "$webdriver/session" -ContentType 'application/json' -Body $capabilities
    $sessionId = $session.value.sessionId

    $emulation = @{cmd='Emulation.setEmulatedMedia';params=@{features=@(@{name='prefers-reduced-motion';value=$MotionPreference})}} | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Method Post -Uri "$webdriver/session/$sessionId/goog/cdp/execute" -ContentType 'application/json' -Body $emulation | Out-Null

    Invoke-RestMethod -Method Post -Uri "$webdriver/session/$sessionId/url" -ContentType 'application/json' -Body (@{url=$PageUrl} | ConvertTo-Json -Compress) | Out-Null
    $loaderDeadline = (Get-Date).AddSeconds(3)
    while (-not (Invoke-WebDriverScript 'return document.querySelector("#page-loader").hidden;') -and (Get-Date) -lt $loaderDeadline) {
        Start-Sleep -Milliseconds 100
    }
    $initial = Invoke-WebDriverScript 'return {y: window.scrollY, behavior: getComputedStyle(document.documentElement).scrollBehavior};'

    $elementResponse = Invoke-RestMethod -Method Post -Uri "$webdriver/session/$sessionId/element" -ContentType 'application/json' -Body (@{using='css selector';value='.navlinks a[href="#sobre"]'} | ConvertTo-Json -Compress)
    $elementId = $elementResponse.value.'element-6066-11e4-a52e-4f735466cecf'
    $actions = @{
        actions = @(@{
            type = 'pointer'; id = 'mouse'; parameters = @{pointerType='mouse'}
            actions = @(
                @{type='pointerMove';duration=0;origin=@{'element-6066-11e4-a52e-4f735466cecf'=$elementId};x=0;y=0},
                @{type='pointerDown';button=0},
                @{type='pointerUp';button=0}
            )
        })
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-RestMethod -Method Post -Uri "$webdriver/session/$sessionId/actions" -ContentType 'application/json' -Body $actions | Out-Null

    $samples = @()
    foreach ($delay in @(0,100,200,350,550,850,1200)) {
        if ($delay -gt 0) { Start-Sleep -Milliseconds ($delay - $samples[-1].delay) }
        $state = Invoke-WebDriverScript 'return {y: Math.round(window.scrollY), hash: location.hash, target: Math.round(document.querySelector("#sobre").getBoundingClientRect().top)};'
        $samples += [pscustomobject]@{delay=$delay;y=$state.y;hash=$state.hash;targetTop=$state.target}
    }

    $distinctPositions = @($samples.y | Select-Object -Unique).Count
    [pscustomobject]@{
        initialY = $initial.y
        motionPreference = $MotionPreference
        computedBehavior = $initial.behavior
        positionsObserved = $distinctPositions
        smoothMotionVerified = ($distinctPositions -ge 3 -and $samples[-1].hash -eq '#sobre')
        samples = $samples
    } | ConvertTo-Json -Depth 5
} finally {
    if ($sessionId) {
        try { Invoke-RestMethod -Method Delete -Uri "$webdriver/session/$sessionId" | Out-Null } catch {}
    }
    if ($driverProcess -and -not $driverProcess.HasExited) { Stop-Process -Id $driverProcess.Id -Force }
}
