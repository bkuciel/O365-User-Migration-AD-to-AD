# Copyright Bartosz Kuciel
# Script used to "migrate" user - AD to AD within one Tennant - detach AD User in Domain A from O365 user, and attach user from domain B to O365 account
# Function "ConvertTo-ImmutableID" is a part of PSSharedGoods module created by - Evotec on MIT License https://github.com/EvotecIT/PSSharedGoods
# "region Enable-RemoteMailbox" is an optional step for creating remote mailbox on Exchange server in domain B pointing to O365 user
# "region connection" uses Export-CliXml / Import-CliXml to securely save and load credentials. See: https://github.com/bkuciel/Powershell_Scripts/blob/main/Code/Export-Clixml_multiple_credentials.ps1

[CmdletBinding()] param ()

#region connection 
try {
    $creds = Import-Clixml -Path "${env:\userprofile}\cred.clixml" 
}
catch {
    Write-Verbose $_
}
try {
        $var = Get-AzureADTenantDetail
}
catch [Microsoft.Open.Azure.AD.CommonLibrary.AadNeedAuthenticationException] {
        Write-Host "Estabilishing connection to AzureAD"
        if ($null -eq $creds.ADM) 
        {
            $creds = @{}
            $creds.ADM = Get-Credential -Message 'ADM Credentials'
        }
        try {
            Connect-AzureAD -Credential $creds.ADM
        }
        catch {
            $message = $_
            Write-Warning -Message "Problem with credentials: $message"
            break
        }
}

try {
        $var = Get-MsolDomain -ErrorAction Stop
}
catch {
        Write-Host "Estabilishing connection to O365"
        if ($null -eq $creds.ADM) 
        {
            $creds = @{}
            $creds.ADM = Get-Credential -Message 'ADM Credentials'
        }
        try {
            Connect-MsolService -Credential $creds.ADM    
        }
        catch{
            $message = $_
            Write-Warning -Message "Problem with credentials: $message"
            break
        }
}
#endregion


#region functions
function ConvertTo-ImmutableID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ParameterSetName = 'User')]
        [alias('ADuser')]
        [Microsoft.ActiveDirectory.Management.ADAccount] $User,

        [Parameter(Mandatory = $false, ParameterSetName = 'Guid')]
        [alias('GUID')]
        [string] $ObjectGUID
    )
    if ($User) {
        if ($User.ObjectGUID) {
            $ObjectGUID = $User.ObjectGuid
        }
    }
    if ($ObjectGUID) {
        $ImmutableID = [System.Convert]::ToBase64String(($User.ObjectGUID).ToByteArray())
        return $ImmutableID
    }
    return
}
Function Start-Countdown 
{  
    Param(
        [Int32]$Seconds = 10,
        [string]$Message = "Pausing for 10 seconds..."
    )
    ForEach ($Count in (1..$Seconds))
    {   Write-Progress -Id 1 -Activity $Message -Status "Waiting for $Seconds seconds, $($Seconds - $Count) left" -PercentComplete (($Count / $Seconds) * 100)
        Start-Sleep -Seconds 1
    }
    Write-Progress -Id 1 -Activity $Message -Status "Completed" -PercentComplete 100 -Completed
}
#endregion

$domainAUser = Read-Host "domainAUser UPN? " #User from domain A
try {
    $var = get-aduser -Server "server1.domainA.local" -filter "userprincipalname -eq '$domainAUser'"
}
catch {
    $message = $_
    Write-Host "Problem with domainAUser UPN: $message" -ForegroundColor Red
    break
}
Write-host "Found " $var.Name", " $var.Userprincipalname "in domainA.local" -ForegroundColor Yellow
Write-Host "Distinguished Name: " $var.DistinguishedName -ForegroundColor Yellow

$domainBUser = Read-Host "domainBUser UPN? "
try {
    $processed_user = Get-ADUser -filter {UserPrincipalName -eq $domainBUser} -Properties mail
}
catch {
    Write-Host "Problem with domainBUser UPN: $message" -ForegroundColor Red
    break
}
Write-Host "Found " $processed_user.Name ", " $processed_user.UserPrincipalName "in domainB.local" -ForegroundColor Yellow
Write-Host "Distinguished Name: " $processed_user.DistinguishedName -ForegroundColor Yellow

