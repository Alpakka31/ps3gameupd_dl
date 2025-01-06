param (
    [CmdletBinding()]
    [Parameter(Mandatory = $true)]
    [string]$GameID
)

# Set default output encoding to UTF-8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Set variables
$ProgramVersion = "0.0.1"
$GameUpdateDownloadTargetPath = "$env:USERPROFILE\ps3_gameupdates"
$GameXML_URL = "https://a0.ww.np.dl.playstation.net/tpl/np/$GameID/$GameID-ver.xml"

$ValidGameIDs = @(
    "BCAS",
    "BCAX",
    "BCED",
    "BCES",
    "BCJB",
    "BCJS",
    "BCKS",
    "BCUS",
    "BLAS",
    "BLES",
    "BLJM",
    "BLJS",
    "BLJX",
    "BLKS",
    "BLUD",
    "BLUS",
    "MRTC",
    "NPEA",
    "NPUB",
    "NPUA",
    "NPEB",
    "NPJB",
    "NPIA",
    "NPJA",
    "NPHA"
)

# Create download directory if it doesn't exist
[IO.Directory]::CreateDirectory($GameUpdateDownloadTargetPath) | Out-Null

# Valida the user given GameID
function Validate-GameID {
    Write-Host "Validating GameID: $GameID"

    # E.g: BLES00000
    if ($GameID.Length -eq 9) {
        # BLES
        $FirstPart = $GameID.Substring(0, 4).ToUpper()
        # 00000
        $SecondPart = $GameID.Substring(4)

        # The first four characters of the id must be uppercase letters
        # and the second part must be all numbers
        if ($FirstPart -match '^[A-Z]{4}$' -and $SecondPart -match '^[0-9]{5}$') {
            if ($ValidGameIDs -contains $FirstPart) {
                Write-Host "GameID $GameID is valid"
            }
            else {
                Write-Host "Supported GameID values:"
                Write-Host "XXXXX = Numbers"
                foreach ($id in $ValidGameIDs) {
                    Write-Host " - $id + XXXXX"
                }
                throw "`nInvalid GameID: $GameID"
            }
        }
        else {
            throw "First four characters of the GameID must be uppercase letters and the last 5 must all be numbers."
        }
    }
    else {
        throw "The GameID length must be equal to 9"
    }
}

# Get the XML metadata of the game by its ID
function Get-GameXml {
    try {
        $response = Invoke-WebRequest -Uri $GameXML_URL -ErrorAction Stop -ContentType 'application/xml; charset=UTF-8'

        # Encoding must be UTF-8 to show special unicode characters correctly
        # Thanks, a headache part 2: https://learn.microsoft.com/en-us/answers/questions/1190434/invoke-webrequest-and-utf-8
        $content = [System.Text.Encoding]::UTF8.GetString($response.Content.ToCharArray())

        if ($response.StatusCode -eq 200 -and $response.Content) {
            [xml]$xmlContent = $content
            return $xmlContent
        }
        else {
            throw "Failed to get game XML metadata by ID: $GameID"
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Host "Details: $($_.Exception.InnerException.Message)"
        }
        throw "Failed to get game XML metadata by ID: $GameID (maybe an invalid id)"
    }
}

# Download the game update pkg itself
function Download-GameUpdate {
    param (
        [Parameter(Mandatory = $true)]
        [string]$GameUpdateUrl,
        [string]$GameUpdateName,
        [int]$GameUpdateSize
    )

    try {
        $response = Invoke-WebRequest -Uri $GameUpdateUrl -OutFile "$GameUpdateDownloadTargetPath\$GameUpdateName" -ErrorAction Stop
        
        # Get the downloaded pkg's size in bytes
        $downloadedGameUpdateInfo = Get-Item "$GameUpdateDownloadTargetPath\$GameUpdateName"
        $downloadedGameUpdateSize = $downloadedGameUpdateInfo.Length

        # The server doesn't support returning succesful statuscodes in any way,
        # so checking the differences of sizes in bytes is used instead.
        if ($downloadedGameUpdateSize -eq $GameUpdateSize) {
            Write-Host "Succesfully downloaded the game update file to: $GameUpdateDownloadTargetPath`n"
        }
        else {
            Write-Error "File sizes between what it is and what it should be doesn't match."
            throw "Failed to succesfully download the game update file. Do not use it, it's corrupted."
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Host "Details: $($_.Exception.InnerException.Message)"
        }
        throw "An error occurred while downloading the game update file"
    }
}

