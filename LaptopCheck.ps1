<#
  LaptopCheck.ps1 - used-laptop inspection for Windows 10/11 (PowerShell 5.1+)
  Read-only: changes nothing, sends nothing over the network.

  Run (normal):   powershell -NoProfile -ExecutionPolicy Bypass -File .\LaptopCheck.ps1
  Best results:   open PowerShell as Administrator first (SSD wear/hours, TPM, Secure Boot)
  Screen test:    add -ScreenTest   (fullscreen colours; click = next colour, Esc = quit)

  A text copy of the report is saved to your Desktop.
#>
param([switch]$ScreenTest)

$ErrorActionPreference = 'SilentlyContinue'
$script:Pass = 0; $script:Warn = 0; $script:Fail = 0

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

function Row($label, $value, $status = 'INFO') {
    switch ($status) {
        'PASS'  { $c = 'Green';  $script:Pass++ }
        'WARN'  { $c = 'Yellow'; $script:Warn++ }
        'FAIL'  { $c = 'Red';    $script:Fail++ }
        default { $c = 'Gray' }
    }
    Write-Host ("[{0,-4}] {1,-24} {2}" -f $status, $label, $value) -ForegroundColor $c
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$reportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("LaptopCheck_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
Start-Transcript -Path $reportPath | Out-Null

Write-Host "LaptopCheck - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
if (-not $isAdmin) {
    Write-Host "Not running as Administrator: SSD wear/hours, TPM and Secure Boot may be missing." -ForegroundColor Yellow
}

# ---------------------------------------------------------------- IDENTITY
Section 'IDENTITY'
$cs    = Get-CimInstance Win32_ComputerSystem
$bios  = Get-CimInstance Win32_BIOS
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$model = $cs.Model

Row 'Manufacturer' $cs.Manufacturer
Row 'Model' $model
Row 'Serial number' $bios.SerialNumber
$sku = (Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation | Select-Object -First 1).SystemSKU
if ($sku) { Row 'Product number (SKU)' $sku }
$biosDate = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { '?' }
Row 'BIOS version / date' ("{0}  /  {1}" -f $bios.SMBIOSBIOSVersion, $biosDate)

# ---------------------------------------------------------------- CPU
Section 'CPU / GENERATION'
Row 'CPU' $cpu.Name.Trim()
Row 'Cores / threads' ("{0} / {1}" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)

$gen = $null
if ($cpu.Name -match 'i[3579]-(\d{4,5})') {
    $n = $Matches[1]
    if ($n.Length -eq 5 -or $n.StartsWith('1')) { $gen = [int]$n.Substring(0,2) }
    else { $gen = [int]$n.Substring(0,1) }
}
if ($gen) { Row 'Intel generation' "Gen $gen" }

$g = $null
if ($model -match '\bG(\d{1,2})\b') { $g = [int]$Matches[1] }
if ($g) { Row 'HP generation tag' "G$g (from model name)" }
$expect = @{ 7 = 10; 8 = 11; 9 = 12; 10 = 13 }
if ($g -and $gen -and $expect.ContainsKey($g)) {
    if ($expect[$g] -eq $gen) {
        Row 'Model vs CPU' "G$g matches Intel gen $gen" 'PASS'
    } else {
        Row 'Model vs CPU' "Model says G$g but CPU is gen $gen (G$g should be gen $($expect[$g]))" 'FAIL'
    }
}

# ---------------------------------------------------------------- MEMORY
Section 'MEMORY'
$mods = Get-CimInstance Win32_PhysicalMemory
$totalGB = [math]::Round(($mods | Measure-Object Capacity -Sum).Sum / 1GB)
Row 'Total RAM' "$totalGB GB" $(if ($totalGB -ge 16) { 'PASS' } else { 'WARN' })
foreach ($m in $mods) {
    Row 'Module' ("{0} GB | {1} MHz | {2} | {3}" -f [math]::Round($m.Capacity / 1GB), $m.Speed, $m.Manufacturer, $m.DeviceLocator)
}
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1).MemoryDevices
if ($slots) { Row 'Memory slots on board' $slots }

# ---------------------------------------------------------------- STORAGE
Section 'STORAGE'
foreach ($d in Get-PhysicalDisk) {
    $sz = [math]::Round($d.Size / 1GB)
    $st = if ($d.HealthStatus -eq 'Healthy') { 'PASS' } else { 'FAIL' }
    Row 'Disk' ("{0} | {1} | {2} GB | {3}" -f $d.FriendlyName, $d.MediaType, $sz, $d.HealthStatus) $st
    $rc = $d | Get-StorageReliabilityCounter
    if ($rc) {
        if ($null -ne $rc.Wear) {
            Row '  wear used' "$($rc.Wear) %" $(if ($rc.Wear -lt 10) { 'PASS' } elseif ($rc.Wear -lt 50) { 'WARN' } else { 'FAIL' })
        }
        if ($null -ne $rc.PowerOnHours) {
            Row '  power-on hours' "$($rc.PowerOnHours) h  (a 'barely used' laptop should be low)" $(if ($rc.PowerOnHours -le 200) { 'PASS' } else { 'WARN' })
        }
        if ($null -ne $rc.Temperature) { Row '  temperature' "$($rc.Temperature) C" }
    } elseif (-not $isAdmin) {
        Row '  SMART detail' 'run as Administrator to read wear / hours' 'WARN'
    }
}

# ---------------------------------------------------------------- BATTERY
Section 'BATTERY'
$bat = Get-CimInstance Win32_Battery | Select-Object -First 1
if (-not $bat) {
    Row 'Battery' 'NOT DETECTED' 'FAIL'
} else {
    Row 'Charge now' "$($bat.EstimatedChargeRemaining) %"
    $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity
    $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
    $cyc    = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount | Select-Object -First 1).CycleCount
    if ($design -and $full) {
        $health = [math]::Round(100 * $full / $design, 1)
        Row 'Design capacity' "$design mWh"
        Row 'Full-charge capacity' "$full mWh"
        Row 'Battery health' "$health %" $(if ($health -ge 90) { 'PASS' } elseif ($health -ge 80) { 'WARN' } else { 'FAIL' })
    } else {
        Row 'Battery health' 'not exposed by WMI - open the powercfg report below' 'WARN'
    }
    if ($null -ne $cyc) {
        Row 'Cycle count' $cyc $(if ($cyc -lt 50) { 'PASS' } elseif ($cyc -lt 150) { 'WARN' } else { 'FAIL' })
    }
    $rep = Join-Path $env:TEMP 'battery-report.html'
    powercfg /batteryreport /output $rep | Out-Null
    Row 'Full battery report' $rep
}

