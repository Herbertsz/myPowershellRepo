<#

    .SYNOPSIS
    This script creates Dynamic Distribution Groups for Exchange and/or Onedrive in AzureAD,
    and queries groups based on given input parameters.


    .NOTES
    Author: Herbert Szumovski

    This is an update of David Bewernick's VBO-CreateDynamicGroups.ps1, which you can find here:
    https://github.com/VeeamHub/powershell/tree/master/VBO-CreateDynamicGroups

    The following was added:
    1) configurable group count for creation of new groups between 2 and 256 (but 
        limited by a uservariable to 64, so that Admins do not clutter their environment with 
        hundreds of groups without thinking twice). 
    2) query of existing AzureAD groups to see, how many users they currently contain,
    3) Check the groupnames and their dynamic membership rules on your screen, before you
        shoot them up into AzureAD.
    4) Function to delete groups in AzureAD.

    This is no official Veeam software, I just created this for convenience of my customers.
    Though checked on a best effort basis, it may contain errors.
    Use at your own risk, and check, if the resulting distribution groups fulfill your needs.


    .DESCRIPTION
    Via dynamic distribution groups AzureAD will dynamically add new users in a way so
    that the users are automatically roughly balanced between all groups, so no manual 
    changes are ever necessary.
       You get the most balanced user distribution, if you use a group count which is
    a power of 2 (so 2,4,8,16,32,64, and if you extend the $limitGroups variable, then
    also 128 and 256. But however, also the other numbers will result in the best possible
    distribution which can be reached via this algorithm. 

    How it works:
    The groups made by this script inherit the userids based on the contents of their 
    respective AzureAD object-id. Byte 27 and 28 of the object-id are used to distribute
    the users across the groups (if not more than 16 groups are created, a lighter
    algorithm is used, targetting only byte 27).
    
    For the OneDrive groups the userassigned serviceplan IDs for Onedrive are also used
    for comparison, so users without Onedrive access are not included there.

    .USAGE
    When the script starts, it checks, if there is an AzureAD session available from a prior run.
    If yes, it is used again, if no, it prompts you for a login. 
    To end the AzureAD session after the final run, specify the "-logout" parameter.

    "-ExchGrp"          :  creates dynamic distributiongroups for Exchange backup

    "-ODGrp"            :  creates dynamic distributiongroups for Onedrive backup

    "-create"           :  per default the generated groupnames and their AzureAD
                dynamic membership rules will be displayed only, but not really created. 
                To create them for AzureAD production you must specify this parameter.

    "-groups" <number>  :  number of groups which should be created. 
                Must be an integer between 2 and 64. Can only be specified with
                one or both of the above 2 parameters. (The group creation limit 
                could be extended up to 256 via the "$limitGroups" variable, if you
                would need for some reason that many groups).

    "-ignoreDisabledAcc :  Disabled accounts are backed up by default, if they 
                have a mailbox (often customers disable sharedmailbox accounts, but
                still want to backup the shared mailboxes). If you do not
                want to backup disabled accounts, use this switch to ignore them.
                It can only be used together with "-ODGrp" and/or "ExchGrp" parameter.

    "-queryGrp" <string>:  displays AzureAD groups found by search criteria <string>
                           The search criteria may contain generic chars '?' and '*', and
                           is case sensitive.

    "-delGrp"   <string>:  deletes AzureAD groups found by search criteria <string>, after
                           confirmation. Generic chars '?' and '*' are allowed, but only
                           in combination with alphanumeric chars. 
                           So something like "*" or "???*" is forbidden.
                           The search criteria is case sensitive. 

    "-logout"           :  the script logs out of the current AzureAD session it
                has just used. By default the session is kept running, for being 
                able to run the script several times without the need for
                multiple logins. If "-logout" is not used, a yellow warning 
                message tells you, that the AzureAD session is still there.

    without parameters  :  displays help 

    "-help"             :  displays help



    Last Updated: May 2022
    Version: 1.72
	
	Fixes: 
        2022-04-01, V1.0 : First version
        2022-04-02, V1.1 : Added OneDrive groups and parameter for flexible number of 
                           groups creation between 2 and 16
        2022-04-03, V1.2 : Added group display, optional AzureAD logout and usercount per group
        2022-05-01, V1.3 : Added separate parameter for group dispay, added help display
        2022-05-03, V1.4 : Fixed bug which included users without a mailbox into the Exchange group
        2022-05-08, V1.5 : Added choice to ignore disabled accounts 
        2022-05-14, V1.6 : Changed algorithm so that up to 256 groups can be created, but limited the
                           parameter input to 64 via a user variable.
        2022-05-15, V1.7 : Added a delete function.
        2022-05-19, V1.71: Minor cosmetic appearance changes.
        2022-05-22, V1.72: Minor cosmetic appearance changes.

    Requires:
    To run the script you must install the Microsoft AzureAdPreview Powershell module:

    Install-Module AzureAdPreview -Scope CurrentUser

    If your Powershell environment is untouched, you must possibly use this command before:

    Register-PSRepository -Default -InstallationPolicy Trusted

 #>

#Requires -Modules AzureAdPreview

[CmdletBinding(PositionalBinding=$False)]  

Param(
    # Generates dynamic distribution groups for Exchange
    [switch] $ExchGrp,

    # Generates dynamic distribution groups for Onedrive
    [switch] $ODGrp,

    # Per default the groups and their dynamic membership rules are only displayed for review.
    # To really create them in AzureAD you must specify this parameter.
    [switch] $create,

    # Do not backup disabled accounts even if they have a mailbox or OD data
    [switch] $ignoreDisabledAcc,

    # Specifies the number of groups you want to generate (limited to 64 by uservariable below)
    [int] $groups = 0,

    # Displays the groups you select (also "?" and "*" are allowed), and their current number of users.
    # It may take up to 24 hours until new groups contain their correct number of users.
    # Take care: If you have many groups and use "-qGroups * ", the resulting display could take a long time.
    [STRING[]] $queryGrp,

    # Deletes the groups you select, after confirmation. Though generic chars "?" and "*" are
    # allowed in the selection string, they must always be combined with alphanumeric chars, which
    # means, something like "*" or "???*" is forbidden.
    [STRING[]] $delGrp,

    # Logout from AzureAD when script exits
    [switch] $logout,

    # Display help
    [SWITCH] $help   
);
<#---------------------------------------------------------------------------------------------------
    Uservariables: 
    The groupNamePrefix can be changed to fulfill your group naming conventions.
    The limitGroups can be changed up to a value of 256, if you would need that much groups.
---------------------------------------------------------------------------------------------------#>
[string]    $groupNamePrefix = "Veeam_"
[int32]     $limitGroups = 64
<#---------------------------------------------------------------------------------------------------
    End of uservariables. 
    Don't change anything below, except if you know what you are doing. :-)
---------------------------------------------------------------------------------------------------#>    


#--------------------- Function for help display
function vbmHelp() { return Get-Content $PSCommandPath -TotalCount 100 | Select-String -Pattern '.USAGE' -Context 0,44 }

#--------------------- Function for AzureAD Login
function AzureADLogin() {

    if($null -eq $Global:AccountID) {
        Write-Log -Info "Trying to connect to AzureAD..." -Status Info
        try {
            $azureConnection = Connect-AzureAD
            $Global:AccountID = $azureConnection.Account.id
            Write-Log -Info "Connection successful with $Global:AccountID" -Status Info
        } 
        catch  {
            Write-Log -Info "$_" -Status Error
            Write-Log -Info "Could not connect with AzureAD." -Status Error
            exit 99
        }
    }
}

#--------------------- Function for logmessage writing
function Write-Log($Info, $Status) {

    $timestamp = get-date -Format "yyyy-MM-dd HH:mm:ss"
    $LogFile = "VBM365-DynamicGroups.log" 

    switch($Status) {
        Info    {Write-Host "$timestamp $Info" -ForegroundColor Green  ; "Infos $timestamp $Info" | Out-File -FilePath $LogFile -Append}
        Status  {Write-Host "$timestamp $Info" -ForegroundColor Yellow ; "State $timestamp $Info" | Out-File -FilePath $LogFile -Append}
        Warning {Write-Host "$timestamp $Info" -ForegroundColor Yellow ; "Warng $timestamp $Info" | Out-File -FilePath $LogFile -Append}
        Error   {Write-Host "$timestamp $Info" -ForegroundColor Red    ; "Error $timestamp $Info" | Out-File -FilePath $LogFile -Append}
        default {Write-Host "$timestamp $Info" -ForegroundColor white  ; "State $timestamp $Info" | Out-File -FilePath $LogFile -Append}
    }
}
	
#--------------------- Function to create dynamic distributiongroups for Exchange	
function New-ExGroups($NoBackupDisabledAcc, $arrchar, $strGrpNames){ 
										 
    $j=0 
               
    while($j -lt $arrChar.length) { 							  
        $strRegex = $arrChar[$j] 		  
        $strGroupName = $strGrpNames[$j]
        $strMembershipRule = '(user.objectID -match "' + $strRegex + '") -and (user.mail -ne null)' + $NoBackupDisabledAcc

        if($null -eq (Get-AzureADMSGroup | Where-Object{$_.DisplayName -eq $strGroupName})) {
            try {
                New-AzureADMSGroup -DisplayName "$strGroupName" -MailNickname "$strGroupName" `
                    -Description "Group for VBO Exchange backup with rule $strRegex" -MailEnabled $false -GroupTypes {DynamicMembership} `
                    -SecurityEnabled $true -MembershipRule "$strMembershipRule" -MembershipRuleProcessingState 'on' > $null		
                Write-Log -Info "Group $strGroupName created with MembershipRule:`n $strMembershipRule `n" -Status Info
            }
            catch{
                Write-Log -Info "$_" -Status Error
                Write-Log -Info "Group $strGroupName could not be created" -Status Error
                exit 99
            }
        }
        else { 
            Write-Log -Info "Group $strGroupName already exists, nothing changed." -Status Status
        } 
        $j++
    }
}

#--------------------- Function to create dynamic distributiongroups for OneDrive
function New-ODGroups($NoBackupDisabledAcc, $OneDriveAssignedPlan, $arrChar, $strGrpNames){ 										 
    
    $j = 0 
               
    while($j -lt $arrChar.length){ 							  
        $strRegex = $arrChar[$j] 		 
        $strGroupName = $strGrpNames[$j]
        $strMembershipRule = '(user.objectID -match "' + $strRegex + '") ' + $NoBackupDisabledAcc + '-and ' + $OneDriveAssignedPlan

        if($null -eq (Get-AzureADMSGroup | Where-Object{$_.DisplayName -eq $strGroupName})) {
            try {
                New-AzureADMSGroup -DisplayName "$strGroupName" -MailNickname "$strGroupName" `
                    -Description "Group for VBO OneDrive backup with rule $strRegex" -MailEnabled $false -GroupTypes {DynamicMembership} `
                    -SecurityEnabled $true -MembershipRule "$strMembershipRule" -MembershipRuleProcessingState 'on' > $null		
                Write-Log -Info "Group $strGroupName created with MembershipRule:`n $strMembershipRule `n" -Status Info
            }
            catch{
                Write-Log -Info "$_" -Status Error
                Write-Log -Info "Group $strGroupName could not be created" -Status Error
                exit 99
            }
        }
        else { 
            Write-Log -Info "Group $strGroupName already exists, nothing changed." -Status Status
        }
        $j++
    }
}

#--------------------- Function to build a single element of the regex array for AzureAD (called by GetLargeArrChar)
function GetRegex($low, $high) {
    $regex = ''
    for ($i = $low; $i -lt $high; $i++) {
        $regex += "{0:x2}" -f ([uint32]$i) + '|'
    }
    $regex += "{0:x2}" -f ([uint32]$high)
    return '^.{27}(?:' + $regex + ')'
}

#--------------------- Function to create AzureAD dynamic membership rules for more than 16 groups (up to 256)	
function GetLargeArrChar($groups) {

    [string[]]$regex = @(); 
    $isum = [Math]::Truncate(256 / $groups)
    $min = 0
    $grpCount = 0
    $oRegexList = @()

    while ($min -lt 256) {
        $max = $min + $isum - 1
        if (++$grpCount -eq $groups) {
            $max = 255
            $isum = $max - $min + 1
        }
        $hmin = "{0:x2}" -f([uint32]$min)
        $hmax = "{0:x2}" -f([uint32]$max)

        $oRegex = New-Object PSCustomObject -Property @{
            dmin = $min
            dmax = $max
            hmin = $hmin
            hmax = $hmax
            isum = $isum
        }

        $oRegexList += $oRegex
        $min = $max + 1
    }

    $lastRegex = $oRegexList.count - 1

    if ($isumDifference = $oRegexList[$lastRegex].isum - $oRegexList[$lastRegex-1].isum) {

        if ($isumDifference -gt 1) {
            $isum = $oRegexList[$lastRegex-1].isum + 1
            $startIndex = $lastRegex - $isumDifference + 1

            for ($i=$startindex; $i -le $lastRegex; $i++) {

                if ($i -ne $startIndex) { 
                    $oRegexList[$i].dmin = $oRegexList[$i-1].dmax + 1 
                }

                $oRegexList[$i].isum = $isum
                $oRegexList[$i].dmax = $oRegexList[$i].dmin + $isum - 1
                $oRegexList[$i].hmin = "{0:x2}" -f([uint32]$oRegexList[$i].dmin)
                $oRegexList[$i].hmax = "{0:x2}" -f([uint32]$oRegexList[$i].dmax)
            }
        }
    }

    foreach ($out in $oRegexList) {
            $regex += GetRegex -low $out.dmin -high $out.dmax     
    }

    return $regex
}

#----------------- function to generate the groupname array
function GetGroupnames ($appl, $rules, $groupNamePrefix) {
    
    [string[]]$strGrpNames = @();

    for ($i = 0; $i -lt $rules.count; $i++) {

        $stripper = [regex] "\[([^\[]*)\]"
        $match = $stripper.match($rules[$i])
        if ('' -eq ($suffix = $match.groups[1].value)) {
            $pos = $rules[$i].IndexOf(":")
            $suffix2 = $rules[$i].Substring($pos+1)
            $suffix = $suffix2.Substring(0,2) + '-' + $suffix2.Substring($suffix2.Length-3,2) 
        }
        $strGrpNames += "{0}{1}{2:d3}_{3}" -f $groupNamePrefix, $appl, ($i+1), $suffix
    }
    return $strGrpNames
}

#----------------- function to query existing AzureAD groups
function GetGroups ($queryGrp) {

    Write-Log -Info "Searching your $queryGrp groups (this may take some time, be patient):`n" -Status Info
    Try {
        $myGroups = (Get-AzureADMSGroup | 
            Where-Object{$_.DisplayName -clike $queryGrp} | 
            Sort-Object -Property DisplayName |
            ForEach-Object { $_ | 
            Add-Member -type NoteProperty -name Users -value ((Get-AzureADGroupMember -ObjectId $_.ID).count) -PassThru })
    }
    catch {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "Your searched groups are not found or are not ready yet. Please be patient, AzureAD needs some time to create newly configured groups." -Status Error
        exit 99
    }
    return $myGroups
}

#------------------------------------- main function

[string[]]$arrChar = @(); 

$OneDriveAssignedPlan = '(user.assignedPlans -any (assignedPlan.servicePlanId -In' + 
' ["13696edf-5a08-49f6-8134-03083ed8ba30" ,"afcafa6a-d966-4462-918c-ec0b4e0fe642" ,"da792a53-cbc0-4184-a10d-e544dd34b3c1"' + 
' ,"da792a53-cbc0-4184-a10d-e544dd34b3c1" ,"98709c2e-96b5-4244-95f5-a0ebe139fb8a" ,"e95bec33-7c88-4a70-8e19-b10bd9d0c014"' + 
' ,"fe71d6c3-a2ea-4499-9778-da042bf08063" ,"5dbe027f-2339-4123-9542-606e4d348a72" ,"e03c7e47-402c-463c-ab25-949079bedb21"' + 
' ,"63038b2c-28d0-45f6-bc36-33062963b498" ,"c7699d2e-19aa-44de-8edf-1736da088ca1" ,"5dbe027f-2339-4123-9542-606e4d348a72"' + 
' ,"902b47e5-dcb2-4fdc-858b-c63a90a2bdb9" ,"8f9f0f3b-ca90-406c-a842-95579171f8ec" ,"153f85dd-d912-4762-af6c-d6e0fb4f6692"' + 
' ,"735c1d98-dd3f-4818-b4ed-c8052e18e62d" ,"e03c7e47-402c-463c-ab25-949079bedb21" ,"e5bb877f-6ac9-4461-9e43-ca581543ab16"' + 
' ,"a361d6e2-509e-4e25-a8ad-950060064ef4" ,"527f7cdd-0e86-4c47-b879-f5fd357a3ac6" ,"a1f3d0a8-84c0-4ae0-bae4-685917b8ab48"]))' 

if ($help -or !($groups -or $ODGrp -or $ExchGrp -or $queryGrp -or $logout -or $delGrp)) {
    vbmHelp
    exit
}

if ($limitGroups -lt 17 -or $limitGroups -gt 256) {
    Write-Log -Info "`$limitGroups variable has been changed to an invalid value $limitGroups. Should be between 17 and 256." -Status Error
    exit 99
}

if ($groups) 
{

    if ($ignoreDisabledAcc) {
        $NoBackupDisabledAcc = ' -and (user.accountEnabled -eq true) '
    }
    else { $NoBackupDisabledAcc = '' }

    if (!$ODGrp -and !$ExchGrp) {
            Write-Log -Info "Which groups ?  For Onedrive, for Exchange, or for both ?" -Status Error
            exit 99
    }

    $hdr = '^.{27}['
    $arrCharString  = "0123456789abcdef"
    $arrchar = switch ($groups)
    {
        2  { (0,8                 | ForEach-Object { $hdr + $arrCharString.Substring($_,8) + ']'})                                                                                  }
        3  { (0,5                 | ForEach-Object { $hdr + $arrCharString.Substring($_,5) + ']'});                                  $hdr + $arrCharString.Substring(10,6) + ']'    }     
        4  { (0,4,8,12            | ForEach-Object { $hdr + $arrCharString.Substring($_,4) + ']'})                                                                                  }
        5  { (0,3,6,9             | ForEach-Object { $hdr + $arrCharString.Substring($_,3) + ']'});                                  $hdr + $arrCharString.Substring(12,4) + ']'    }
        6  { (0,3,6,9             | ForEach-Object { $hdr + $arrCharString.Substring($_,3) + ']'}); (12,14        | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})  }
        7  { (0,2,4,6,8           | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'}); (10,13        | ForEach-Object { $hdr + $arrCharString.Substring($_,3) + ']'})  }
        8  { (0,2,4,6,8,10,12,14  | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})                                                                                  }
        9  { (0,2,4,6,8,10,12     | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'}); (14,15        | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'})  }
        10 { (0,2,4,6,8,10        | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'}); (12,13,14,15  | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'})  }
        11 { (0..5                | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'}); (6,8,10,12,14 | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})  }
        12 { (0..7                | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'}); (8,10,12,14   | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})  }
        13 { (0..9                | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'}); (10,12,14     | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})  }           
        14 { (0..11               | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'}); (12,14        | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})  }
        15 { (0..13               | ForEach-Object { $hdr + $arrCharString.Substring($_,1) + ']'}); (14           | ForEach-Object { $hdr + $arrCharString.Substring($_,2) + ']'})  }
        16 { $arrCharString -split '(?<=.)(?=.)' | ForEach-Object { $hdr + $_ + ']' }                                                                                               }                               
        {$_ -gt 16 -and $_ -le $limitGroups}  { GetLargeArrChar -Groups $_          }
        default {
            Write-Log -Info "Number of groups to be generated must be between 2 and $limitGroups." -Status Error
            Write-Log -Info "You may expand the `$limitGroups variable up to 256, if you REALLY need that many groups." -Status Error
            exit 99
        }
    }
}
else {
    if ($ODGrp -or $ExchGrp) {
            Write-Log -Info "Number of groups must be specified, if you select 'ODGrp' or 'ExchGrp' parameter." -Status Error
            exit 99
    }
}

if ($queryGrp) {

    AzureADLogin
    $dispose = GetGroups -queryGrp $queryGrp

    if ($null -eq $dispose) {
        Write-Log -Info "No groups found for selection $queryGrp" -Status Error 
    }
    else {
        ($dispose |
            Format-Table    @{Label="Created date";Expression={$_.CreatedDateTime}},
                            @{Label="Name";        Expression={$_.DisplayName}},
                            @{Label="Users";       Expression={$_.Users}},
                            @{Label="Description"; Expression={$_.Description}} -autosize |
            Out-String).Trim()
        Write-Host
        Write-Log -Info "It may take up to 24 hours with large groups, until they are correctly filled with all users. Be patient." -Status Warning
    }
}
elseif ($delGrp) {

    $regex = "^[\*\?]+$"
    if ($delGrp -match $regex) {
        Write-Log -Info "Generic char '$delgrp' only allowed together with alphanumeric chars." -Status Error    
        Write-Log -Info "Be careful with generic chars, so that you don't delete important groups." -Status Error 
        exit 99   
    }

    AzureADLogin
    $dispose = GetGroups -queryGrp $delGrp

    if ($null -eq $dispose) {
        Write-Log -Info "No groups found for selection $delGrp" -Status Error 
    }
    else {
        ($dispose |
            Format-Table    @{Label="Created date";Expression={$_.CreatedDateTime}},
                            @{Label="Name";        Expression={$_.DisplayName}},
                            @{Label="Users";       Expression={$_.Users}},
                            @{Label="Description"; Expression={$_.Description}} -autosize |
            Out-String).Trim()

        Write-Log -Info "Do you really want to delete all groups displayed above ?`nIf so, type exactly 'Yes' (case sensitive)" -Status Error

        if (($answer = Read-Host) -ceq 'Yes') {
            try {
                foreach ($out in $dispose) {                                      
                    Remove-AzureADMSGroup -Id $out.id > $null
                    Write-Log -Info "Group $($out.DisplayName) deleted." -Status Warning
                }
            }
            catch{
                Write-Log -Info "$_" -Status Error
                Write-Log -Info "Group $($out.DisplayName) could not be deleted." -Status Error
            }

        }
        else { Write-Log -Info "Deletion skipped by user." -Status Error } 
    }
}
else {
    if ($create) {

        AzureADLogin

        if ($ExchGrp) {
	        Write-Log -Info "Creating Exchange groups..." -Status Info
	        New-ExGroups -NoBackupDisabledAcc $NoBackupDisabledAcc -arrChar $arrChar -strGrpNames (GetGroupnames -appl "ExChg" -rules $arrChar -groupNamePrefix $groupNamePrefix)
        }
	
        if ($ODGrp) {
	        Write-Log -Info "Creating ONEDrive groups..." -Status Info
	        New-ODGroups -NoBackupDisabledAcc $NoBackupDisabledAcc -OneDriveAssignedPlan $OneDriveAssignedPlan -arrChar $arrChar -strGrpNames (GetGroupnames -appl "ODGrp" -rules $arrChar -groupNamePrefix $groupNamePrefix)
        }
    }
    else {
        if ($ExchGrp) {
            $strGrpNames = GetGroupnames -appl "ExChg" -rules $arrChar -groupNamePrefix $groupNamePrefix
            for ($i=0; $i -lt $strGrpNames.Length; $i++) {
                Write-Log -Info "$($strGrpNames[$i])`:  (user.objectID -match `"$($arrChar[$i])`")" -Status Info
            }
        }    
        if ($ODGrp) {
            $strGrpNames = GetGroupnames -appl "ODGrp" -rules $arrChar -groupNamePrefix $groupNamePrefix
            for ($i=0; $i -lt $strGrpNames.Length; $i++) {
                Write-Log -Info "$($strGrpNames[$i])`:  (user.objectID -match `"$($arrChar[$i])`")" -Status Info
            }  
            Write-Log -Info "Onedrive membership rules will also contain this: " -Status Info 
            Write-Log -Info "(user.assignedPlans -any (assignedPlan.servicePlanId -In" -Status Info
            Write-Log -Info ' ["13696edf-5a08-49f6-8134-03083ed8ba30" ,"afcafa6a-d966-4462-918c-ec0b4e0fe642" ,"da792a53-cbc0-4184-a10d-e544dd34b3c1"' -Status Info
            Write-Log -Info ' ,"da792a53-cbc0-4184-a10d-e544dd34b3c1" ,"98709c2e-96b5-4244-95f5-a0ebe139fb8a" ,"e95bec33-7c88-4a70-8e19-b10bd9d0c014"' -Status Info 
            Write-Log -Info ' ,"fe71d6c3-a2ea-4499-9778-da042bf08063" ,"5dbe027f-2339-4123-9542-606e4d348a72" ,"e03c7e47-402c-463c-ab25-949079bedb21"' -Status Info 
            Write-Log -Info ' ,"63038b2c-28d0-45f6-bc36-33062963b498" ,"c7699d2e-19aa-44de-8edf-1736da088ca1" ,"5dbe027f-2339-4123-9542-606e4d348a72"' -Status Info 
            Write-Log -Info ' ,"902b47e5-dcb2-4fdc-858b-c63a90a2bdb9" ,"8f9f0f3b-ca90-406c-a842-95579171f8ec" ,"153f85dd-d912-4762-af6c-d6e0fb4f6692"' -Status Info 
            Write-Log -Info ' ,"735c1d98-dd3f-4818-b4ed-c8052e18e62d" ,"e03c7e47-402c-463c-ab25-949079bedb21" ,"e5bb877f-6ac9-4461-9e43-ca581543ab16"' -Status Info 
            Write-Log -Info ' ,"a361d6e2-509e-4e25-a8ad-950060064ef4" ,"527f7cdd-0e86-4c47-b879-f5fd357a3ac6" ,"a1f3d0a8-84c0-4ae0-bae4-685917b8ab48"]))' -Status Info
   
        }    
        Write-Log -Info "All membership rules will also contain this: '-and (user.mail -ne null) $NoBackupDisabledAcc'" -Status Info
        Write-Log -Info "To create the above dynamic groups in AzureAD, specify the '-create' parameter." -Status Warning
        Write-Host
    }
}
	
if($null -ne $Global:AccountID) {
    if ($logout) {
        Write-Log -Info "Trying to disconnect from AzureAD..." -Status Info
        try {
            $Global:AccountID = $null
            Disconnect-AzureAD
            Write-Log -Info "Successfully disconnected" -Status Info
            exit
        } 
        catch {
            Write-Log -Info "$_" -Status Error
            Write-Log -Info "Could not disconnect from AzureAD" -Status Error
            exit 99
        }
    }
    else {
        Write-Log -Info "AzureAD Session kept running. If you want to logout, run 'VBM365-DynamicGroups.ps1 -logout'." -Status Warning
    }
}

Write-Host " "
	