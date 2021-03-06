<#
.Synopsis
    Mounts Egnyte network drives.

.Description
    This script mounts Egnyte network drives based on group membership in Azure Active Directory.
    Utilizes a CSV file with all of the drive mappings and group names located in an Azure Storage Account.

.Example
    .\Mount-Egnyte-Intune.ps1 without administrator rights.

.Outputs
    Log files stored in C:\Logs\Egnyte.

.Notes
    Author: Chrysi
    Link:   https://github.com/DarkSylph/egnyte
    Date:   01/18/2022
#>

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Requires -Version 5.1

#----------------------------------------------------------[Declarations]----------------------------------------------------------

#Script version
$ScriptVersion = "v5.2.1"
#Script name
$App = "Egnyte Drive Mapping"
#Application installation path
$Default = "C:\Program Files (x86)\Egnyte Connect\EgnyteClient.exe"
#Location of the mappings
$File = "https://contoso.blob.core.windows.net/egnyte/client-drives.csv"
#Today's date
$Date = Get-Date -Format "MM-dd-yyyy-HH-mm-ss"
#Destination to store logs
$LogFilePath = "C:\Logs\Egnyte\" + $Date + "" + "-" + $env:USERNAME + "-Mount-Logs.log"
#Defines the data needed to connect to the Microsoft Graph API
$AppID = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
$AppSecret = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$Scope = "https://graph.microsoft.com/.default"
$TenantName = "contoso.onmicrosoft.com"
$GraphURL = "https://login.microsoftonline.com/$TenantName/oauth2/v2.0/token"

#-----------------------------------------------------------[Functions]------------------------------------------------------------

