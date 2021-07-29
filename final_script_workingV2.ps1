$org = Read-Host "  ...Please Input Organization Name (any format is fine)" 
New-Item $org -type directory
$fullpath = dir -Directory | Where-Object {$_.Name -like "$org"} | Select-Object -ExpandProperty FullName

#logfile
$Logfile = $fullpath + '\' + $org +'\'+"script-log.txt"
Function LogWrite
{
   Param ([string]$logstring)
   Add-content $Logfile -value $logstring
}

    $f1 = $fullpath + '\' + $org + "_365GroupsReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f2 = $fullpath + '\' + $org + "_365GroupsMembershipsReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f3 = $fullpath + '\' + $org + "_AzureGlobalAdminsReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f4 = $fullpath + '\' + $org + "_UsersReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f5 = $fullpath + '\' + $org + "_UsersDeletedReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f6 = $fullpath + '\' + $org + "_OneDriveStorageReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f7 = $fullpath + '\' + $org + "_SharepointSitesStorageReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f8 = $fullpath + '\' + $org + "_AzureDomainsReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f9 = $fullpath + '\' + $org + "_AzureTenantDetails_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
    $f10 = $fullpath + '\' + $org + "_AzureDevicesReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"
	$f11 = $fullpath + '\' + $org + "_365DistributionListsReport_$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).csv"

