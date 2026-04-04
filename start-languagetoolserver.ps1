$ProgressPreference = 'SilentlyContinue'

# CONFIGURATION
$rootDir = $PSScriptRoot
$serverDir = "$rootDir\server"
$serverProps = "$rootDir\server.properties"
$remoteUrlSource = "https://raw.githubusercontent.com/ELowry/LanguageToolServer/main/download_url.txt"
$fallbackZipUrl = "https://internal1.languagetool.org/snapshots/LanguageTool-latest-snapshot.zip"
$zipPath = "$rootDir\LanguageTool-latest-snapshot.zip"
$extractPath = "$rootDir\temp_extract"
$port = 8081

# FETCH DYNAMIC URL
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

# STOP EXISTING INSTANCE
try {
	$runningInstances = Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe'" | Where-Object {
		$_.CommandLine -like "*languagetool-server.jar*"
	}
	if ($runningInstances) {
		Write-Output "Stopping existing LanguageTool server instances..."
		$runningInstances | ForEach-Object {
			Stop-Process -Id $_.ProcessId -Force
		}
		Start-Sleep -Seconds 2
	}
}
catch {
	Write-Warning "Could not query running processes. Skipping stop step."
}

# SMART JAVA CHECK & INSTALL
Write-Output "Scanning system for the newest Java version..."

# Find ALL javaw.exe instances in system PATH
$allJavas = Get-Command javaw -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source

if ($allJavas) {
	# Sort by file version number and pick the highest one
	$bestJavaw = $allJavas | Sort-Object {
		$verString = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_).ProductVersion
		# Clean the string to ensure it casts to a [version] object correctly
		$cleanVer = $verString -replace '[^\d\.]', ''
		if ([version]::TryParse($cleanVer, [ref]$null)) { [version]$cleanVer } else { [version]'0.0' }
	} -Descending | Select-Object -First 1

	Write-Output "Selected Java Executable: $bestJavaw"
}
else {
	Write-Warning "Java not found. Attempting to install Eclipse Adoptium (JRE 21) via Winget..."
	try {
		winget install -e --id EclipseAdoptium.Temurin.25.JRE --accept-package-agreements --accept-source-agreements --silent
		$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
		$bestJavaw = "javaw" # Fallback to standard command after install
		Write-Output "Java installed successfully."
	}
 catch {
		Write-Error "Failed to install Java automatically. Please install Java 17+ manually."
		exit 1
	}
}

# CONFIGURATION SAFETY
if (-not (Test-Path $serverProps)) {
	New-Item $serverProps -ItemType File | Out-Null
}

# SMART UPDATE LOGIC
try {
	Write-Output "Checking if a new LanguageTool version is available..."
	$forceDownload = $false
    
	# Get headers from the server safely
	try {
		$headers = Invoke-WebRequest -Uri $zipUrl -Method Head -UseBasicParsing -ErrorAction Stop
		if ($headers.Headers.ContainsKey('Last-Modified')) {
			$remoteDate = [datetime]$headers.Headers['Last-Modified']
		}
		else {
			$forceDownload = $true
		}
	}
 catch {
		Write-Warning "Server didn't respond to HEAD request. Forcing download."
		$forceDownload = $true
		$remoteDate = [datetime]::MaxValue
	}

	# Get the date of your current local installation
	$localDate = if (Test-Path $serverDir) {
		(Get-Item $serverDir).LastWriteTime
	}
	else {
		[datetime]::MinValue
	}

	# Only download if the remote file is newer than the local folder or forced
	if ($forceDownload -or ($remoteDate -gt $localDate) -or -not (Test-Path $serverDir)) {
		Write-Output "Downloading LanguageTool..."
		Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

		if (Test-Path $extractPath) {
			Remove-Item -Recurse -Force $extractPath
		}
		New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
		Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

		$subFolder = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
		if ($subFolder) {
			if (Test-Path $serverDir) {
				Remove-Item -Recurse -Force $serverDir
			}
			Move-Item -Path $subFolder.FullName -Destination $serverDir -Force
			if (-not $forceDownload) {
				(Get-Item $serverDir).LastWriteTime = $remoteDate
			}
		}

		Remove-Item -Recurse -Force $extractPath
		Remove-Item -Force $zipPath
		Write-Output "Update successful."
	}
 else {
		Write-Output "You are already on the latest version. Skipping download."
	}
}
catch {
	Write-Warning "Download failed completely. Proceeding with existing version."
}

# STARTUP LOGIC
if (-not (Test-Path $serverDir)) {
	Write-Error "Server directory missing. Cannot start."; exit 1
}

Set-Location -Path $serverDir
$jarFile = Get-ChildItem -Path $serverDir -Filter "languagetool-server.jar" | Select-Object -First 1

if ($jarFile) {
	Write-Host "Starting LanguageTool Server..." -ForegroundColor Cyan

	# Construct the arguments as a single precise string so PowerShell cannot mangle it
	$startArgs = '-cp "languagetool-server.jar;libs/*" org.languagetool.server.HTTPServer --config "' + $serverProps + '" --port ' + $port + ' --allow-origin "*"'

	# Start the process silently, explicitly defining the working directory
	$process = Start-Process -FilePath "javaw" -ArgumentList $startArgs -WorkingDirectory $serverDir -RedirectStandardError "$rootDir\error.log" -WindowStyle Hidden -PassThru

	Write-Host "Waiting for server to initialize..." -NoNewline
	Start-Sleep -Seconds 5
	Write-Host " Done."

	if ($process.HasExited) {
		Write-Error "Server process crashed immediately. Check the 'error.log' file in your folder for the exact Java error."
		exit 1
	}

	try {
		$tcpConnection = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
		Write-Host "SUCCESS: Server is up and listening on port $port" -ForegroundColor Green
	}
 catch {
		Write-Warning "Server process is running, but port $port is not yet responding."
	}
}
else {
	Write-Error "Could not find languagetool-server.jar in $serverDir"
}
exit 0