function Start-Egnyte {
    <#
    .Synopsis
    Starts Egnyte if any of its processes aren't running.
    #>
    $arguments = '--auto-silent'
    try {
        $egnyteclient = Get-WmiObject -Class Win32_Process -Filter "Name = 'egnyteclient.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.GetOwner().User -eq $env:USERNAME }
        $egnytedrive = Get-WmiObject -Class Win32_Process -Filter "Name = 'egnytedrive.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.GetOwner().User -eq $env:USERNAME }
        $egnytesync = Get-WmiObject -Class Win32_Process -Filter "Name = 'egnytesyncservice.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.GetOwner().User -eq $env:USERNAME }
        if (!$egnyteclient -or !$egnytedrive -or !$egnytesync) {
            Write-Host "$(Get-Date): Starting $app before mapping drives..."
            Start-Process -PassThru -FilePath $default -ArgumentList $arguments | Out-Null
            Start-Sleep -Seconds 8
            $egnyteclient = Get-WmiObject -Class Win32_Process -Filter "Name = 'egnyteclient.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.GetOwner().User -eq $env:USERNAME }
            if ($egnyteclient) {
                Write-Host "$(Get-Date): $app has successfully started up!"
            }
        }
        else {
            Write-Host "$(Get-Date): $app is already running, proceeding to map drives."
        }
    }
    catch {
        Write-Host "$(Get-Date): Unable to confirm if $app is running or not, attempting to start $app by force: $($_.Exception.Message)"
        Start-Process -PassThru -FilePath $default -ArgumentList $arguments
        Start-Sleep -Seconds 8
        $egnyteclient = Get-WmiObject -Class Win32_Process -Filter "Name = 'egnyteclient.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.GetOwner().User -eq $env:USERNAME }
        if ($egnyteclient) {
            Write-Host "$(Get-Date): $app has successfully started up!"
        }
        else {
            Write-Host "$(Get-Date): Status of $app is unknown, proceeding with rest of script..."
        }
    }
}
function Get-Mappings {
    <#
    .Synopsis
    Downloads the mapping file.
    .Parameter URL
    Input the URL to the mapping file. Must be publicly accessible.
    #>
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $URL
    )
    process {
        try {
            if (-Not (Test-Path -Path "C:\Deploy")) {
                Write-Host -Message "Creating new log folder."
                New-Item -ItemType Directory -Force -Path C:\Deploy | Out-Null
            }
            $outpath = "C:\Deploy\client-drives.csv"
            Write-Host "$(Get-Date): Downloading files to $outpath..."
            $job = Measure-Command { (New-Object System.Net.WebClient).DownloadFile($URL, $outpath) }
            $jobtime = $job.TotalSeconds
            $timerounded = [math]::Round($jobtime)
            if (Test-Path $outpath) {
                Write-Host "$(Get-Date): Files downloaded successfully in $timerounded seconds...."		
            }
            else {
                Write-Host "$(Get-Date): Download failed, please check your connection and try again..." -ForegroundColor Red
                Remove-Item "C:\Deploy" -Force -Recurse
                exit
            }        
        }
        catch {
            Throw "Unable to download mapping file: $($_.Exception.Message)"
        }
    }
}
function Get-Groups {
    #Add System.Web for urlencode
    Add-Type -AssemblyName System.Web

    #Create body
    $Body = @{
        client_id     = $AppId
        client_secret = $AppSecret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }

    #Splat the parameters for Invoke-Restmethod for cleaner code
    $PostSplat = @{
        ContentType = 'application/x-www-form-urlencoded'
        Method      = 'POST'
        #Create string by joining bodylist with '&'
        Body        = $Body
        Uri         = $GraphUrl
    }

    #Request the token!
    Write-Host "$(Get-Date): Connecting to Microsoft Graph..."
    $Request = Invoke-RestMethod @PostSplat

    #Create header
    $Header = @{
        'Authorization' = "$($Request.token_type) $($Request.access_token)"
        'Content-Type'  = "application/json"
    }
    #Define user ID to check for group memberships
    $userID = whoami.exe /upn
    Write-Host "$(Get-Date): Currently logged on user found is $userID..."

    #Graph URL to run check against
    $Uri = "https://graph.microsoft.com/v1.0/users/$userID/getMemberGroups"

    #Define JSON payload
    $Payload = @'
    {
        "securityEnabledOnly": false
    }
'@

    #Fetch group membership
    Write-Host "$(Get-Date): Grabbing list of group memberships..."
    $GroupMemberRequest = Invoke-RestMethod -Uri $Uri -Headers $Header -Method 'Post' -Body $Payload
    $GroupMemberRequest.Value
}
function Mount-Drives {
    <#
    .Synopsis
    Map and connect each drive in the array.
    .Parameter DriveList
    Accepts an array of drives and then feeds them into Egnyte to be mounted.
    #>
    [CmdletBinding(DefaultParameterSetName = "DriveList")]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "DriveList")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject[]]
        $DriveList
    )
    process {
        try {
            foreach ($Drive in $DriveList) {
                Write-Host "$(Get-Date): Mapping $($Drive.DriveName) to $($Drive.DriveLetter)" -ForegroundColor Green
                $arguments = @(
                    "-command add"
                    "-l ""$($Drive.DriveName)"""
                    "-d ""$($Drive.DomainName)"""
                    "-sso use_sso"
                    "-t ""$($Drive.DriveLetter)"""
                    "-m ""$($Drive.DrivePath)"""
                )
                $process = Start-Process -PassThru -FilePath $default -ArgumentList $arguments
                $process.WaitForExit()
                $connect = @(
                    "-command connect"
                    "-l ""$($Drive.DriveName)"""
                )
                $process = Start-Process -PassThru -FilePath $default -ArgumentList $connect
                $process.WaitForExit()
            }
        }
        catch {
            Throw "Unable to map or connect drives: $($_.Exception.Message)"
        }
    }
}
function Test-Paths {
    <#
    .Synopsis
    Tests existing paths to see if the drives have already been mapped.
    .Description
    Checks group membership before mapping each drive to ensure end user has appropriate permissions.
    Tests the paths first so as to not waste time re-mapping drives that are already mapped.
    Checks whether the path is mapped to a local server versus Egnyte. If mapped to local, then removes the mapping and remaps it to Egnyte.
    Also checks if drive is disconnected and if it is, will unmap it and then remap it to Egnyte.
    #>
    [CmdletBinding(DefaultParameterSetName = "DriveList")]
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = "DriveList")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject[]]
        $DriveList
    )
    process {
        try {
            Write-Host "$(Get-Date): Checking to see if the paths are already mapped..."
            $GroupMember = Get-Groups
            foreach ($Drive in $DriveList) {
                $CheckMembers = $GroupMember -contains $Drive.GroupID
                $DiscDrives = Get-CimInstance -Class Win32_NetworkConnection | Where-Object { $_.ConnectionState -eq "Disconnected" }
                if ((Test-Path -Path "$($Drive.DriveLetter):") -Or ($DiscDrives)) {
                    $Root = Get-PSDrive | Where-Object { $_.DisplayRoot -match "EgnyteDrive" -and $_.Name -eq $Drive.DriveLetter }  
                    if (!$Root) {
                        Write-host "$(Get-Date): $($Drive.DriveName) is not mapped to the cloud. Unmapping now."
                        $NetDrive = $($Drive.DriveLetter) + ":"
                        net use $NetDrive /delete
                        Mount-Drives -DriveList $Drive
                    }
                    else {
                        Write-Host "$(Get-Date): $($Drive.DriveName) is already mapped..."
                    }
                }
                elseif ($CheckMembers) {
                    Write-Host "$(Get-Date): $($Drive.DriveName) not found, proceeding to map drive..."
                    Mount-Drives -DriveList $Drive
                }
                else {
                    Write-Host "$(Get-Date): Not authorized for this drive, moving to next drive..."    
                }
            }
            Write-Host "$(Get-Date): All drives checked on $env:computername, proceeding to exit script..."
            Start-Sleep -Seconds 2
        }
        catch {
            Throw "Could not map drives: $($_.Exception.Message)"
        }
    }
}

#-----------------------------------------------------------[Execution]------------------------------------------------------------

#Sets up a destination for the logs
if (-Not (Test-Path -Path "C:\Logs")) {
    Write-Host -Message "Creating new log folder."
    New-Item -ItemType Directory -Force -Path C:\Logs | Out-Null
}
if (-Not (Test-Path -Path "C:\Logs\Egnyte")) {
    Write-Host -Message "Creating new log folder."
    New-Item -ItemType Directory -Force -Path C:\Logs\Egnyte | Out-Null
}
#Begins the logging process to capture all output
Start-Transcript -Path $LogFilePath -Force
Write-Host "$(Get-Date): Successfully started $App $ScriptVersion on $env:computername"
Write-Host "$(Get-Date): Checking if Egnyte is running before continuing..."
#Starts Egnyte up if it isn't already running
Start-Egnyte
#Imports the mapping file into the script
Get-Mappings -URL $File
$Drives = Import-Csv -Path "C:\Deploy\client-drives.csv"
#Tests the paths to see if they are already mapped or not and maps them if needed
Test-Paths -DriveList $Drives
#Ends the logging process
Stop-Transcript
#Terminates the script
exit