# Parse the game's XML metadata
function Parse-GameXml {
    Write-Host "Parsing XML metadata of $GameID`n"

    [xml]$response = Get-GameXml
    if (-not $response) {
        throw "Invalid XML metadata of $GameID"
    }

    [xml]$tree = $response
    $xmlGameID = $tree.titlepatch.titleid

    # If multiple game updates are available and
    # only one TITLE is present in one of the 'package'
    # sections of the whole XML file, then extract it first
    # to use it for all of the updates.
    $xmlGameName = ""
    foreach ($xml in $tree.titlepatch.tag.package) {
        if ($xml.paramsfo -and $xml.paramsfo.TITLE) {
            $xmlGameName = $xml.paramsfo.TITLE -replace "`n", " "
        }
    }

    # Get the data
    $allGameUpdates = @()
    foreach ($xml in $tree.titlepatch.tag.package) {
        $allGameUpdates += [PSCustomObject]@{
            GameId       = $xmlGameID
            GameVersion  = $xml.version
            GameSizeInMB = Convert-BytesToMegabytes -Size $xml.size
            GameSizeInB  = $xml.size
            GameSysver   = $xml.ps3_system_ver
            GameUrl      = $xml.url
            GameName     = $xmlGameName
        }
    }

    return $allGameUpdates
}

# Handle the process of getting the game update
function Get-GameUpdate {
    # Get all the game update data
    $GameUpdates = Parse-GameXml
    $overwriteAll = $false

    foreach ($update in $GameUpdates) {
        # Get the base file name of the update file
        $GameUpdateBaseName = $update.GameUrl.Split('/')[-1]

        if (Test-FileExistence -FilePath "$GameUpdateDownloadTargetPath\$GameUpdateBaseName") {
            Write-Host "This game update file is already downloaded"

            # Go automatic
            if ($overwriteAll -eq $true) {
                Write-Host "Overwriting..."

                Write-Host "Requesting download for: $($update.GameName) $($update.GameVersion) ($($update.GameId)) - $($update.GameSizeInMB)"
                Download-GameUpdate -GameUpdateUrl $update.GameUrl -GameUpdateName $GameUpdateBaseName -GameUpdateSize $update.GameSizeInB
                continue
            }

            # Handle overwriting process
            $promptForOverwrite = Read-Host "Do you want to overwrite it? (y/n/a)"
            if ($promptForOverwrite.ToLower() -eq "y" -or $promptForOverwrite.ToLower() -eq "yes") {
                Write-Host "`nRequesting download for: $($update.GameName) $($update.GameVersion) ($($update.GameId)) - $($update.GameSizeInMB)"
                Download-GameUpdate -GameUpdateUrl $update.GameUrl -GameUpdateName $GameUpdateBaseName -GameUpdateSize $update.GameSizeInB
            }
            elseif ($promptForOverwrite.ToLower() -eq "a" -or $promptForOverwrite.ToLower() -eq "all") {
                Write-Host "Overwriting all without prompting...`n"
                $overwriteAll = $true
            }
            else {
                Write-Host "Not overwriting..."
                continue
            }
        }
        else {
            Write-Host "Requesting download for: $($update.GameName) $($update.GameVersion) ($($update.GameId)) - $($update.GameSizeInMB)"
            Download-GameUpdate -GameUpdateUrl $update.GameUrl -GameUpdateName $GameUpdateBaseName -GameUpdateSize $update.GameSizeInB
        }
    }
}

function Convert-BytesToMegabytes {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Size
    )

    return ($Size / 1MB).ToString("n2") + " MB"
}

function Test-FileExistence {
    param ( [Parameter(Mandatory = $true)]
        [string]$FilePath )
    
    if (Test-Path -Path $FilePath) {
        return $true
    }
    else {
        return $false
    } 
}

Write-Host "ps3gameupd_dl v$ProgramVersion`n"
Validate-GameID

# Skip SSL certificate validation for the PlayStation server,
# because it doesn't work and otherwise the download fails
# due to an SSL error.

# Thanks, what a headache this was: https://stackoverflow.com/a/57422713
Add-Type -Language CSharp @"
namespace System.Net {
public static class Util {
public static void Init() {
ServicePointManager.ServerCertificateValidationCallback = null;
ServicePointManager.ServerCertificateValidationCallback += (sender, cert, chain, errs) => true;
ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls12;
}}}
"@
[System.Net.Util]::Init()
Get-GameUpdate

Write-Host "Thank you for using ps3gameupd_dl! :)"