#master pscred - global admin 365
$credential = Get-Credential
#AAD/msol modules
Connect-MsolService -Credential $credential
Connect-AzureAD -Credential $credential
#exchange
$session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $credential -Authentication Basic -AllowRedirection -ErrorAction Stop
Import-PSSession $session -ErrorAction Stop
#sharepoint
$TenantExpanded = get-azureaddomain | Where-Object {$_.IsInitial -eq "True"} | Select-Object -ExpandProperty Name
$TenantTrimmed = $TenantExpanded.Substring(0,$TenantExpanded.Length-16)
$TenantTrimmed=$TenantTrimmed.ToLower()
$tenantadmin = "https://" + $TenantTrimmed + "-admin.sharepoint.com"
$onedriveurl="https://" + $TenantTrimmed + "-my.sharepoint.com/personal/"
Connect-SPOService -Url $tenantadmin -Credential $credential
#Helper function for fetching data from Exchange Online
function Get-O365GroupMembershipInventory {

    [CmdletBinding()]
    Param( [Switch]$CondensedOutput) #Specify whether to write the output in condensed format
    #Confirm connectivity to Exchange Online
    try { $session = Get-PSSession -InstanceId (Get-AcceptedDomain | select -First 1).RunspaceId.Guid -ErrorAction Stop }
    catch {
        try {
            $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $credential -Authentication Basic -AllowRedirection -ErrorAction Stop
            Import-PSSession $session -ErrorAction Stop | Out-Null
            }
        catch { Write-Error "No active Exchange Online session detected, please connect to ExO first: https://technet.microsoft.com/en-us/library/jj984289(v=exchg.160).aspx" -ErrorAction Stop; return }
    }
    #Get a list of all recipients that support ManagedBy/Owner attribute
    $O365Groups = Invoke-Command -Session $session -ScriptBlock { Get-UnifiedGroup -ResultSize Unlimited | Select-Object -Property Displayname,PrimarySMTPAddress,ExternalDirectoryObjectId,ResourceProvisioningOptions,AccessType,SharePointSiteUrl,IsMailboxConfigured,GroupType,Managedby,ManagedByDetails,GroupMemberCount,HiddenGroupMembershipEnabled,HiddenFromExchangeClientsEnabled,HiddenFromAddressListsEnabled,GroupExternalMemberCount,IsDeleted } -HideComputerName 
 
#############################################################
#export Groups here (member comes next)
    $O365Groups | Export-CSV -nti -Path $f1
#############################################################
    #If no objects are returned from the above cmdlet, stop the script and inform the user
    if (!$O365Groups) { Write-Error "No Office 365 groups found" -ErrorAction Continue }

    #Once we have the O365 Groups list, cycle over each group to gather membership
    $arrMembers = @()
    $count = 1; $PercentComplete = 0;
    foreach ($o in $O365Groups) {
        #Progress message
        $ActivityMessage = "Retrieving data for mailbox $($o.DisplayName). Please wait..."
        $StatusMessage = ("Processing mailbox {0} of {1}: {2}" -f $count, @($O365Groups).count, $o.PrimarySmtpAddress.ToString())
        $PercentComplete = ($count / @($O365Groups).count * 100)
        Write-Progress -Activity $ActivityMessage -Status $StatusMessage -PercentComplete $PercentComplete
        $count++

        #Add some artificial delay to combat throttling
        Start-Sleep -Milliseconds 500

        #Gather the LINKS for each Group
        $oMembers = Invoke-Command -Session $session -ScriptBlock { Get-UnifiedGroupLinks -Identity $using:o.ExternalDirectoryObjectId -LinkType Members -ResultSize Unlimited | Select-Object -Property WindowsLiveID, RecipientTypeDetails} -HideComputerName
        $oGuests = $oMembers | ? {$_.RecipientTypeDetails.ToString() -eq "GuestMailUser"}
        $oOwners = Invoke-Command -Session $session -ScriptBlock { Get-UnifiedGroupLinks -Identity $using:o.ExternalDirectoryObjectId -LinkType Owners -ResultSize Unlimited | Select-Object -Property WindowsLiveID, RecipientTypeDetails} -HideComputerName
        $oSubscribers = Invoke-Command -Session $session -ScriptBlock { Get-UnifiedGroupLinks -Identity $using:o.ExternalDirectoryObjectId -LinkType Subscribers -ResultSize Unlimited | Select-Object -Property WindowsLiveID, RecipientTypeDetails} -HideComputerName

        #If NOT using the $condensedoutput switch, each individual Link will be listed on a single line in the output
        if (!$CondensedOutput) {
            #Make sure to add Aggregators and EventSubscribers once they start working
            foreach ($oMember in $oMembers) {
                #Prepare the output object
                $objMember = New-Object PSObject
                $i++;Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Number" -Value $i
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "DisplayName" -Value $o.DisplayName
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "PrimarySMTPAddress" -Value $o.PrimarySMTPAddress.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Member" -Value $oMember.WindowsLiveID.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "MemberType" -Value "Member"
                $arrMembers += $objMember
            }
            foreach ($oMember in $oOwners) {
                #Prepare the output object
                $objMember = New-Object PSObject
                $i++;Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Number" -Value $i
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "DisplayName" -Value $o.DisplayName
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "PrimarySMTPAddress" -Value $o.PrimarySMTPAddress.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Member" -Value $oMember.WindowsLiveID.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "MemberType" -Value "Owner"
                $arrMembers += $objMember
            }
            foreach ($oMember in $oSubscribers) {
                #Prepare the output object
                $objMember = New-Object PSObject
                $i++;Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Number" -Value $i
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "DisplayName" -Value $o.DisplayName
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "PrimarySMTPAddress" -Value $o.PrimarySMTPAddress.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Member" -Value $oMember.WindowsLiveID.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "MemberType" -Value "Subscriber"
                $arrMembers += $objMember
            }
            foreach ($oMember in $oGuests) {
                #Prepare the output object
                $objMember = New-Object PSObject
                $i++;Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Number" -Value $i
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "DisplayName" -Value $o.DisplayName
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "PrimarySMTPAddress" -Value $o.PrimarySMTPAddress.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Member" -Value $oMember.WindowsLiveID.ToString()
                Add-Member -InputObject $objMember -MemberType NoteProperty -Name "MemberType" -Value "Guest"
                $arrMembers += $objMember
            }
        }
        else {
            #If using condensed output, use single line per Group
            #Make sure to add Aggregators and EventSubscribers once they start working
            $o | Add-Member "Owners" $($oOwners.WindowsLiveID -join ";")
            $o | Add-Member "Members" $($oMembers.WindowsLiveID -join ";")
            $o | Add-Member "Subscribers" $($oSubscribers.WindowsLiveID -join ";")
            $o | Add-Member "Guests" (&{If ($oGuests) {$($oGuests.WindowsLiveID -join ",")} else {""}})
            $arrMembers += $o
        }}
    #Return the output
    $arrMembers | select * -ExcludeProperty Number,PSComputerName,RunspaceId,PSShowComputerName,ExternalDirectoryObjectId
}
#Get the Office 365 Group membership reports
Get-O365GroupMembershipInventory @PSBoundParameters -OutVariable global:varO365GroupMembers | Export-Csv -nti -Path $f2

#Now get distribution lists & Membership
Out-File -FilePath $f11 -InputObject "Distribution Group DisplayName,Distribution Group Email,Member DisplayName, Member Email, Member Type" -Encoding UTF8  
$objDistributionGroups = Get-DistributionGroup -ResultSize Unlimited 
Foreach ($objDistributionGroup in $objDistributionGroups)  
{
    write-host "Processing $($objDistributionGroup.DisplayName)..."  
    #Get members of this group  
    $objDGMembers = Get-DistributionGroupMember -Identity $($objDistributionGroup.PrimarySmtpAddress)  
      
    write-host "Found $($objDGMembers.Count) members..."  
    #Iterate through each member  
    Foreach ($objMember in $objDGMembers)  
    {  Out-File -FilePath $f11 -InputObject "$($objDistributionGroup.DisplayName),$($objDistributionGroup.PrimarySMTPAddress),$($objMember.DisplayName),$($objMember.PrimarySMTPAddress),$($objMember.RecipientType)" -Encoding UTF8 -append 
	}  
}
##############