# ---------------------------------------------------------------- DISPLAY
Section 'DISPLAY'
foreach ($v in Get-CimInstance Win32_VideoController) {
    Row 'GPU' ("{0} | {1}x{2} @ {3} Hz" -f $v.Name, $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate)
    $drvDate = if ($v.DriverDate) { $v.DriverDate.ToString('yyyy-MM-dd') } else { '?' }
    Row '  driver' ("{0}  ({1})" -f $v.DriverVersion, $drvDate)
    if ($v.Name -match 'Basic Display') {
        Row '  WARNING' 'generic Microsoft driver in use - this alone can make the screen look dim/wrong' 'FAIL'
    }
}
$decode = { param($a) -join ($a | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) }
$mon = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | Select-Object -First 1
if ($mon) {
    Row 'Panel maker code' (& $decode $mon.ManufacturerName)
    Row 'Panel product code' (& $decode $mon.ProductCodeID)
    Row 'Panel made' ("week {0} of {1}" -f $mon.WeekOfManufacture, $mon.YearOfManufacture)
    Row 'Tip' 'search "<model> + panel product code" to find if it is the 250-nit or 400-nit panel'
}
$br = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness | Select-Object -First 1
if ($br) {
    Row 'Brightness control' "works (now $($br.CurrentBrightness) %)" 'PASS'
    Row 'Tip' 'set brightness to 100% and compare with a phone/other laptop - software cannot read nits'
} else {
    Row 'Brightness control' 'not available - driver/panel problem?' 'WARN'
}

# ---------------------------------------------------------------- LOCKS
Section 'LOCKS / MANAGEMENT (ex-corporate check)'
if ($cs.PartOfDomain) { Row 'Domain joined' $cs.Domain 'FAIL' } else { Row 'Domain joined' 'no' 'PASS' }

