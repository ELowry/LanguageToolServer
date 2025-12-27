$ProgressPreference = 'SilentlyContinue'

# --- SETTINGS ---
$repoRoot = "https://raw.githubusercontent.com/ELowry/LanguageToolServer/main"
$targetDir = "$env:LOCALAPPDATA\LanguageToolServer"
$taskName = "LanguageTool Local Server"

# --- 1. SELF-ELEVATION ---

# If not Admin, download this script to Temp and run it as Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	Write-Host "Requesting Admin privileges..." -ForegroundColor Yellow
    
	$selfPath = "$env:TEMP\lt_install.ps1"
	Invoke-WebRequest -Uri "$repoRoot/install.ps1" -OutFile $selfPath -UseBasicParsing

	if (Get-Command "wt.exe" -ErrorAction SilentlyContinue) {
		Start-Process "wt.exe" -ArgumentList "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$selfPath`"" -Verb RunAs
	} 
	else {
		Start-Process "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`""
	}
	exit
}

# --- 2. SETUP FOLDER ---
Write-Host "Installing LanguageTool Server to: $targetDir" -ForegroundColor Cyan
if (-not (Test-Path $targetDir)) {
	New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
}

# --- 3. DOWNLOAD SCRIPTS ---
try {
	Write-Host "Downloading scripts from GitHub..."
	
	# Download the Main Logic Script
	Invoke-WebRequest -Uri "$repoRoot/start-languagetoolserver.ps1" -OutFile "$targetDir\start-languagetoolserver.ps1" -UseBasicParsing -ErrorAction Stop

	# Download Config
	if (-not (Test-Path "$targetDir\server.properties")) {
		try {
			Invoke-WebRequest -Uri "$repoRoot/server.properties" -OutFile "$targetDir\server.properties" -UseBasicParsing -ErrorAction Stop
		}
		catch {
			Write-Warning "Custom server.properties not found on GitHub. Using defaults."
		}
	}
}
catch {
	Write-Error "Failed to download the main script. Check the URL in install.ps1."
	Read-Host "Press Enter to exit"
	exit
}

# --- 4. CREATE INVISIBLE LAUNCHER & TASK ---
Write-Host "Creating invisible launcher..."
$vbsPath = "$targetDir\launch.vbs"
$scriptPath = "$targetDir\start-languagetoolserver.ps1"

# Create a VBS script that launches PowerShell completely hidden
$vbsContent = @"
Set WshShell = CreateObject("WScript.Shell") 
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$scriptPath""", 0, False
"@
Set-Content -Path $vbsPath -Value $vbsContent -Encoding Ascii

Write-Host "Creating Scheduled Task..."
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings | Out-Null

# --- 5. LAUNCH ---
Write-Host "Installation Complete! Starting server..." -ForegroundColor Green
	if (Get-Command "wt.exe" -ErrorAction SilentlyContinue) {
		Start-Process "wt.exe" -ArgumentList "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$targetDir\start-languagetoolserver.ps1`"" -Verb RunAs
	} 
	else {
		Start-Process "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$targetDir\start-languagetoolserver.ps1`""
	}
exit