#Report for global admins
$AADRoles = Get-AzureADDirectoryRole
$RolesHash = @{}
#Cycle each role and gather a list of users and service principals assigned
foreach ($AADRole in $AADRoles) {
       $AADRoleMembers = Get-AzureADDirectoryRoleMember -ObjectId $AADRole.ObjectId
        #if no role members assigned, skip
        if (!$AADRoleMembers) { continue }
    
        foreach ($AADRoleMember in $AADRoleMembers) {
            #prepare the output
            if (!$RolesHash[$AADRoleMember.ObjectId]) {
                $RolesHash[$AADRoleMember.ObjectId] = @{
                    "UserPrincipalName" = (&{If($AADRoleMember.ObjectType -eq "User") {$AADRoleMember.UserPrincipalName} Else {$AADRoleMember.AppId}})
                    "DisplayName" = $AADRoleMember.DisplayName
                    "Roles" = $AADRole.DisplayName
                    }
                }
            #if the same object was returned as a member of previous role(s)
            else { $RolesHash[$AADRoleMember.ObjectId].Roles += $(", " + $AADRole.DisplayName)  }
        }
    }
    #format and export
$report = foreach ($key in ($RolesHash.Keys)) { $RolesHash[$key] | % { [PSCustomObject]$_ } }
$report | sort DisplayName | Export-CSV -nti -Path $f3

######
# user report

function get-aad { 
    $i=0 
    do { 
        Write-Progress -activity "fetching mailboxes..." -Status "please wait" 
        $users = get-msoluser -All | Select *
        $i++ 
        
    }until ($i -eq 1) 
 
    return $users
} 

function get-aaddeleted { 
    $i=0 
    do { 
        Write-Progress -activity "fetching mailboxes..." -Status "please wait" 
        $users = get-msoluser -ReturnDeletedUsers | Select *
        $i++ 
    }until ($i -eq 1) 
 
    return $users
} 

