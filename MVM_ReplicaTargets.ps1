# ====================================================================
# Author: Tiago DA SILVA - ATHEO INGENIERIE
# Version: 1.0.1
# Creation Date: 2024-11-29
# Last Update: 2024-12-02
# GitHub Repository: https://github.com/TiagoDSLV/MyVeeamMonitoring
# ====================================================================
#
# Description:
# This PowerShell script monitors the storage usage of replica targets in 
# Veeam Backup & Replication (VBR). It calculates the used, free, and total
# storage on replica targets and compares the storage usage to specified 
# thresholds (Warning and Critical). The script provides an alert if any 
# replica target exceeds the defined thresholds, with a custom message 
# detailing the status of each target.
#
# Parameters:
# - Warning: Defines the storage usage percentage at which a warning will be triggered. - Default is 80%.
# - Critical: Defines the storage usage percentage at which a critical alert will be triggered - Default is 90 %.
# - ExcludedTargets: A comma-separated list of target names to exclude from monitoring. 
#
# Returns:
#   - OK: If all replica targets are below the defined thresholds.
#   - Warning: If one or more replica targets exceed the Warning threshold but not the Critical threshold.
#   - Critical: If one or more replica targets exceed the Critical threshold.
#   - Unknown: If no replica targets are found or an error occurs.
#
# ====================================================================

#region Parameters
param (
    [int]$Warning = 80,   # Warning threshold for storage usage percentage
    [int]$Critical = 90,  # Critical threshold for storage usage percentage
    [string]$ExcludedTargets = ""  # List of Target names to exclude from monitoring
)
#endregion

#region Functions
# Functions for returning exit codes (OK, Warning, Critical, Unknown)
function Exit-OK { param ([string]$message) if ($message) { Write-Host "OK - $message" } exit 0 }
function Exit-Warning { param ([string]$message) if ($message) { Write-Host "WARNING - $message" } exit 1 }
function Exit-Critical { param ([string]$message) if ($message) { Write-Host "CRITICAL - $message" } exit 2 }
function Exit-Unknown { param ([string]$message) if ($message) { Write-Host "UNKNOWN - $message" } exit 3 }

# Function to connect to the VBR server
function Connect-VBRServerIfNeeded {
    $vbrServer = "localhost"  # Veeam Backup & Replication server address
    $credentialPath = ".\scripts\MyVeeamMonitoring\key.xml"  # Path to credentials file for connection
    
    # Check if a connection to the VBR server is already established
    $OpenConnection = (Get-VBRServerSession).Server
    
    if ($OpenConnection -ne $vbrServer) {
        # Disconnect existing session if connected to a different server
        Disconnect-VBRServer
        
        if (Test-Path $credentialPath) {
            # Load credentials from XML file
            try {
                $credential = Import-Clixml -Path $credentialPath
                Connect-VBRServer -server $vbrServer -Credential $credential -ErrorAction Stop
            } Catch {
                Exit-Critical "Unable to load credentials from the XML file."
            }
        } else {
            # Connect without credentials if file does not exist
            try {
                Connect-VBRServer -server $vbrServer -ErrorAction Stop
            } Catch {
                Exit-Critical "Unable to connect to the VBR server."
            }
        }
    }
}

# Retrieves all replica target information
Function Get-VBRReplicaTarget {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline=$true)]
        [PSObject[]]$InputObj
    )

    BEGIN {
        $outputAry = @()  # Initialize an array for output data
        $dsAry = @()  # Initialize an array to track processed datastores
    }

    PROCESS {
        foreach ($obj in $InputObj) {
            # Skip if the datastore has already been processed
            if ($dsAry -contains $obj.ViReplicaTargetOptions.DatastoreName) {
                continue
            }

            # Retrieve the datastore and calculate storage usage
            $esxi = $obj.GetTargetHost()  # Get the ESXi host
            $dtstr = $esxi | Find-VBRViDatastore -Name $obj.ViReplicaTargetOptions.DatastoreName  # Find the datastore by name
            $StorageFree = [Math]::Round([Decimal]$dtstr.FreeSpace / 1GB, 2)  # Calculate free storage in GB
            $StorageTotal = [Math]::Round([Decimal]$dtstr.Capacity / 1GB, 2)  # Calculate total storage
            $StorageUsed = $StorageTotal - $StorageFree  # Calculate used storage in GB
            $FreePercentage = [Math]::Round(($dtstr.FreeSpace / $dtstr.Capacity) * 100)  # Calculate free storage percentage
            $UsedPercentage = 100 - $FreePercentage  # Calculate used storage percentage

            # Prepare the output object
            $objoutput = [PSCustomObject]@{
                Datastore       = $obj.ViReplicaTargetOptions.DatastoreName  # Datastore name
                StorageFree     = $StorageFree  # Free storage in GB
                StorageUsed     = $StorageUsed  # Used storage in GB
                StorageTotal    = $StorageTotal  # Total storage in GB
                FreePercentage  = $FreePercentage  # Free storage percentage
                UsedPercentage  = $UsedPercentage  # Used storage percentage
            }

            # Add the datastore name to the list and the result to the output array
            $dsAry += $obj.ViReplicaTargetOptions.DatastoreName
            $outputAry += $objoutput
        }
    }

    END {
        # Return the output
        $outputAry | Select-Object Datastore, StorageFree, StorageUsed, StorageTotal, FreePercentage, UsedPercentage
    }
}
#endregion

