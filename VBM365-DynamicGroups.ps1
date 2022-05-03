<#

    .SYNOPSIS
    This script creates Dynamic Distribution Groups for Exchange and/or Onedrive in AzureAD,
	and queries groups based on given input parameters.


    .NOTES
    Author: Herbert Szumovski

    I use functions from David Bewernick's VBO-CreateDynamicGroups.ps1, which you can find here:
    https://github.com/VeeamHub/powershell/tree/master/VBO-CreateDynamicGroups

    In case you need more than 2 to 16 Exchange distributiongroups, use David's script. Though 
	it creates no Onedrive-only groups, it can create up to 64 groups for Exchange using a 
	slightly different algorithm.

    This is no official Veeam software, I just created this for convenience of my customers.
    Though checked on a best effort basis, it may contain errors.
    Use at your own risk, and check, if the resulting distribution groups fulfill your needs.


    .DESCRIPTION
    The dynamic distribution groups will contain all users from your M365 org. Users who 
    will be added later or will be removed from your Org are dynamically managed by AzureAD
    via these groups. The users will also be roughly balanced between the groups.

    How it works:
    The groups made by this script inherit the userids based on the fourth letter of their 
    respective AzureAD object-id. This letter contains a hex digit between 0 and f. Therefore 
    up to 16 groups could be generated.  If you generate less than 16 groups, the script uses 
    more than one character for the regex comparison: 
    e.g. if you create 6 groups, then characters 0-2, 3-5, 6-8, 9ab, cd, ef are compared 
    to the fourth letter in the object-id of the users.
    For the OneDrive groups the userassigned serviceplan IDs for Onedrive are also used
    for comparison, so users without Onedrive access are not included there.

    .FAQ
    Why separate groups for OneDrive ? 
        The Exchange Groups contain also shared mailboxes with no OneDrive access, and these
        generate unnecessary warning messages in the Veeam backupjobs. 
        This can be avoided with the OD groups.

    Why does the script not allow to create just one group only for the whole org ?
        It makes no sense. In case you want to backup your whole Org without group
        selection, just specify the Org in the backup job, and not groups.
        This script is made for companies which need to split their users to
        multiple different repositories or jobs.  For best practice how many users one group
        should maximally contain, plz contact your Veeam SE.

    .USAGE

    When the script starts, it checks, if there is an AzureAD session available from a prior run.
    If yes, it is used again, if no, it prompts you for a login. 
    To logout from the AzureAD session after the script run, specify the "-logout" parameter.

    without parameters :  displays help 

    "-qGroups" <string>:  displays AzureAD groups found by search criteria <string>

    "-ExchGrp"         :  creates dynamic distributiongroups for Exchange backup

    "-ODGrp"           :  creates dynamic distributiongroups for Onedrive backup

    "-Groups" <number> :  number of groups which should be created. 
                Must be an integer between 2 and 16. Can only be specified with
                one or both of the above 2 parameters.

    "-logout"          :  the script logs out of the current AzureAD session it
                has just used. By default the session is kept running, for being 
                able to run the script several times without the need for
                multiple logins. If "-logout" is not used, a yellow warning 
                message tells you, that the AzureAD session is still there.
                You can combine the "-logout" parameter with any of the other, or
                also use it standalone.
        

    Last Updated: May 2022
    Version: 1.3
	
	Fixes: 
        2022-04-01, V1.0: First version
        2022-04-02, V1.1: Added OneDrive groups and parameter for flexible number of 
                          groups creation between 2 and 16
        2022-04-03, V1.2: Added group display, optional AzureAD logout and usercount per group
        2022-05-02, V1.3: Added separate parameter for group dispay, added help display
  
    Requires:
    To run the script you must install the Microsoft AzureAdPreview Powershell module:

    Install-Module AzureAdPreview -Scope CurrentUser

 #>

#Requires -Modules AzureAdPreview

[CmdletBinding(DefaultParameterSetName='help',PositionalBinding=$False)]  

Param(
    # Generates dynamic distribution groups for Exchange
    [switch] $ExchGrp,

	# Generates dynamic distribution groups for Onedrive
    [switch] $ODGrp,

    # Specifies the number of groups you want to generate (2 - 16)
    [int] $Groups = 0,

    # Displays the groups you select
    [STRING[]]$qGroups,

	# Logout from AzureAD when script exits
    [parameter(ParameterSetName="logout")]
    [alias("logoff")]
    [switch] $logout,

    [parameter(ParameterSetName="help")]
    [SWITCH]$help   
);

          $Global:azureConnection      = ''