function get-licenses ([String]$uservar) { 
    $assignedlicense = "" 
    $Tassignedlicense = "" 
    $Fassignedlicense = "" 
    $Sku = @{ 
		"AAD_BASIC"							     = "Azure Active Directory Basic"
		"RMS_S_ENTERPRISE"					     = "Azure Active Directory Rights Management"
		"AAD_PREMIUM"						     = "Azure Active Directory Premium P1"
		"AAD_PREMIUM_P2"						 = "Azure Active Directory Premium P2"
		"MFA_PREMIUM"						     = "Azure Multi-Factor Authentication"
		"RIGHTSMANAGEMENT"					     = "Azure Information Protcetion Plan 1"
		"O365_BUSINESS_ESSENTIALS"			     = "Office 365 Business Essentials"
		"O365_BUSINESS_PREMIUM"				     = "Office 365 Business Premium"
		"ADALLOM_O365"                           = "Office 365 Cloud App Security"
		"ADALLOM_S_DISCOVERY"					 = "Unknown"
		"EXCHANGESTANDARD"					     = "Office 365 Exchange Online Only"
		"STANDARDPACK"						     = "Enterprise Plan E1"
		"STANDARDWOFFPACK"					     = "Office 365 (Plan E2)"
		"ENTERPRISEPACK"						 = "Enterprise Plan E3"
		"ENTERPRISEPACKLRG"					     = "Enterprise Plan E3"
		"ENTERPRISEWITHSCAL"					 = "Enterprise Plan E4"
		"DESKLESSPACK"						     = "Office 365 (Plan K1)"
		"DESKLESSWOFFPACK"					     = "Office 365 (Plan K2)"
		"LITEPACK"							     = "Office 365 (Plan P1)"
		"STANDARDPACK_STUDENT"				     = "Office 365 (Plan A1) for Students"
		"STANDARDWOFFPACKPACK_STUDENT"		     = "Office 365 (Plan A2) for Students"
		"ENTERPRISEPACK_STUDENT"				 = "Office 365 (Plan A3) for Students"
		"ENTERPRISEWITHSCAL_STUDENT"			 = "Office 365 (Plan A4) for Students"
		"STANDARDPACK_FACULTY"				     = "Office 365 (Plan A1) for Faculty"
		"STANDARDWOFFPACKPACK_FACULTY"		     = "Office 365 (Plan A2) for Faculty"
		"ENTERPRISEPACK_FACULTY"				 = "Office 365 (Plan A3) for Faculty"
		"ENTERPRISEWITHSCAL_FACULTY"			 = "Office 365 (Plan A4) for Faculty"
		"ENTERPRISEPACK_B_PILOT"				 = "Office 365 (Enterprise Preview)"
		"STANDARD_B_PILOT"					     = "Office 365 (Small Business Preview)"
		"VISIOCLIENT"						     = "Visio Pro Online"
		"POWER_BI_ADDON"						 = "Office 365 Power BI Addon"
		"POWER_BI_INDIVIDUAL_USE"			     = "Power BI Individual User"
		"POWER_BI_STANDALONE"				     = "Power BI Stand Alone"
		"POWER_BI_STANDARD"					     = "Power-BI Standard"
		"PROJECTESSENTIALS"					     = "Project Lite"
		"PROJECTCLIENT"						     = "Project Professional"
		"PROJECTONLINE_PLAN_1"				     = "Project Online"
		"PROJECTONLINE_PLAN_2"				     = "Project Online and PRO"
		"ProjectPremium"						 = "Project Online Premium"
		"ECAL_SERVICES"						     = "ECAL"
		"EMS"								     = "Enterprise Mobility Suite"
		"RIGHTSMANAGEMENT_ADHOC"				 = "Windows Azure Rights Management"
		"MCOMEETADV"							 = "PSTN conferencing"
		"SHAREPOINTSTORAGE"					     = "SharePoint storage"
		"PLANNERSTANDALONE"					     = "Planner Standalone"
		"CRMIUR"								 = "CMRIUR"
		"BI_AZURE_P1"						     = "Power BI Reporting and Analytics"
		"INTUNE_A"							     = "Windows Intune Plan A"
		"PROJECTWORKMANAGEMENT"				     = "Office 365 Planner Preview"
		"ATP_ENTERPRISE"						 = "Exchange Online Advanced Threat Protection"
		"EQUIVIO_ANALYTICS"					     = "Office 365 Advanced eDiscovery"
		"STANDARDPACK_GOV"					     = "Microsoft Office 365 (Plan G1) for Government"
		"STANDARDWOFFPACK_GOV"				     = "Microsoft Office 365 (Plan G2) for Government"
		"ENTERPRISEPACK_GOV"					 = "Microsoft Office 365 (Plan G3) for Government"
		"ENTERPRISEWITHSCAL_GOV"				 = "Microsoft Office 365 (Plan G4) for Government"
		"DESKLESSPACK_GOV"					     = "Microsoft Office 365 (Plan K1) for Government"
		"ESKLESSWOFFPACK_GOV"				     = "Microsoft Office 365 (Plan K2) for Government"
		"EXCHANGESTANDARD_GOV"				     = "Microsoft Office 365 Exchange Online (Plan 1) only for Government"
		"EXCHANGEENTERPRISE_GOV"				 = "Microsoft Office 365 Exchange Online (Plan 2) only for Government"
		"SHAREPOINTDESKLESS_GOV"				 = "SharePoint Online Kiosk"
		"EXCHANGE_S_DESKLESS_GOV"			     = "Exchange Kiosk"
		"RMS_S_ENTERPRISE_GOV"				     = "Windows Azure Active Directory Rights Management"
		"OFFICESUBSCRIPTION_GOV"				 = "Office ProPlus"
		"MCOSTANDARD_GOV"					     = "Lync Plan 2G"
		"SHAREPOINTWAC_GOV"					     = "Office Online for Government"
		"SHAREPOINTENTERPRISE_GOV"			     = "SharePoint Plan 2G"
		"EXCHANGE_S_ENTERPRISE_GOV"			     = "Exchange Plan 2G"
		"EXCHANGE_S_ARCHIVE_ADDON_GOV"		     = "Exchange Online Archiving"
		"EXCHANGE_S_DESKLESS"				     = "Exchange Online Kiosk"
		"SHAREPOINTDESKLESS"					 = "SharePoint Online Kiosk"
		"SHAREPOINTWAC"						     = "Office Online"
		"YAMMER_ENTERPRISE"					     = "Yammer for the Starship Enterprise"
		"EXCHANGE_L_STANDARD"				     = "Exchange Online (Plan 1)"
		"MCOLITE"							     = "Lync Online (Plan 1)"
		"SHAREPOINTLITE"						 = "SharePoint Online (Plan 1)"
		"OFFICE_PRO_PLUS_SUBSCRIPTION_SMBIZ"	 = "Office ProPlus"
		"EXCHANGE_S_STANDARD_MIDMARKET"		     = "Exchange Online (Plan 1)"
		"MCOSTANDARD_MIDMARKET"				     = "Lync Online (Plan 1)"
		"SHAREPOINTENTERPRISE_MIDMARKET"		 = "SharePoint Online (Plan 1)"
		"OFFICESUBSCRIPTION"					 = "Office ProPlus"
		"YAMMER_MIDSIZE"						 = "Yammer"
		"DYN365_ENTERPRISE_PLAN1"			     = "Dynamics 365 Customer Engagement Plan Enterprise Edition"
		"ENTERPRISEPREMIUM_NOPSTNCONF"		     = "Enterprise E5 (without Audio Conferencing)"
		"ENTERPRISEPREMIUM"					     = "Enterprise E5 (with Audio Conferencing)"
		"MCOSTANDARD"						     = "Skype for Business Online Standalone Plan 2"
		"PROJECT_MADEIRA_PREVIEW_IW_SKU"		 = "Dynamics 365 for Financials for IWs"
		"STANDARDWOFFPACK_IW_STUDENT"		     = "Office 365 Education for Students"
		"STANDARDWOFFPACK_IW_FACULTY"		     = "Office 365 Education for Faculty"
		"EOP_ENTERPRISE_FACULTY"				 = "Exchange Online Protection for Faculty"
		"EXCHANGESTANDARD_STUDENT"			     = "Exchange Online (Plan 1) for Students"
		"OFFICESUBSCRIPTION_STUDENT"			 = "Office ProPlus Student Benefit"
		"STANDARDWOFFPACK_FACULTY"			     = "Office 365 Education E1 for Faculty"
		"STANDARDWOFFPACK_STUDENT"			     = "Microsoft Office 365 (Plan A2) for Students"
		"DYN365_FINANCIALS_BUSINESS_SKU"		 = "Dynamics 365 for Financials Business Edition"
		"DYN365_FINANCIALS_TEAM_MEMBERS_SKU"	 = "Dynamics 365 for Team Members Business Edition"
		"FLOW_FREE"							     = "Microsoft Flow Free"
		"POWER_BI_PRO"						     = "Power BI Pro"
		"O365_BUSINESS"						     = "Office 365 Business"
		"DYN365_ENTERPRISE_SALES"			     = "Dynamics Office 365 Enterprise Sales"
		"PROJECTPROFESSIONAL"				     = "Project Professional"
		"VISIOONLINE_PLAN1"					     = "Visio Online Plan 1"
		"EXCHANGEENTERPRISE"					 = "Exchange Online Plan 2"
		"DYN365_ENTERPRISE_P1_IW"			     = "Dynamics 365 P1 Trial for Information Workers"
		"DYN365_ENTERPRISE_TEAM_MEMBERS"		 = "Dynamics 365 For Team Members Enterprise Edition"
		"CRMSTANDARD"						     = "Microsoft Dynamics CRM Online Professional"
		"EXCHANGEARCHIVE_ADDON"				     = "Exchange Online Archiving For Exchange Online"
		"EXCHANGEDESKLESS"					     = "Exchange Online Kiosk"
		"SPZA_IW"							     = "App Connect"
		"SPB"                                    = "Microsoft 365 Business"
		"AAD_SMB"								 = ""
		"BPOS_S_TODO_1"							 = "Microsoft To Do"
		"DESKLESS"								 = ""
		"EXCHANGE_S_ARCHIVE_ADDON"				 = ""
		"EXCHANGE_S_STANDARD"					 = ""
		"INTUNE_SMBIZ"							 = ""
		"WINBIZ"								 = "Windows 10 Business"
		"SPE_E3"								 = "Microsoft 365 E3"
		"TEAMS1"                                 = "Microsoft Teams"
		"MCOPSTN1"								 = "Domestic Calling Plan"
		"MCOPSTNC"								 = "Communication Credits"
		"MCOPSTN2"								 = "Domestic and International Calling Plan"
		"MCOMEETACPEA"							 = "Audio Conferencing Pay-Per-Minute"
		"WIN_ENT_E5"                             = "Windows Ent E5"
		"POWERAPPS_VIRAL"						 = "Microsoft PowerApps Plan 2 Trial"
		"SMB_APPS" = "SMB Apps/Bookings"
        "TEAMS_COMMERCIAL_TRIAL" = "Teams Commercial Trial"
		"NonLicensed" = "User is Not Licensed" 
        "DEFAULT_0" = "Unrecognized License" 
    } 
    $licenseparts = (Get-MsolUser -UserPrincipalName $uservar).licenses.AccountSku.SkuPartNumber 
    foreach($license in $licenseparts) { 
        if($Sku.Item($license)) { 
            $Tassignedlicense = $Sku.Item("$($license)") + " + " + $Tassignedlicense 
        } 
        else { 
            Write-Warning -Message "user $($uservar) has an unrecognized license $license. Please update script." 
            $Fassignedlicense = $Sku.Item("DEFAULT_0") + " + " + $Fassignedlicense 
        } 
        $assignedlicense = $Tassignedlicense + $Fassignedlicense 
         
    } 
    return $assignedlicense 
} 
 
