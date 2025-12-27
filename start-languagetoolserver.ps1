$ProgressPreference = 'SilentlyContinue'

# --- CONFIGURATION ---
$rootDir = $PSScriptRoot
$serverDir = "$rootDir\server"
$serverProps = "$rootDir\server.properties"
$remoteUrlSource = "https://raw.githubusercontent.com/ELowry/LanguageToolServer/main/download_url.txt"
$fallbackZipUrl = "https://internal1.languagetool.org/snapshots/LanguageTool-latest-snapshot.zip"
$zipPath = "$rootDir\LanguageTool-latest-snapshot.zip"
$extractPath = "$rootDir\temp_extract"
$port = 8081

# --- 0. FETCH DYNAMIC URL ---
try {
	$zipUrl = (Invoke-WebRequest -Uri $remoteUrlSource -UseBasicParsing -ErrorAction Stop).Content.Trim()
	if ([string]::IsNullOrWhiteSpace($zipUrl)) {
		throw "Empty URL"
	}
}
catch {
	Write-Warning "Could not fetch remote URL from GitHub. Using fallback."
	$zipUrl = $fallbackZipUrl
}

# --- 1. STOP EXISTING INSTANCE ---
try {
	$runningInstances = Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe'" | Where-Object {
		$_.CommandLine -like "*languagetool-server.jar*"
	}

	if ($runningInstances) {
		Write-Output "Stopping existing LanguageTool server instances..."
		$runningInstances | ForEach-Object {
			Stop-Process -Id $_.ProcessId -Force
			Write-Output "Stopped PID $($_.ProcessId)"
		}
		# Wait a second to ensure file locks are released
		Start-Sleep -Seconds 2
	}
}
catch {
	Write-Warning "Could not query running processes. Skipping stop step."
}

# --- 2. JAVA CHECK & INSTALL (WINGET) ---
try {
	Get-Command javaw -ErrorAction Stop | Out-Null
}
catch {
	Write-Warning "Java not found. Attempting to install Eclipse Adoptium (JRE 21) via Winget..."
	try {
		winget install -e --id EclipseAdoptium.Temurin.25.JRE --accept-package-agreements --accept-source-agreements --silent

		# Refresh Path
		$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

		Get-Command javaw -ErrorAction Stop | Out-Null
		Write-Output "Java installed successfully."
	}
 catch {
		Write-Error "Failed to install Java automatically. Please install Java 17+ manually."
		exit 1
	}
}

# --- 3. CONFIGURATION SAFETY ---
if (-not (Test-Path $serverProps)) {
	New-Item $serverProps -ItemType File
	Write-Output "Created empty server.properties in root."
}

# --- 4. UPDATE LOGIC ---
try {
	Write-Output "Checking for updates..."

	# Download
	Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

	# Clean & Create Temp
	if (Test-Path $extractPath) {
		Remove-Item -Recurse -Force $extractPath
	}
	New-Item -ItemType Directory -Force -Path $extractPath | Out-Null

	# Extract
	Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

	# Find the dynamic subfolder
	$subFolder = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1

	if ($subFolder) {
		if (Test-Path $serverDir) {
			Remove-Item -Recurse -Force $serverDir
		}

		Move-Item -Path $subFolder.FullName -Destination $serverDir -Force
	}

	# Cleanup
	Remove-Item -Recurse -Force $extractPath
	Remove-Item -Force $zipPath
	Write-Output "Update successful."
}
catch {
	Write-Warning "Update failed (Network down?). Proceeding with existing version."
}

# --- 5. STARTUP LOGIC ---
if (-not (Test-Path $serverDir)) {
	Write-Error "Server directory missing and update failed. Cannot start."
	exit 1
}

Set-Location -Path $serverDir

$jarFile = Get-ChildItem -Path $serverDir -Filter "languagetool-server.jar" | Select-Object -First 1

if ($jarFile) {
	# Point to the jar in \server\ but config in \root\
	$args = "-cp `"$($jarFile.Name)`" org.languagetool.server.HTTPServer --config `"$serverProps`" --port $port --allow-origin `"*`""

	# Start silently
	Start-Process -FilePath "javaw" -ArgumentList $args -WindowStyle Hidden
}
else {
	Write-Error "Could not find languagetool-server.jar in $serverDir"
}