[string[]]$Global:arrChar              = @(''); 
[string]  $Global:LogFile              = "VBM365-DynamicGroups.log" 
[string]  $Global:strGroupNameStart    = "Veeam_"
[string]  $Global:OneDriveAssignedPlan = '(user.assignedPlans -any (assignedPlan.servicePlanId -In' + 
				' ["13696edf-5a08-49f6-8134-03083ed8ba30" ,"afcafa6a-d966-4462-918c-ec0b4e0fe642" ,"da792a53-cbc0-4184-a10d-e544dd34b3c1"' + 
				' ,"da792a53-cbc0-4184-a10d-e544dd34b3c1" ,"98709c2e-96b5-4244-95f5-a0ebe139fb8a" ,"e95bec33-7c88-4a70-8e19-b10bd9d0c014"' + 
				' ,"fe71d6c3-a2ea-4499-9778-da042bf08063" ,"5dbe027f-2339-4123-9542-606e4d348a72" ,"e03c7e47-402c-463c-ab25-949079bedb21"' + 
				' ,"63038b2c-28d0-45f6-bc36-33062963b498" ,"c7699d2e-19aa-44de-8edf-1736da088ca1" ,"5dbe027f-2339-4123-9542-606e4d348a72"' + 
				' ,"902b47e5-dcb2-4fdc-858b-c63a90a2bdb9" ,"8f9f0f3b-ca90-406c-a842-95579171f8ec" ,"153f85dd-d912-4762-af6c-d6e0fb4f6692"' + 
				' ,"735c1d98-dd3f-4818-b4ed-c8052e18e62d" ,"e03c7e47-402c-463c-ab25-949079bedb21" ,"e5bb877f-6ac9-4461-9e43-ca581543ab16"' + 
				' ,"a361d6e2-509e-4e25-a8ad-950060064ef4" ,"527f7cdd-0e86-4c47-b879-f5fd357a3ac6" ,"a1f3d0a8-84c0-4ae0-bae4-685917b8ab48"]))' 

#--------------------- Function for help display
function help() { return Get-Content $PSCommandPath -TotalCount 90 | Select-String -Pattern '.USAGE' -Context 0,27 }