#Main #############################################
# SHAREPOINT STUFF
$Header = "BlockCredential,City,Country,Department,DisplayName,FirstName,LastName,PhoneNumber,AssignedLicense,LastPasswordChange,LastDirSync,PasswordNeverExpires,UserPrincipalName,OneDriveSize,MailboxSize,MailboxType,ProxyAddresses,StrongPasswordRequired,Created,UserType"
$OutputFile = $f4 
Out-File -FilePath $OutputFile -InputObject $Header -Encoding UTF8 -append 

$i=1 
$j=0
$users = get-aad 

Write-Host -Object "found $($users.count) users" -ForegroundColor Cyan 
foreach($u in $users) { 
    if($j -eq 0) 
    { 
        $i++ 
     
        $watch = [System.Diagnostics.Stopwatch]::StartNew() 

        

        $blocked = $u.BlockCredential 
        $city = $u.City
        $country = $u.Country
        $dept = $u.Department
        $display = $u.DisplayName
        $first = $u.FirstName
        $last = $u.LastName 
        $phone = $u.PhoneNumber
        $assignedlicense = get-licenses -user $u.UserPrincipalName 
        $pwchange = $u.LastPasswordChangeTimestamp
        $dirsync = $u.LastDirSyncTime
        $pwexpire = $u.PasswordNeverExpires
        $upn = $u.UserPrincipalName 
        $proxy = $u.ProxyAddresses
        $strong = $u.StrongPasswordRequired
        $created = $u.WhenCreated 
        $type = $u.UserType
        $statistics = get-mailboxstatistics -identity $u.UserPrincipalName -ErrorAction SilentlyContinue
        $size = $statistics.TotalItemSize.Value | Out-String
        if ([string]::IsNullOrEmpty($size)){$size=" "}else{$size = $size.Substring(0,8);$size = $size.Replace(",","");$size = $size.Replace("(","")}
        ##mailboxtype    
            try {
                 $mailboxtype = Get-Mailbox -Filter "WindowsLiveID -eq '$upn'" -ErrorAction SilentlyContinue | Select -ExpandProperty RecipientTypeDetails
                 $mailboxtype = $mailboxtype.Replace("Mailbox","")
                 }
            catch {
                 $mailboxtype = ""
                  }
        ##onedrivesize
        if ($type -eq "Member"){      
            try {
                $url = $onedriveurl + $u.UserPrincipalName.Replace(".","_").Replace("@","_")
                $onedrive = Get-SPOSite $url -ErrorAction SilentlyContinue                                     
                $onedrivesize = $onedrive.StorageUsageCurrent             
                 }
            catch {
                $onedrivesize = "0"           
                 }
        }

        $watch.Stop() 
        $seconds = $watch.elapsed.totalseconds.tostring() 
        $remainingseconds = ($users.Count-1)*$seconds 
         
        $j++ 
    } 
    else 
    { 
        Write-Progress -activity "processing $u" -status "$i Out Of $($users.Count) completed" -percentcomplete ($i / $($users.Count)*100) -secondsremaining $remainingseconds 
        $i++ 
        $remainingseconds = ($users.Count-$i)*$seconds 

        

        $blocked = $u.BlockCredential.ToString()
        $city = $u.City
        $country = $u.Country
        $dept = $u.Department
        $display = $u.DisplayName
        $first = $u.FirstName
        $last = $u.LastName 
        $phone = $u.PhoneNumber
        $assignedlicense = get-licenses -user $u.UserPrincipalName 
        $pwchange = $u.LastPasswordChangeTimestamp.ToString()
        $dirsync = $u.LastDirSyncTime
        $pwexpire = $u.PasswordNeverExpires
        $upn = $u.UserPrincipalName
        $proxy = $u.ProxyAddresses
        $strong = $u.StrongPasswordRequired
        $created = $u.WhenCreated
        $type = $u.UserType
        $statistics = get-mailboxstatistics -identity $u.UserPrincipalName -ErrorAction SilentlyContinue
        $size = $statistics.TotalItemSize.Value | Out-String
        if ([string]::IsNullOrEmpty($size)){$size=" "}else{$size = $size.Substring(0,8);$size = $size.Replace(",","");$size = $size.Replace("(","")}
        ##mailboxtype    
            try {
                 $mailboxtype = Get-Mailbox -Filter "WindowsLiveID -eq '$upn'" -ErrorAction SilentlyContinue | Select -ExpandProperty RecipientTypeDetails
                 $mailboxtype = $mailboxtype.Replace("Mailbox","")
                 }
            catch {
                 $mailboxtype = ""
                  }
        ##onedrivesize
        if ($type -eq "Member"){    
            try {
                $url = $onedriveurl + $u.UserPrincipalName.Replace(".","_").Replace("@","_")
                $onedrive = Get-SPOSite $url -ErrorAction SilentlyContinue                                     
                $onedrivesize = $onedrive.StorageUsageCurrent             
                 }
            catch {
                $onedrivesize = "0"           
                 }
        }  
    } 
    ##
    $Data = ("$blocked" + "," + $city + "," + $country + "," + $dept + "," + $display + "," + $first + "," + $last + "," + $phone + "," + $assignedlicense + "," + $pwchange + "," + $dirsync + "," + $pwexpire + "," + $upn + "," + $onedrivesize + "," + $size + "," + $mailboxtype + ',' + $proxy + "," + $strong + "," + $created + "," + $type) 
    Out-File -FilePath $OutputFile -InputObject $Data -Encoding UTF8 -append 
}
########
########
#do the same for deleted users list
$Header2 = "BlockCredential,City,Country,Department,DisplayName,FirstName,LastName,PhoneNumber,LastPasswordChange,LastDirSync,PasswordNeverExpires,UserPrincipalName,ProxyAddresses,StrongPasswordRequired,Created,UserType" 
$OutputFile2 = $f5
Out-File -FilePath $OutputFile2 -InputObject $Header2 -Encoding UTF8 -append 

