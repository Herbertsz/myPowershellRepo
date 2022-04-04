<#-------------------------------------------------------------------------------------------------------------------------------------------+

   herbert.szumovski@veeam.com - hsTools    Windows disk related tools
   
                            A helper skript, which displays Windows disk related infos, which are otherwise not easily accessible in one place 
							Currently (2022) I only adapt it to actual Windows versions
							Call it without parameters to see a help display
							WARNING: If you use it to install MPIO feature, iSCSI or set MPIO parameters, you should know what you are doing!
							The query parameters can be used without danger.
 
   Version 			Date	Changes
       1.0		20151123 	Installs MPIO feature, enables it for Flash arrays, sets Microsoft DSM parameters for Flash LUNs
       1.1		20151126 	Added check for Server OS, added check if MPIO is already installed
       1.2		20151212	Added script parameters
	   1.4 		20160110    Added iSCSI mpio and iSCSI service activation
	   1.5      20160110    Changed parameter sets, added filesystems and partitions
	   1.6      20160124    Added qdisks, changed output format
	   1.7		20160124    Added qLUNs parameter to be able to select also LUN-ids, not only Windows disknumbers
							(Because Microsoft says dynamic volumes and LDM are deprecated, they are also not supported via Powershell.
							So I implemented a workaround to support them here.  If enough people tell me that this is no
							longer needed, I'll be happy to throw out this ugly part of the code, thanks! )
	   1.8      20160214	Fixed Bug which prevented it from running under Windows 2016 server
       2.0      20190304    Added Windows server 2019 support, and some changes to make it runnable also on servers with no MPIO installed
       2.1      20190310    Modified MPIO discovery to be faster 
							(added that in the main procedure. Was to lazy to remove the other method from flasharray proc - something to clean up later)
	   2.2		20190311    Removed historic Flash arrays, added Purestorage arrays instead
							(Thanks to Martin Heger, PureStorage Austria, for providing me the right values)
---------------------------------------------------------------------------------------------------------------------------------------------#>

[CmdletBinding(DefaultParameterSetName='help')]  

Param(
    [Parameter(Mandatory=$false,ParameterSetName="instfc")]
    [alias("iFC")]
    [SWITCH]$installFC,
	
    [Parameter(Mandatory=$false,ParameterSetName="iscsi")]
    [alias("iSCSI")]
    [SWITCH]$installiSCSI,
	    
    [Parameter(Mandatory=$false,ParameterSetName="online")]
    [SWITCH]$online,

    [Parameter(Mandatory=$false,ParameterSetName="qsettings")]
	[alias("qMPIO")]
    [SWITCH]$qsettings,

    [Parameter(Mandatory=$false,ParameterSetName="qdisks")]
    [STRING[]]$qdisks,

    [Parameter(Mandatory=$false,ParameterSetName="qLUNs")]
    [STRING[]]$qLUNs,

    [Parameter(Mandatory=$false,ParameterSetName="qhba")]
    [SWITCH]$qHBA,

    [Parameter(Mandatory=$false,ParameterSetName="qdisks")]
    [Parameter(Mandatory=$false,ParameterSetName="qLUNs")]
    [SWITCH]$detail,

    [Parameter(Mandatory=$false,ParameterSetName="qdisks")]
    [Parameter(Mandatory=$false,ParameterSetName="qLUNs")]
    [SWITCH]$filesystems,

    [Parameter(Mandatory=$false,ParameterSetName="instfc")]
    [Parameter(Mandatory=$false,ParameterSetName="iscsi")]
    [SWITCH]$RR,
	
    [parameter(Mandatory=$false,ParameterSetName="help")]
    [SWITCH]$help    
)

<#-------------------------------------+
    Function for collecting HBA info  |
---------------------------------------#>
function get-hbaInfo
{
    $Ports = (Get-WmiObject -Class MSFC_FibrePortHBAAttributes -Namespace "root\WMI" 2>&1)
    if ($Ports -match "Not supported")
    {
        Write-Output "No Fiberchannel HBAs found."
        Write-Output " "
    }
    else
    {
    	$HBAs  = Get-WmiObject -Class MSFC_FCAdapterHBAAttributes -Namespace "root\WMI"
    
	    $HBAProperties = $HBAs | Get-Member -MemberType Property, AliasProperty | Select -ExpandProperty name | Where-Object {$_ -notlike "__*"}
    	$HBAs = $HBAs | Select $HBAProperties
    	$HBAs | ForEach-Object { $_.NodeWWN = ((($_.NodeWWN) | ForEach-Object {"{0:x2}" -f $_}) -join "").ToUpper() }
 
    	ForEach($HBA in $HBAs) 
	    {
		    $PortWWN = (($Ports | Where-Object { $_.instancename -eq $HBA.instancename }).attributes).PortWWN
		    $PortWWN = (($PortWWN | ForEach-Object {"{0:x2}" -f $_}) -join "").ToUpper()
		    Add-Member -MemberType NoteProperty -InputObject $HBA -Name PortWWN -Value $PortWWN
	    }

        Write-Output " "
        Write-Output "Fiberchannel HBAs                                   V   e   r   s   i   o   n   s"
        ($HBAs | ft @{Label="Manufacturer";Expression={$_.Manufacturer}},
                @{Label="Model";Expression={$_.Model}},
                @{Label="Serial#";Expression={$_.Serialnumber}},
                @{Label="Driver";Expression={$_.Drivername}},
                @{Label="Driver";Expression={$_.Driverversion}},
                @{Label="Firmware";Expression={$_.Firmwareversion}},
                @{Label="Hardware";Expression={$_.Hardwareversion}},
                @{Label="NodeWWN";Expression={$_.NodeWWN}},
                @{Label="PortWWN";Expression={$_.PortWWN}},
                @{Label="Active";Expression={$_.Active}} -autosize |
             Out-String).Trim()
        Write-Output " "
    }
}
<#-------------------------------------+
    Function for collecting MPIO info  |
---------------------------------------#>
function get-MpioInfo
{
        Write-Output " "
        Write-Output "iSCSI:"
        (Get-InitiatorPort |
                Where-Object {($_.NodeAddress -match "iqn")} |
                ft @{Label=”NodeAddress”;Expression={$_.NodeAddress}},
                   @{Label=”PortAddress”;Expression={$_.PortAddress}} -autosize |                 
                Out-String).Trim()
        (Get-Service -name MSiSCSI |
                 ft @{Label=””;Expression={$_.DisplayName}},                
                    @{Label=””;Expression={$_.Status}} -autosize -HideTableHeaders |
                 Out-String).Trim()
        Write-Output " "
        Write-Output "MPIO settings:"
        Write-Output "---- ---------"
        Write-Output "LoadBalancingPolicy       : $(Get-MSDSMGlobalDefaultLoadBalancePolicy)"
        (Get-MPIOSetting | Out-String).Trim()
        Write-Output " "
        Write-Output "MSDSM enabled Hardware:"
        Write-Output "----- ------- ---------"
        $supportedHW=Get-MSDSMSupportedHW
        ForEach ($vals in $supportedHW) 
		{
                if ($vals.VendorID -ne "Vendor 8") {"$($vals.VendorID) $($vals.ProductId)" } ;
        }
        Write-Output " "
        Write-Output "Currently available Hardware with MPIO support:"
        (Get-MPIOAvailableHW |
                ft @{Label=”VendorID”;Expression={$_.VendorID}},
                   @{Label=”ProductID”;Expression={$_.ProductID}},                 
                   @{Label=”BusType”;Expression={$_.BusType}},
                   @{Label=”MPIO”;Expression={$_.IsMultipathed}},
                   @{Label=”SPC3Support”;Expression={$_.IsSPC3Supported}} -autosize |
                Out-String).Trim()
        Write-Output " "
}


<#----------------------------------------------------+
    Filter for detailed pathdisplay per disk/LUN      |
------------------------------------------------------#>
filter Modify-DiskPipe
{
    'Disk-nr '+$_.index+', Status: '+$_.Statusinfo+', Serial: '+$_.SerialNumber
    'Firmware: '+$_.FirmwareRevision+', Size '+[Math]::Round($_.size / 1GB,2)+' GB, Partitions: '+$_.Partitions+', Partitionstyle: '+$_.Partitionstyle
    'Type: '+$_.Caption
    $_.PathInfo
    "------------------------------------------------------------"
}

<#-----------------------------------------------------------------------+
    Filter for detailed filesystem information per disk/LUN              |
-------------------------------------------------------------------------#>
filter Modify-Filepipe 
{

    if ($_.SerialNumber.Length -gt 17) {$serialout = $_.SerialNumber.SubString(0,14)+"..."} else {$serialout = $_.SerialNumber}
    if ($_.Caption.Length -gt 24) {$captionout = $_.Caption.SubString(0,21)+"..."} else { $captionout = $_.Caption } 

	write-output $('| Disk {0,3}' -f $_.index +
		', Status {0,7}' -f $_.StatusInfo +
		', Size {0,8}' -f [Math]::Round($_.size / 1GB, 2).tostring("#0.00") +
		' GB, PType {0,3}' -f $_.partitionStyle +
		', SCSI {0,3}|{1,3}|{2,3}|{3,3}' -f $_.SCSIPort.tostring("000"),$_.scsibus.tostring("000"),$_.SCSITargetId.tostring("000"),$_.scsilogicalunit.tostring("000") +
		', Serial {0}' -f $serialout +
		', Type {0}' -f $captionout)

	$getpartitions = 'ASSOCIATORS OF {Win32_DiskDrive.DeviceID="' + $_.DeviceID.replace('\','\\') + '"} WHERE AssocClass=Win32_DiskDriveToDiskPartition'
    $partitions = @( get-wmiobject -query $getpartitions | sort StartingOffset )

    foreach ($partition in $partitions) {
        $getvolumes = 'ASSOCIATORS OF {Win32_DiskPartition.DeviceID="' + $partition.DeviceID + '"} WHERE AssocClass=Win32_LogicalDiskToPartition'
        $volumes   = @(get-wmiobject -query $getvolumes)
        $align=$partition.StartingOffset % 4096
        if ($align -eq 0)  { $alignout = ", 4k aligned." }
        else { $alignout = ", WARNING: Misalignment " + '+{0} Bytes.' -f $align }
        write-output $( '+----| Partition {0,2}' -f $partition.Index + 
			',        Size {0,8}' -f [Math]::Round($partition.size / 1GB, 2).tostring("#0.00") + 
			' GB, Type ' + $partition.Type + $alignout )
 
        foreach ( $volume in $volumes) {
            write $( '     +------| Vol {0,1}' -f $volume.name + 
			    '        Size {0,8} GB' -f [Math]::Round($volume.Size / 1GB, 2).tostring("#0.00") + 
			    ' ({0} GB free),' -f [Math]::Round($volume.FreeSpace / 1GB, 2).tostring("#0.00") +
                ' [{0}]' -f $volume.FileSystem )

        } 
 
    } 
	
    write-output "                            ----------------------------------------------------------------------------------------------------"
    write-output ""
}



<#-------------------------------------------+
    Function for collecting diskinfo         |
---------------------------------------------#>
function get-vdiskinfo
{
	$WMIDisks = Get-WmiObject Win32_DiskDrive 
	
	if ($qdisks) {
        $qdisks[0] = $qdisks[0] -replace("-","..")
		if ($qdisks[0] -like '*..*') { $qdisks = iex "`($qdisks)" }
        if ($qdisks[0] -eq "*") { $qdisks = $WMIDisks.index }
		$selectdisks = $qdisks 
        $wherecriteria = '$_.index -in $selectdisks'
		$sortcriteria  = @{expression="index"}
	}
	else {
        $qLUNs[0] = $qLUNs[0] -replace("-","..")
		if ($qLUNs[0] -match "..") { $qLUNs = iex "`($qLUNs)" }
        if ($qLUNs[0] -eq "*") { $qLUNs = $WMIDisks.scsilogicalunit }
		$selectdisks = $qLUNs 
        $wherecriteria = '$_.scsilogicalunit -in $selectdisks'
		$sortcriteria  =  @{expression="scsilogicalunit"},@{expression="scsiBus"},@{expression="SerialNumber"}
	}
	
	$WMIDisks = $WMIDisks |  Where-Object {iex $wherecriteria} 

    $mpObject = New-Object PSCustomObject -Property @{
        mpioDeviceId = $null
        systemDeviceId = $null
        pathInformation = $null
    }

    $mpDevList = @()
    if ($MPIO.Installed) {

        $mpathdevs = (mpclaim -s -d | select-string -pattern "^MPIO DISK\p{Nd}+")

        ForEach($mpathdev in $mpathdevs) {
            $splitUp = $mpathdev -split("\s+")
            $splitup[1] = $splitup[1] -replace("Disk","")
		
		    if ($splitup[3] -in $WMIDisks.index) { 
			    $workpath = (mpclaim -s -d $splitup[1] | ForEach-Object { if ($_ -ne "" -and $_ -notmatch "----" -and $_ -notmatch "Supported" -and $_ -notmatch "TPG") { $_ } $i++ })
			    $workpath[0] = $workpath[0] -replace("MPIO Disk","MPIO-id ")
			    $workpath[0] = $workpath[0] -replace(":",",")
			    $workpath[2] = $workpath[2] -replace("SN:","Guid:")
			    For($i=0; $i -lt $workpath.count; $i++) { $workpath[$i] = ($workpath[$i]).trim() }

			    $mpObject = New-Object PSCustomObject -Property @{
				    mpioDeviceId    = ($splitUp[1] -as [int])
				    systemDeviceId  = ($splitUp[3] -as [int])
				    pathInformation =  $workpath
			    }  
			    $mpDevList += $mpobject
		    }
        }
    }

    $DDObject = New-Object PSCustomObject -Property @{
        index = $null
        status = $null
        partitiontype = $null
    }

# I found out, Powershell doesn't support dynamic disks, therefore I use diskpart here (Herby, 2016 01 24) ---- Begin
	
    $dynamicdisks = ("LIST DISK" | diskpart | select-string -notMatch "###","Part","Missing" | select-string -simpleMatch "Disk")
    $dyndisklist = @()

    ForEach($dynamicdisk in $dynamicdisks) {
        $dyn=$dynamicdisk.tostring().substring(43,4).trim()
        if ($dyn) {$dyn="LDM"}
        $splitUp = $dynamicdisk -split("\s+")
        $DDObject = New-Object PSCustomObject -Property @{
            index = ($splitUp[2])/1
            status = $splitUp[3]
            partitiontype = $dyn
        }
        $dyndisklist += $DDObject
    }

    $DiskObject = New-Object PSCustomObject -Property @{
		scsiBus = $null
		scsiPort = $null
		SCSITargetId = $null
		scsilogicalunit = $null
		SerialNumber = $null
		size = $null
		Partitions = $null
		PartitionStyle = $null
		Caption = $null
		index = $null
		StatusInfo = $null
		FirmwareRevision = $null
		DeviceID = $null
        mpioId = $null
        PathInfo = $null
	}
 
	$DiskList = @()
     
	ForEach ($WMIDisk in $WMIDisks) {
        if ($mpDevList.Count -eq 0) { $mpDevListIndex = $Null }
        else { $mpDevListIndex = (0..($mpDevList.Count-1)) | Where-Object {$mpDevList.systemDeviceId[$_] -eq $WMIDisk.index} }

# I found out, Powershell doesn't support dynamic partitions, therefore I use diskpart here (Herby, 2016 01 24) ---- End
# Take care, logic below must be changed when I remove that one day
        
        if ($dyndisklist.Count -gt 0) {
            $dynindex = (0..(($dyndisklist.Count)-1)) | Where-Object {$dyndisklist.index[$_] -eq $WMIDisk.index}
            if ($dyndisklist[$dynindex].Partitiontype -eq "") { $dyndisklist[$dynindex].Partitiontype = (Get-Disk $WMIDisk.index).PartitionStyle }
        }
        if ($mpDevListIndex -eq $null)
        {
    		$DiskObject = New-Object PSCustomObject -Property @{
	    		scsiBus = $WMIDisk.scsiBus
		    	scsiPort = $WMIDisk.scsiPort
			    SCSITargetId = $WMIDisk.SCSITargetId
    			scsilogicalunit = $WMIDisk.scsilogicalunit
    			SerialNumber = $WMIDisk.SerialNumber
    			size = $WMIDisk.size+5000000
    			Partitions = $WMIDisk.Partitions
    			PartitionStyle = $dyndisklist[$dynindex].Partitiontype
    			Caption = $WMIDisk.Caption
    			index = $WMIDisk.index
    			StatusInfo = $dyndisklist[$dynindex].status
    			FirmwareRevision = $WMIDisk.FirmwareRevision
				DeviceID = $WMIDisk.DeviceID
                mpioId = $Null
                PathInfo = "--- no MPIO device ---" 
		    }
		    $DiskList += $DiskObject
        }
        else
        {
		    $DiskObject = New-Object PSCustomObject -Property @{
			    scsiBus = $WMIDisk.scsiBus
    			scsiPort = $WMIDisk.scsiPort
    			SCSITargetId = $WMIDisk.SCSITargetId
    			scsilogicalunit = $WMIDisk.scsilogicalunit
    			SerialNumber = $WMIDisk.SerialNumber
    			size = $WMIDisk.size+5000000
    			Partitions = $WMIDisk.Partitions
    			PartitionStyle = $dyndisklist[$dynindex].Partitiontype
    			Caption = $WMIDisk.Caption
    			index = $WMIDisk.index
    			StatusInfo = $dyndisklist[$dynindex].status
    			FirmwareRevision = $WMIDisk.FirmwareRevision
				DeviceID = $WMIDisk.DeviceID
                mpioId = $mpDevList.mpioDeviceId[$mpDevListIndex]
                PathInfo = $mpDevList[$mpDevListIndex].pathinformation 
		    }
		    $DiskList += $DiskObject
        }
	}

    if (($DiskList | Where-Object {iex $wherecriteria}) -eq $Null)
    {
        Write-Output "No disks/LUNs found with the given search criteria."
        Write-Output " "
        exit
    }

    if ($detail) {
            ($DiskList |
	    		sort ($sortcriteria) |
                Modify-DiskPipe  |
                Out-String).Trim() |
                more
	}
	elseif ($filesystems) {
            ($DiskList |
	    		sort ($sortcriteria) |
                Modify-FilePipe  |
                Out-String).Trim() |
                more            	
	}
    else {
			Write-Output "                      S   C   S   I"
			($DiskList | 
	    		sort ($sortcriteria) |  
                ft  @{Label=”Disk-#”;Expression={$_.index}},
                    @{Label=”MPIO-Id”;Expression={$_.mpioid};align='right'},
                    @{Label=”Status”;Expression={$_.StatusInfo}},
                    @{Label=”Port”;Expression={$_.SCSIPort}},
                    @{Label=”Bus”;Expression={$_.scsibus}},
                    @{Label=”Target”;Expression={$_.SCSITargetId}},
                    @{Label=”LUN”;Expression={$_.scsilogicalunit}}, 
                    @{Label=”Serial”;Expression={if ($_.SerialNumber.Length -gt 17) {$_.SerialNumber.SubString(0,14)+"..."} else {$_.SerialNumber}}},
                    @{Label=”Size(GB)”;Expression={[Math]::Round($_.size / 1GB, 0)}}, 
                    @{Label=”Parts”;Expression={$_.Partitions}},
                    @{Label=”PStyle”;Expression={$_.PartitionStyle}},
                    @{Label="Type";Expression={if ($_.Caption.Length -gt 24) { $_.Caption.SubString(0,21)+"..."} else { $_.Caption }}},
                    @{Label=”Firmw.”;Expression={$_.FirmwareRevision}} -autosize |  
                Out-String).Trim() |
                more
    }

    Write-Output " "
}

<#---------------------------------------------------------------------------------------------------------+
    Function for rescanning (finding newly attached LUNs, and setting them online after security prompt    |
----------------------------------------------------------------------------------------------------------#>
function set-online
{
        Write-Output " "
        $pdevsBeforeScan = @(Get-Disk)
        Write-Output "$($pdevsBeforeScan.count) disks found before scanning."
        Write-Output "Rescanning storage, please wait (in case of Fiberchannel attachments scan could take some time) ..."
		Update-HostStorageCache
        Sleep -s 2
        $pdevsAfterScan = @(Get-Disk)
        Write-Output "$($pdevsAfterScan.count) disks found after scanning."

		$pdevs = @(Get-Disk | Where-Object { $_.IsReadOnly -or $_.IsOffline })  
        if ($pdevs.count -eq 0)
        {
            Write-Output "No offline or readonly devices found, no need to set anything online."
        }
        else
        {
 		    ( $pdevs |
                ft  @{Label=”Disk”;Expression={$_.number}},
                    @{Label=”Manufacturer”;Expression={$_.Manufacturer}},
                    @{Label=”Model”;Expression={$_.Model}},
                    @{Label=”PS”;Expression={$_.partitionStyle}},
                    @{Label=”Size(GB)”;Expression={[Math]::Round($_.size / 1GB, 0)}}, 
                    @{Label=”Readonly”;Expression={$_.IsReadOnly}},  
                    @{Label=”Offline”;Expression={$_.IsOffline}} -autosize |  
                Out-String).Trim()
	        Write-Output " "
            "Trying to set $($pdevs.count) offline or readonly devices online and make them R/W, continue (y/n) ?"

            $prompt = Read-Host
            if ($prompt -ne "y") { exit }
            $pdevs | ForEach-Object { Sleep -m 200 | Out-Null; $_ } |  Set-Disk –IsOffline $False
            $pdevs |  Set-Disk –IsReadOnly $False
            Write-Output " "
            (Get-Disk $pdevs.number |
                ft  @{Label=”Disk”;Expression={$_.number}},
                    @{Label=”Manufacturer”;Expression={$_.Manufacturer}},
                    @{Label=”Model”;Expression={$_.Model}},
                    @{Label=”PS”;Expression={$_.partitionStyle}},
                    @{Label=”Size(GB)”;Expression={[Math]::Round($_.size / 1GB, 0)}}, 
                    @{Label=”Readonly”;Expression={$_.IsReadOnly}},  
                    @{Label=”Offline”;Expression={$_.IsOffline}} -autosize |  
                Out-String).Trim()

        }
        Write-Output " "
}


<#---------------------------------------+
    Function for Purestorage MPIO setup  |
-----------------------------------------#>
function set-PureMPIO
{
		$MPIO = Get-WindowsFeature Multipath-IO
        if ($MPIO.Installed) {
             Write-Output "MPIO installation skipped, is already installed."
        }
        else {
             Write-Output “Installing Feature 'MPIO' ...”
             Enable-WindowsOptionalFeature -Online -FeatureName MultipathIO
        }
        Write-Output " " 
        Write-Output “Enabling MPIO for Purestorage Arrays ...”
        New-MSDSMSupportedHW -ProductID "FlashArray" -VendorID "PURE"
        Write-Output " " 
        Write-Output "Setting Microsoft DSM parameters for Purestorage Arrays: "
		if ($RR) {
			Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR
		}
		else {
			Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy LQD
		}
        Set-MPIOSetting -NewPathRecoveryInterval 20
		Set-MPIOSetting -CustomPathRecovery Enabled
		Set-MPIOSetting -NewPDORemovePeriod 30
		Set-MPIOSetting -NewDiskTimeout 60
		Set-MPIOSetting -NewPathVerificationState Enabled
		
        Write-Output "LoadBalancingPolicy       : $(Get-MSDSMGlobalDefaultLoadBalancePolicy)"
        (Get-MPIOSetting | Out-String).Trim()
        Write-Output " "
}
<#---------------------------------------+
    usage function                       |
-----------------------------------------#>
function get-usage
{
        " "
        "Usage (Version 2.3):"
        " " 
        "hsTools  < -installFC | -installiSCSI | -qMPIO | -qdisks disknumber | -qLUNs LUNnumber | -online | -qhba > "
        "            [-RR] [-detail] [-filesystems] [-help]" 
        " "
        "(Parameters in the first line are mutually exclusive, parameters in the second line are optional). "
		" "
        "-installFC (or -iFC)      : Sets up MPIO for Purestorage fiberchannel devices, and installs" 
        "                            Microsoft MPIO-feature before, if not already installed."
        " "
        "-installiSCSI (or -iSCSI) : Sets up MPIO for Purestorage iSCSI devices, and installs Microsoft"
        "                            MPIO-feature before, if not already installed."
        " "
		"-qMPIO (or -qsettings)    : Displays the current MPIO settings of this server."
        " "
		"-qdisks disknumber        : Displays serverdisks by MS-Windows disknumbers."
        "                            'disknumber' can be '*' for all, or a single disknumber, or"
        "                            a list like '0,7,2,18', or a range like '0..5' or '0-5'."
        " "
		"-qLUNs LUN-number         : Displays serverdisks by LUN-numbers."
        "                            'LUN-number' can be '*' for all, or a single LUN-number, or"
        "                            a list like '0,7,2,18', or a range like '0..5' or '0-5'."
        " "
		"-online                   : Rescans the storage environment for newly assigned LUNs, and sets"
        "                            all offline LUNs online on this server (after y/n prompt)."
        " "
        "-qHBA                     : Displays FC HBA-info like WWNs, driverversions etc."
        " " 
		"-RR                       : If specified together with -iFC or -iSCSI, sets the loadbalancing" 
        "                            policy to RoundRobin instead of LeastQueueDepth."
        " "
		"-detail                   : If specified together with -qdisks or -qLUNs, displays detailed" 
        "                            information about the requested Disks/LUNs including MPIO pathes."
        " " 
		"-filesystems              : If specified together with -qdisks or -qLUNs, displays information" 
        "                            about the partitions and filesystems on the Disks/LUNs."
        " " 
		"-help                     : Displays this usage info." 
        " "
}

<#-------------------------------------------------------------------------------------------------------+
    PROC OPTIONS(MAIN)   :-)	the grand final                                                        	 |
---------------------------------------------------------------------------------------------------------#>

#Requires -RunAsAdministrator

$ServerTest = (Get-WmiObject win32_operatingsystem)
$ServerCaption = $ServerTest.Caption
$ServerVersion = ($ServerTest.Version).SubString(0,3) -as [double]
$PSVersion = $PSVersionTable.PSVersion.Major -as [double]

if ( ! $ServerCaption.contains("Server") -or $ServerVersion -lt 6.2 -or $PSVersion -lt 5) {
	Write-Output "";
	Write-Output "+--------------------------------------------------------------------------------+"; 
	Write-Output "Script only supported under Windows 2012 Server and above, Powershell 5 and above.";
    Write-Output "(It seems, I'm running under $($ServerCaption), Build $($Servertest.Buildnumber), Powershell $($PSVersion).)"	
	Write-Output "+--------------------------------------------------------------------------------+"; 
	Write-Output ""; 
	Get-Usage;
	exit; 
}

$MPIO = New-Object PSCustomObject -Property @{
	    		installed = $true
		}

$mpclaim = cmd /c mpclaim '2>&1' | Out-String
if ($mpclaim -match "is not recognized as")
{
	$MPIO.installed = $false
}

$pshost = Get-Host             
$pswindow = $pshost.UI.RawUI   
$newsize = $pswindow.BufferSize 

if ($newsize.width -lt 148) { 
    $newsize.width = 148            
    $pswindow.buffersize = $newsize
	$newsize = $pswindow.windowsize
	$newsize.width = 148
	$pswindow.windowsize = $newsize
}

if ($installFC)
{
		set-PureMPIO
}
elseif ($installiSCSI)
{
		set-PureMPIO
		Set-Service -Name msiscsi -StartupType Automatic -Status Running
        (Get-InitiatorPort |
                Where-Object {($_.NodeAddress -match "iqn")} |
                ft @{Label=”NodeAddress”;Expression={$_.NodeAddress}},
                   @{Label=”PortAddress”;Expression={$_.PortAddress}} -autosize |                 
                Out-String).Trim()
        (Get-Service -name MSiSCSI |
                 ft @{Label=””;Expression={$_.DisplayName}},                
                    @{Label=””;Expression={$_.Status}} -autosize -HideTableHeaders |
                 Out-String).Trim()
        $global:ConfirmPreference = "None"
        $temp = (Enable-MSDSMAutomaticClaim -BusType iSCSI)
}
elseIf ($qsettings)
{
        if ($MPIO.Installed) {
             get-mpioInfo
        }
        else {
             Write-Output “Windows MPIO feature is not installed.”
        }

}
elseIf ($qHBA)
{
        get-hbaInfo
}
elseIf ($qdisks -or $qLUNs)
{
        Write-Output " "
        Write-Output "Collecting disk info (MPIO & Non-MPIO), please wait ..."
        Write-Output " "
        get-vdiskInfo
}
elseIf ($online)
{
        set-online
}
else
{
        get-usage
}