#region Validate Parameters
# Validate that the Critical threshold is greater than the Warning threshold
if ($Critical -le $Warning) {
    Exit-Critical "Invalid parameter: Critical threshold ($Critical) must be greater than Warning threshold ($Warning)."
}
# Validate that the parameters are non-empty if they are provided
if ($ExcludedTargets -and $ExcludedTargets -notmatch "^[\w\.\,\s\*\-_]*$") {
    Exit-Critical "Invalid parameter: 'ExcludedTargets' contains invalid characters. Please provide a comma-separated list of target names."
  }
#endregion

#region Connection to VBR Server
Connect-VBRServerIfNeeded
#endregion

#region Variables
$ExcludedTargetsArray = $ExcludedTargets -split ','  # Split the ExcludedTargets string into an array
$outputStats = @()  # Initialize an array to store the output statistics
#endregion

try {
    # Retrieve all replica target information
    $repTargets = Get-VBRJob -WarningAction SilentlyContinue | 
    Where-Object {$_.JobType -eq "Replica"} | 
    Get-VBRReplicaTarget | 
    Select-Object @{Name="Name"; Expression={$_.Datastore}},
                    @{Name='UsedStorageGB'; Expression={$_.StorageUsed}},
                    @{Name="FreeStorageGB"; Expression={$_.StorageFree}},
                    @{Name="TotalStorageGB"; Expression={$_.StorageTotal}},
                    @{Name="FreeStoragePercent"; Expression={$_.FreePercentage}},
                    @{Name="UsedStoragePercent"; Expression={$_.UsedPercentage}},
                    @{Name="Status"; Expression={
                    if ($_.UsedPercentage -ge $Critical) { "Critical" }
                    elseif ($_.UsedPercentage -ge $Warning) { "Warning" }
                    else { "OK" }
                    }}

    # Create a regular expression to exclude specified target from monitoring
    $ExcludedTargets_regex = ('(?i)^(' + (($ExcludedTargetsArray | ForEach-Object {[regex]::escape($_)}) -join "|") + ')$') -replace "\\\*", ".*"
    $filteredrepTargets = $repTargets | Where-Object {$_.Name -notmatch $ExcludedTargets_regex}

    If ($filteredrepTargets.count -gt 0) {

        # Separate critical and warning targets
        $criticalRepTargets = @($filteredrepTargets | Where-Object {$_.Status -eq "Critical"})
        $warningRepTargets = @($filteredrepTargets | Where-Object {$_.Status -eq "Warning"})

        foreach ($target in $filteredrepTargets) {
            $name = $target.Name -replace ' ', '_'  # Replace spaces in the name with underscores
            $totalGB = $target.TotalStorageGB  # Total storage in GB
            $usedGB = $target.UsedStorageGB  # Used storage in GB
            $prctUsed = $target.UsedStoragePercent  # Used storage percentage
        
            # Convert Warning and Critical thresholds to absolute storage in GB
            $warningGB = [Math]::Round(($Warning / 100) * $totalGB, 2)
            $criticalGB = [Math]::Round(($Critical / 100) * $totalGB, 2)
            
            # Construct strings for the output
            $targetStats = "$name=${usedGB}GB;$warningGB;$criticalGB;0;$totalGB"
            $prctUsedStats = "${name}_prct_used=$prctUsed%;$Warning;$Critical"
            
            # Append to the output array
            $outputStats += "$targetStats $prctUsedStats"
        }

    # Prepare output for critical and warning targets
        $outputCritical = ($criticalRepTargets | Sort-Object { $_.FreeStoragePercent } | ForEach-Object {
            "$($_.Name) - Used: $($_.UsedStoragePercent)% ($($_.FreeStorageGB)GB / $($_.TotalStorageGB)GB)"
        }) -join ", "
        $outputWarning = ($warningRepTargets | Sort-Object { $_.FreeStoragePercent } | ForEach-Object {
            "$($_.Name) - Used: $($_.UsedStoragePercent)% ($($_.FreeStorageGB)GB / $($_.TotalStorageGB)GB)"
        }) -join ", "

    # Exit with appropriate status based on critical and warning targets
        If ($criticalRepTargets.count -gt 0) {
        Exit-Critical "$($criticalRepTargets.count) critical target(s): $outputCritical|$outputStats"
    } ElseIf ($warningRepTargets.count -gt 0) {
        Exit-Warning "$($warningRepTargets.count) warning target(s): $outputWarning|$outputStats"
    } Else {
        Exit-OK "All targets are OK|$outputStats"
        }
    } Else {
        Exit-Unknown "No replica targets found"
    }
} Catch {
    Exit-Critical "An error occurred: $($_.Exception.Message)"
}