$i=1 
$j=0
$users2 = get-aaddeleted

Write-Host -Object "found $($users2.count) users" -ForegroundColor Cyan 
foreach($u2 in $users2) { 
    if($j -eq 0) 
    { 
        $i++ 
     
        $watch = [System.Diagnostics.Stopwatch]::StartNew() 
 
        $blocked = $u2.BlockCredential 
        $city = $u2.City
        $country = $u2.Country
        $dept = $u2.Department
        $display = $u2.DisplayName
        $first = $u2.FirstName
        $last = $u2.LastName 
        $phone = $u2.PhoneNumber
        $pwchange = $u2.LastPasswordChangeTimestamp
        $dirsync = $u2.LastDirSyncTime
        $pwexpire = $u2.PasswordNeverExpires
        $upn = $u2.UserPrincipalName 
        $proxy = $u2.ProxyAddresses
        $strong = $u2.StrongPasswordRequired
        $created = $u2.WhenCreated 
        $type = $u2.UserType
 
        $watch.Stop() 
 
        $seconds = $watch.elapsed.totalseconds.tostring() 
        $remainingseconds = ($users2.Count-1)*$seconds 
         
        $j++ 
    } 
    else 
    { 
        Write-Progress -activity "processing $u2" -status "$i Out Of $($users2.Count) completed" -percentcomplete ($i / $($users2.Count)*100) -secondsremaining $remainingseconds 
        $i++ 
        $remainingseconds = ($users2.Count-$i)*$seconds 
 
        $blocked = $u2.BlockCredential.ToString()
        $city = $u2.City
        $country = $u2.Country
        $dept = $u2.Department
        $display = $u2.DisplayName
        $first = $u2.FirstName
        $last = $u2.LastName 
        $phone = $u2.PhoneNumber
        $pwchange = $u2.LastPasswordChangeTimestamp.ToString()
        $dirsync = $u2.LastDirSyncTime
        $pwexpire = $u2.PasswordNeverExpires
        $upn = $u2.UserPrincipalName
        $proxy = $u2.ProxyAddresses
        $strong = $u2.StrongPasswordRequired
        $created = $u2.WhenCreated
        $type = $u2.UserType
    } 
    ##
    $Data2 = ("$blocked" + "," + $city + "," + $country + "," + $dept + "," + $display + "," + $first + "," + $last + "," + $phone + "," + "," + $pwchange + "," + $dirsync + "," + $pwexpire + "," + $upn + "," + $proxy + "," + $strong + "," + $created + "," + $type) 
    Out-File -FilePath $OutputFile2 -InputObject $Data2 -Encoding UTF8 -append 
}
##############