$ds = dsregcmd /status 2>$null
if ($ds) {
    $aad = ($ds | Select-String 'AzureAdJoined\s*:\s*(\w+)' | Select-Object -First 1).Matches.Groups[1].Value
    $mdm = ($ds | Select-String 'MdmUrl\s*:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
    if ($aad -eq 'YES') { Row 'Azure AD joined' 'YES - company-owned, may be remotely lockable' 'FAIL' } else { Row 'Azure AD joined' 'no' 'PASS' }
    if ($mdm) { Row 'MDM enrolment' $mdm 'FAIL' } else { Row 'MDM enrolment' 'none' 'PASS' }
}

$agents = Get-Service | Where-Object {
    $_.Name -in 'CcmExec', 'IntuneManagementExtension' -or
    $_.DisplayName -match 'Absolute|Computrace|Workspace ONE|AirWatch|Jamf|MobileIron|CrowdStrike|Zscaler'
}
if ($agents) {
    foreach ($a in $agents) { Row 'Corporate agent' $a.DisplayName 'WARN' }
} else {
    Row 'Corporate agents' 'none found' 'PASS'
}

$pw = Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSPassword
if ($pw) {
    foreach ($p in $pw) {
        if ($p.IsSet) { Row "BIOS $($p.Name)" 'SET - make the seller clear it before you pay' 'FAIL' }
        else          { Row "BIOS $($p.Name)" 'not set' 'PASS' }
    }
} else {
    Row 'BIOS password' 'cannot read from Windows - press F10 at boot and check manually' 'WARN'
}

$sb = Confirm-SecureBootUEFI
if ($null -ne $sb) { Row 'Secure Boot' $sb }
$tpm = Get-Tpm
if ($tpm) { Row 'TPM' ("present={0} ready={1}" -f $tpm.TpmPresent, $tpm.TpmReady) }

# ---------------------------------------------------------------- SOFTWARE
Section 'WINDOWS / USAGE HISTORY'
$os = Get-CimInstance Win32_OperatingSystem
Row 'OS' ("{0}  build {1}" -f $os.Caption, $os.BuildNumber)
Row 'Windows installed' $os.InstallDate.ToString('yyyy-MM-dd')
$lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Select-Object -First 1
if ($lic -and $lic.LicenseStatus -eq 1) { Row 'Activation' 'Licensed' 'PASS' } else { Row 'Activation' 'NOT activated / unknown' 'WARN' }
$profiles = Get-ChildItem "$env:SystemDrive\Users" -Directory | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' }
Row 'User profiles on disk' (($profiles.Name) -join ', ')

# ---------------------------------------------------------------- DEVICES
Section 'DRIVERS / DEVICE MANAGER'
$bad = Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
if ($bad) {
    foreach ($b in $bad) { Row 'Problem device' ("{0} (code {1})" -f $b.Name, $b.ConfigManagerErrorCode) 'FAIL' }
} else {
    Row 'Device Manager errors' 'none' 'PASS'
}

Section 'HARDWARE PRESENT'
$pnp = Get-PnpDevice -PresentOnly
function Chk($name, $filter) {
    $f = $pnp | Where-Object $filter | Select-Object -First 1
    if ($f) { Row $name $f.FriendlyName 'PASS' } else { Row $name 'NOT FOUND' 'FAIL' }
}
Chk 'Webcam'    { $_.Class -in 'Camera', 'Image' }
Chk 'Bluetooth' { $_.Class -eq 'Bluetooth' -and $_.FriendlyName -match 'Bluetooth' }
Chk 'Wi-Fi'     { $_.Class -eq 'Net' -and $_.FriendlyName -match 'Wi-?Fi|Wireless|WLAN' }
Chk 'Audio'     { $_.Class -eq 'MEDIA' }

# ---------------------------------------------------------------- SUMMARY
Section 'SUMMARY'
Write-Host ("PASS {0}   WARN {1}   FAIL {2}" -f $script:Pass, $script:Warn, $script:Fail) -ForegroundColor White
Write-Host ""
Write-Host "DO BY HAND (software cannot check these):" -ForegroundColor Cyan
@(
    'Serial above == bottom sticker == HP support site > Check warranty (confirm model, config, warranty)',
    'BIOS (F10 at boot): no admin/power-on password, model name matches',
    'Run again with -ScreenTest: dead pixels, yellow tint, backlight bleed, brightness at 100%',
    'Keyboard: every key + backlight. Touchpad: both clicks, scroll, gestures',
    'Ports: USB-A, USB-C (also charge through it), HDMI, headphone jack - plug something into each',
    'Speakers (both sides, no crackle) and mic (record a voice note)',
    'Hinges, cracks, missing screws, bottom plate gaps, swollen battery (case bulging)',
    'Fans: run a video / heavy page for 3-5 min - loud rattle or very hot = bad',
    'Original charger: plug in, % goes up. Connect Wi-Fi + pair Bluetooth once',
    'Bill + warranty terms in writing with the serial number on it'
) | ForEach-Object { Write-Host " [ ] $_" }
Write-Host ""
Write-Host "Report saved: $reportPath" -ForegroundColor Green
Stop-Transcript | Out-Null

# ---------------------------------------------------------------- SCREEN TEST
if ($ScreenTest) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $script:colors = 'White', 'Black', 'Red', 'Lime', 'Blue', 'Gray'
    $script:idx = 0
    $script:f = New-Object System.Windows.Forms.Form
    $script:f.FormBorderStyle = 'None'
    $script:f.WindowState = 'Maximized'
    $script:f.TopMost = $true
    $script:f.KeyPreview = $true
    $script:f.BackColor = [System.Drawing.Color]::FromName($script:colors[0])
    $script:f.Add_Click({
        $script:idx++
        if ($script:idx -ge $script:colors.Count) { $script:f.Close() }
        else { $script:f.BackColor = [System.Drawing.Color]::FromName($script:colors[$script:idx]) }
    })
    $script:f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $script:f.Close() } })
    Write-Host "Screen test: click for next colour, Esc to quit." -ForegroundColor Cyan
    [void]$script:f.ShowDialog()
}