#--------------------- Function for logmessage writing
function Write-Log($Info, $Status){
    $timestamp = get-date -Format "yyyy-mm-dd HH:mm:ss"
    switch($Status){
        Info    {Write-Host "$timestamp $Info" -ForegroundColor Green  ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
        Status  {Write-Host "$timestamp $Info" -ForegroundColor Yellow ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
        Warning {Write-Host "$timestamp $Info" -ForegroundColor Yellow ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
        Error   {Write-Host "$timestamp $Info" -ForegroundColor Red    ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
        default {Write-Host "$timestamp $Info" -ForegroundColor white  ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
    }
}
	
#--------------------- Function to create dynamic distributiongroups for Exchange	
function Create-ExGroups(){ 										 
    $j=0 
               
    while($j -lt $arrChar.length){ 							  
        $strRegex = '^.{3}' + '[' + $arrChar[$j] + ']' 		 
        $strGroupName = $strGroupNameStart + 'Exchg_' + $arrChar[$j]  
        $strMembershipRule = '(user.objectID -match "' + $strRegex + '") and (user.mail -ne $null) and (user.accountEnabled -eq true)' 

        if((Get-AzureADMSGroup | where{$_.DisplayName -eq $strGroupName}) -eq $null) {
            try {
                New-AzureADMSGroup -DisplayName "$strGroupName" -MailNickname "$strGroupName" `
                    -Description "Group for VBO Exchg backup with rule $strRegex" -MailEnabled $false -GroupTypes {DynamicMembership} `
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
function Create-ODGroups(){ 										 
    $j=0 
               
    while($j -lt $arrChar.length){ 							  
        $strRegex = '^.{3}' + '[' + $arrChar[$j] + ']' 		 
        $strGroupName = $strGroupNameStart + 'OneDr_' + $arrChar[$j]  
        $strMembershipRule = '(user.objectID -match "' + $strRegex + '") and (user.accountEnabled -eq true) and ' + $OneDriveAssignedPlan

        if((Get-AzureADMSGroup | where{$_.DisplayName -eq $strGroupName}) -eq $null) {
            try {
                New-AzureADMSGroup -DisplayName "$strGroupName" -MailNickname "$strGroupName" `
                    -Description "Group for VBO OneDr backup with rule $strRegex" -MailEnabled $false -GroupTypes {DynamicMembership} `
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


#--------------------- Main function

if (!($Groups -or $ODGrp -or $ExchGrp -or $qGroups -or $logout)) {
    help
    exit
}

if ($Groups) 
{

    if (!$ODGrp -and !$ExchGrp) {
            Write-Log -Info "Which groups ?  For Onedrive, for Exchange, or for both ?" -Status Error
            exit 99
    }


    $arrCharString  = "0123456789abcdef"
    $Global:arrchar = switch ($Groups)
    {
        2  {  0,8                 | % { $arrCharString.Substring($_,8) }                                                         }
        3  { (0,5                 | % { $arrCharString.Substring($_,5) });                     $arrCharString.Substring(10,6)    }     
        4  {  0,4,8,12            | % { $arrCharString.Substring($_,4) }                                                         }
        5  { (0,3,6,9             | % { $arrCharString.Substring($_,3) });                     $arrCharString.Substring(12,4)    }
        6  { (0,3,6,9             | % { $arrCharString.Substring($_,3) }); (12,14        | % { $arrCharString.Substring($_,2) }) }
        7  { (0,2,4,6,8           | % { $arrCharString.Substring($_,2) }); (10,13        | % { $arrCharString.Substring($_,3) }) }
        8  {  0,2,4,6,8,10,12,14  | % { $arrCharString.Substring($_,2) }                                                         }
        9  { (0,2,4,6,8,10,12     | % { $arrCharString.Substring($_,2) }); (14,15        | % { $arrCharString.Substring($_,1) }) }
        10 { (0,2,4,6,8,10        | % { $arrCharString.Substring($_,2) }); (12,13,14,15  | % { $arrCharString.Substring($_,1) }) }
        11 { (0..5                | % { $arrCharString.Substring($_,1) }); (6,8,10,12,14 | % { $arrCharString.Substring($_,2) }) }
        12 { (0..7                | % { $arrCharString.Substring($_,1) }); (8,10,12,14   | % { $arrCharString.Substring($_,2) }) }
        13 { (0..9                | % { $arrCharString.Substring($_,1) }); (10,12,14     | % { $arrCharString.Substring($_,2) }) }           
        14 { (0..11               | % { $arrCharString.Substring($_,1) }); (12,14        | % { $arrCharString.Substring($_,2) }) }
        15 { (0..13               | % { $arrCharString.Substring($_,1) }); (14           | % { $arrCharString.Substring($_,2) }) }
        16 {                            $arrCharString -split '(?<=.)(?=.)'                                                      }
        default {
            Write-Log -Info "Number of groups to be generated must be between 2 and 16." -Status Error
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

if($Global:AccountID -eq $null) {
    Write-Log -Info "Trying to connect to AzureAD..." -Status Info
    try {
        $Global:azureConnection = Connect-AzureAD
        $Global:AccountID = $Global:azureConnection.Account.id
        Write-Log -Info "Connection successful with $Global:AccountID" -Status Info
    } 
    catch  {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "Could not connect with AzureAD." -Status Error
        exit 99
    }
}

if ($qGroups) {
	Write-Log -Info "Searching your $qGroups groups (this may take some time, be patient):" -Status Info
    Try {
        (Get-AzureADMSGroup | 
            where{$_.DisplayName -like $qGroups} | 
            Sort-Object -Property DisplayName |
            ForEach-Object { $_ | 
            Add-Member -type NoteProperty -name Users -value ((Get-AzureADGroupMember -ObjectId $_.ID).count) -PassThru } |
            ft @{Label="Created date";Expression={$_.CreatedDateTime}},
               @{Label="Name";Expression={$_.DisplayName}},
               @{Label="Users";Expression={$_.Users}},
               @{Label="Description";Expression={$_.Description}} -autosize |
            Out-String).Trim()
        Write-Log -Info "It may take some minutes with large groups, until they are correctly filled with all users. Be patient." -Status Warning
        exit
    }
    catch {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "New groups are not ready yet. Please be patient, AzureAD is busy." -Status Error
        exit 99
    }
}
else {
    if ($ExchGrp) {
	    Write-Log -Info "Creating Exchange groups..." -Status Info
	    Create-ExGroups
    }
	
    if ($ODGrp) {
	    Write-Log -Info "Creating ONEDrive groups..." -Status Info
	    Create-ODGroups
    }
}
	
if($Global:AccountID -ne $null) {
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
	