$SharePointSKU = 'SharepointEnterprise'
$SharePointSKU2 = 'SharepointStandard'
$myarray = @()
$resultshash = @{}
$results
$users=get-msoluser -All
foreach ($user in $users){
    Foreach ($Plan in $User.Licenses.ServiceStatus){
        if (($Plan.servicePlan.servicename -like $SharePointSKU) -and $Plan.ProvisioningStatus -eq 'Success')
        {            
            try
                  {
                $url=$onedriveurl + $user.UserPrincipalName.Replace(".","_").Replace("@","_")
                $OneDrive=Get-SPOSite $url                                    
                        $myarray += New-Object psobject -Property @{DisplayName=$user.DisplayName.ToString();UPN=$user.UserPrincipalName.ToString();Country=$user.Country;LastModifiedDate=$OneDrive.LastContentModifiedDate; SizeMB=$onedrive.StorageUsageCurrent} -ErrorAction SilentlyContinue             
            }
                  catch
                  {
                  $myarray += New-Object psobject -Property @{DisplayName=$user.DisplayName.ToString();UPN=$user.UserPrincipalName.ToString();Country=$user.Country;LastModifiedDate=$OneDrive.LastContentModifiedDate;SizeMB="0"} -ErrorAction SilentlyContinue             
            }
        }
        elseif (($Plan.servicePlan.servicename -like $SharePointSKU2) -and $Plan.ProvisioningStatus -eq 'Success')
        {            
            try
                  {
                $url=$onedriveurl + $user.UserPrincipalName.Replace(".","_").Replace("@","_")
                $OneDrive=Get-SPOSite $url                                    
                        $myarray += New-Object psobject -Property @{DisplayName=$user.DisplayName.ToString();UPN=$user.UserPrincipalName.ToString();Country=$user.Country;LastModifiedDate=$OneDrive.LastContentModifiedDate; SizeMB=$onedrive.StorageUsageCurrent} -ErrorAction SilentlyContinue             
            }
                  catch
                  {
                  $myarray += New-Object psobject -Property @{DisplayName=$user.DisplayName.ToString();UPN=$user.UserPrincipalName.ToString();Country=$user.Country;LastModifiedDate=$OneDrive.LastContentModifiedDate;SizeMB="0"} -ErrorAction SilentlyContinue             
            }
        }
    }
}
$myarray | Select DisplayName,UPN,Country,LastModifiedDate,SizeMB| Sort-Object DisplayName | Export-Csv -nti -Path $f6
# Note: when you open c:\Temp\OneDriveUserStorage_$currentdate.csv then keep in mind this information: 
# A size of zero means OneDrive has not been provisioned
# A size of 1 means OneDrive has been provisioned but not used
# A size of larger than zero is the size of there OneDrive storage