$location = Read-host "User OU Location (branch1/branch2)?"
switch ($location)
{
    'branch1' {$targetOU = "OU=Users,OU=Branch1,DC=DomainB,DC=local"}
    'branch2' {$targetOU = "OU=Users,OU=Branch2,DC=DomainB,DC=local"}
    default  {Write-host "Input not recognized. Stopping script"; exit}
}


#[o365] Restore User
try{
        Restore-MsolUser -UserPrincipalName $domainAUser -NewUserPrincipalName $processed_user.UserPrincipalName
        Write-Host "User Restored.. Waiting 2 min" -ForegroundColor Green
        Start-Countdown -Seconds 120 -Message "Waiting for processing o365 changes"
    }
catch{
        throw $_
        break
     }


#Set
$ImmutableID = ConvertTo-ImmutableID -User $processed_user
Write-Host "Setting ImmutableID" -ForegroundColor Yellow
$o365user = $processed_user.UserPrincipalName
try{
        Set-AzureADUser -ObjectId $o365User -ImmutableId $ImmutableID
    }
catch{
    throw $_
    break
    }



#region Compare
$o365compare = Get-AzureADUser -ObjectId $o365User | select ImmutableId
if ($o365compare.ImmutableId -eq $ImmutableID)
{
    Write-Host " AD ImmutableID match with O365 ImmutableID " -ForegroundColor white -backgroundcolor green
}
else 
{
    Write-Host "ImmutableID NOT MATCH. Stopping script" -ForegroundColor Red 
    break
}
#endregion

#[AD] MoveUser
Write-Host "Moving user to target OU.." -ForegroundColor Green
$processed_user | Move-ADObject -TargetPath $targetOU -Server DC1.domainB.local


#[ADConnect] Start-Sync
Write-host "Waiting 2 mins for sync in AD" -ForegroundColor Yellow
Start-Countdown -Seconds 120 -Message "Waiting 2 mins for AAD sync"
Write-Host "Starting sync.." -ForegroundColor Green
Invoke-Command -ComputerName ADConnect.domainB.local -ScriptBlock {Start-ADSyncSyncCycle -policytype delta}
Write-Host "Sync Started.." -ForegroundColor Green
Start-Countdown -Seconds 120 -Message "Waiting 2 mins for second AAD sync"
Invoke-Command -ComputerName ADConnect.domainB.local -ScriptBlock {Start-ADSyncSyncCycle -policytype delta}
Write-Host "Second Sync Started.." -ForegroundColor Green
Start-Countdown -Seconds 60 -Message "Waiting for results of sync"
Write-Host "Done" -ForegroundColor Green


#region Enable-RemoteMailbox
#[Exchange] Enable-RemoteMailbox
Write-host "Enabling EXCH Remote Mailbox" -ForegroundColor Yellow
if ($null -eq $creds.DOM)
{
    $creds.DOM = Get-Credential -Message 'DOM Credentials'
}
try {
    $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://Exchange1.domainB.local/PowerShell/ -Authentication Kerberos -Credential $Creds.DOM
    Import-PSSession $Session -DisableNameChecking
}
catch {
    $message = $_
    Write-Warning -Message "Problem with connecting to Exchange1.domainB.local: $message"
    break
}


$EXO_user= $processed_user.SamAccountName
$EXO_extmail= $processed_user.mail
try 
{
    Enable-RemoteMailbox "$EXO_user" -RemoteRoutingAddress $EXO_extmail | Out-Null
    Write-Host "RemoteMailbox enabled" -ForegroundColor Green
}
catch
{
    $message = $_
    Write-Warning -Message "Enabling Remote Mailbox failed: $message"
}

#Verification: 
Write-Host "Verification" -ForegroundColor Yellow
Get-Recipient $EXO_user | select  Name, Recipienttype, RecipientTypeDetails

#Disconnect
Remove-PSSession $Session
#endregion

Write-Host "Migration done" -ForegroundColor Green