# ====================================================================
# Script PowerShell : Vérification et gestion des sessions de sauvegarde Veeam
# Auteur : Tiago DA SILVA - ATHEO INGENIERIE
# Description : Ce script vérifie l'état des sessions de sauvegarde Veeam
#               et retourne des messages d'alerte en fonction du statut des tâches.
# Version : 1.0.2
# Date de création : 2024-11-29
# Dernière mise à jour : 2024-12-02
# Dépôt GitHub : https://github.com/ATHEO-TDS/MyVeeamMonitoring
# ====================================================================
#
# Ce script permet de surveiller les tâches de sauvegarde dans Veeam Backup & Replication
# et d'envoyer des alertes basées sur le statut des sauvegardes.
# Il analyse les sessions récentes en fonction de l'heure définie par le paramètre `$RPO`,
# en signalant toute session ayant échoué, étant en avertissement ou en échec et en attente de reprise.
#
# L'objectif est d'assurer un suivi efficace des sauvegardes et de signaler rapidement tout
# problème éventuel nécessitant une attention particulière.
#
# Veuillez consulter le dépôt GitHub pour plus de détails et de documentation.
#
# ====================================================================

#region Arguments
param (
    [int]$RPO
)
#endregion

#region Update Configuration
$repoURL = "https://raw.githubusercontent.com/ATHEO-TDS/MyVeeamMonitoring/main"
$scriptFileURL = "$repoURL/SDSup_Backup.ps1"
$localScriptPath = $MyInvocation.MyCommand.Path
#endregion

#region Functions      
    #region Fonction Get-VersionFromScript
        function Get-VersionFromScript {
            param (
                [string]$scriptContent
            )
            # Recherche une ligne contenant '#Version X.Y.Z'
            if ($scriptContent -match "# Version\s*:\s*([\d\.]+)") {
                return $matches[1]
            } else {
                Write-Error "Impossible de trouver la version dans le script."
                return $null
            }
        }
    #endregion

    #region Fonctions Handle NRPE
        function Handle-OK {
            param (
                [string]$message
            )

            if ($message) {
                Write-Host "OK - $message"
            }
            exit 0
        }

        function Handle-Warning {
            param (
                [string]$message
            )

            if ($message) {
                Write-Host "WARNING - $message"
            }
            exit 1
        }

        function Handle-Critical {
            param (
                [string]$message
            )

            if ($message) {
                Write-Host "CRITICAL - $message"
            }
            exit 2
        }

        function Handle-Unknown {
            param (
                [string]$message
            )

            if ($message) {
                Write-Host "UNKNOWN - $message"
            }
            exit 3
        }
    #endregion

    #region Fonction GetVBRBackupSession
        function GetVBRBackupSession {
            $Type = @("Backup")
            foreach ($i in ([Veeam.Backup.DBManager.CDBManager]::Instance.BackupJobsSessions.GetAll())  | Where-Object {($_.EndTime -ge (Get-Date).AddHours(-$HourstoCheck) -or $_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck) -or $_.State -eq "Working") -and $_.JobType -in $Type})
        { 
                        $sessionProps = @{ 
                        JobName = $i.JobName
                        JobType = $i.JobType
                        SessionId = $i.Id
                        SessionCreationTime = $i.CreationTime
                        SessionEndTime = $i.EndTime
                        SessionResult = $i.Result.ToString()
                        State = $i.State.ToString()
                        Result = $i.Result
                        Failures = $i.Failures
                        Warnings = $i.Warnings
                        WillBeRetried = $i.WillBeRetried
                }  
                New-Object PSObject -Property $sessionProps 
            }
        }
    #endregion
#endregion

#region Update 
# --- Extraction de la version locale ---
$localScriptContent = Get-Content -Path $localScriptPath -Raw
$localVersion = Get-VersionFromScript -scriptContent $localScriptContent

# --- Récupération du script distant ---
$remoteScriptContent = Invoke-RestMethod -Uri $scriptFileURL -Headers $headers -UseBasicParsing

# --- Extraction de la version distante ---
$remoteVersion = Get-VersionFromScript -scriptContent $remoteScriptContent

# --- Comparaison des versions et mise à jour ---
if ($localVersion -ne $remoteVersion) {
    try {
        # Écrase le script local avec le contenu distant
        $remoteScriptContent | Set-Content -Path $localScriptPath -Force
    } catch {
    }
}
#endregion

#endregion

#region Variables
$vbrServer = "localhost"
$HourstoCheck = $RPO
$criticalSessions = @()
$warningSessions = @()
$allSessionDetails = @()
#endregion

#region Connect to VBR server
$OpenConnection = (Get-VBRServerSession).Server
If ($OpenConnection -ne $vbrServer){
    Disconnect-VBRServer
    Try {
        Connect-VBRServer -server $vbrServer -ErrorAction Stop
    } Catch {
        handle_critical "Unable to connect to the VBR server."
    exit
    }
}
#endregion

try {
    # Get all backup session
    $sessListBk = @(GetVBRBackupSession)
    $sessListBk = $sessListBk | Group-Object JobName | ForEach-Object { $_.Group | Sort-Object SessionEndTime -Descending | Select-Object -First 1}
    if (-not $sessListBk) {
        Handle-Unknown "No Backup Session found."
    }
        
    # Iterate over each collection
    foreach ($session in $sessListBk) {
        $sessionName = $session.JobName
        $quotedSessionName = "'$sessionName'"

        $sessionResult = @{
            "Success" = 0
            "Warning" = 1
            "Failed" = 2
        }[$session.Result]

        # Append session details
        $allSessionDetails += "$quotedSessionName=$sessionResult;1;2"

        if ($sessionResult -eq 2) {
            $criticalSessions += "$sessionName"
        } elseif ($sessionResult -eq 1) {
            $warningSessions += "$sessionName"
        }
    }

    $sessionsCount = $allSessionDetails.Count

    # Construct the status message
    if ($criticalSessions.Count -gt 0) {
        $statusMessage = "At least one failed backup session : " + ($criticalSessions -join " / ")
        $status = "CRITICAL"
    } elseif ($warningSessions.Count -gt 0) {
        $statusMessage = "At least one backup session is in a warning state : " + ($warningSessions -join " / ")
        $status = "WARNING"
    } else {
        $statusMessage = "All backup sessions are successful ($sessionsCount)"
        $status = "OK"
    }

    # Construct the statistics message
    $statisticsMessage = $allSessionDetails -join " "

    # Construct the final message
    $finalMessage = "$statusMessage|$statisticsMessage"

    # Handle the final status
    switch ($status) {
        "CRITICAL" { Handle-Critical $finalMessage }
        "WARNING" { Handle-Warning $finalMessage }
        "OK" { Handle-OK $finalMessage }
    }

} catch {
    Handle-Critical "An error occurred: $_"
}