####
####
#now for the group sizes

function get-spousage {
$sites = get-sposite
$array = @()
foreach($s in $sites){ 
$sc = Get-SPOSite $s -Detailed -ErrorAction SilentlyContinue | select url, storageusagecurrent, Title 
$objMember = New-Object PSObject
Add-Member -InputObject $objMember -MemberType NoteProperty -Name "URL" -Value $sc.url
Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Title" -Value $sc.Title
Add-Member -InputObject $objMember -MemberType NoteProperty -Name "Storage in MegaBytes" -Value $sc.storageusagecurrent
$array += $objMember
#$usage = $sc.StorageUsageCurrent
#New-Object PSObject -Property @{ 
#    URL  = $sc.url 
##   Title =$sc.Title 
#    StorageInMB = $usage 
#    }
#$Data3 = ("@PSObject"
    }
        $array | Select *
}
get-spousage | Export-csv -Path $f7 -nti
######

#AzureAD Domains Report
$domains = get-azureaddomain | select * ,@{Name='SupportedServices_flat';Expression={ConvertTo-Json $_.SupportedServices}} -ExcludeProperty AvailabilityStatus,State,SupportedServices,ForceDeleteState
$domains | Export-Csv -Path $f8 

#Azure Tenant full details report
$details = Get-AzureADTenantDetail | Select *,@{Name='AssignedPlans_flat';Expression={ConvertTo-Json $_.AssignedPlans}},@{Name='VerifiedDomains_flat';Expression={ConvertTo-Json $_.VerifiedDomains}} -ExcludeProperty AssignedPlans,VerifiedDomains
$details | Export-Csv -Path $f9 -nti

#Azure AD Devices (joined and registered)
$devices = Get-AzureADDevice | Select DisplayName, DeviceId, ProfileType, DeviceOSType, DeviceOSVersion
$devices | Export-Csv -Path $f10 -nti

Disconnect-AzureAD
Disconnect-SPOService
Get-PSSession | Remove-PSSession