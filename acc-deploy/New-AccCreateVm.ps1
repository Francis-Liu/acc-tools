# Copyright (c) Microsoft Corporation. All rights reserved.

<#

The script is used to deploy a sample ACC VM to support PCK provisioning.

Usage:

Create an ACC Linux VM (Assumes ssh keys will be used for auth)
.\New-AccCreateVm.ps1 -Subscription <SUB_NAME_OR_ID> -ResourceGroupName <EXISTING_OR_NEW> -AccImage acc-ubuntu-16 -VMName <NAME_OF_VM> -VmUserName <NAME_OF_USER> -VmGenerateSSHKeys
Note: The SSH Keys will be stored in "~/.ssh" on linux and "%userprofile%\.ssh" on Windows

Create an ACC Linux VM with specified password
.\New-AccCreateVm.ps1 -Subscription <SUB_NAME_OR_ID> -ResourceGroupName <EXISTING_OR_NEW> -AccImage acc-ubuntu-16 -VMName <NAME_OF_VM> -VmUserName <NAME_OF_USER> -VmPassword <PASSWORD>

Create an ACC Windows VM (If password is not specified, then script will prompt for password)
.\New-AccCreateVm.ps1 -Subscription <SUB_NAME_OR_ID> -ResourceGroupName <EXISTING_OR_NEW> --AccImage windows-server-2016-VMName <NAME_OF_VM> -VmUserName <NAME_OF_USER> -VmPassword <PASSWORD>

Create an ACC VM with 4 cores (instead of default 2)
.\New-AccCreateVm.ps1 -Subscription <SUB_NAME_OR_ID> -ResourceGroupName <EXISTING_OR_NEW> --AccImage <ACC_IMAGE> -VMName <NAME_OF_VM> -VmUserName <NAME_OF_USER> -VmPassword <PASSWORD>  -VmSize Standard_DC4s

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Subscription = "2ab0c1f8-57a3-460e-b21f-d1dd91908ddc",

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [ValidateSet("canonical-18.04", "canonical-16.04", "rhel-8.0", "windows-server-2016", "windows-server-2019")]
    [string]$AccImage,

    [Parameter(Mandatory=$false)]
    [ValidateSet("eastus", "westeurope","uksouth")]
    [string]$Location = "westeurope",

    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$true)]
    [string]$VmUserName,

    [Parameter(Mandatory=$false)]
    [string]$VmPassword,

    [Parameter(Mandatory=$false)] 
    [ValidateSet("Standard_DC2s_v2", "Standard_DC4s_v2", "Standard_DC8s_v2" )]
    [string]$VmSize = "Standard_DC2s_v2"
    )

. $PSScriptRoot\Utils.ps1

    

# Constants 
$ParameterNameVmPassword = "VmPassword"
$publickeyfile="key.pub"
$publickeyfilepath="$PSScriptRoot\$publickeyfile"

$LinuxString = "linux"
$WindowsString = "windows"
$NsgRuleWindows = "RDP"
$NsgRuleLinux = "SSH"
$all = "all"

# Image details


$ImgVersion = "latest"

if($AccImage -eq "canonical-18.04")
{
    $PublisherName = "Canonical"
    $Offer = "UbuntuServer"
    $Sku = "18_04-LTS-gen2"
    $ImageOsType = $LinuxString
    $NsgRule = $NsgRuleLinux
}
elseif($AccImage -eq "canonical-16.04")
{
    $PublisherName = "Canonical"
    $Offer = "UbuntuServer"
    $Sku = "16_04-LTS-gen2"
    $ImageOsType = $LinuxString
    $NsgRule = $NsgRuleLinux
}
elseif($AccImage -eq "rhel-8.0")
{
    $PublisherName = "RedHat"
    $Offer = "RHEL"
    $Sku = "8-gen2"
    $ImageOsType = $LinuxString
    $NsgRule = $NsgRuleLinux
}
elseif ($AccImage -eq "windows-server-2016") {
    $PublisherName = "MicrosoftWindowsServer"
    $Offer = "WindowsServer"
    $Sku = "2016-datacenter-gensecond"
    $ImageOsType = $WindowsString
    $NsgRule = $NsgRuleWindows
}
elseif ($AccImage -eq "windows-server-2019") {
    $PublisherName = "MicrosoftWindowsServer"
    $Offer = "WindowsServer"
    $Sku = "2019-datacenter-gensecond"
    $ImageOsType = $WindowsString
    $NsgRule = $NsgRuleWindows
}
else
{
    Write-Log -Type ERROR -Text "AccImage: $AccImage not supported through the marketplace."
    exit
} 

$NowUTC = $(Get-Date).ToUniversalTime()
$Global:LogFile = ($PSScriptRoot + "\New-AccCreateVmImageLog-" + "{0:yyyy.MM.dd.HH.mm.ss.fff}.log") -f $NowUTC

$ParameterString = @"
                          `t    `tSubscription: $Subscription
                          `t    `tResourceGroupName: $ResourceGroupName
                          `t    `tLocation: $Location
                          `t    `tAccImage: $AccImage
                          `t    `tPublisher: $PublisherName
                          `t    `tOffer: $Offer
                          `t    `tSku: $Sku
                          `t    `tVersion: $ImgVersion
                          `t    `tVmName: $VmName
                          `t    `tVmUsername: $VmUserName
                          `t    `tVmSize: $VmSize
                          `t    `tkey file: $publickeyfilepath
"@

Write-Log -Type INFO -Text "Log File: $($Global:LogFile)";
Write-Log -Type INFO -Text "New ACC VM:`r`n$ParameterString"

# Validate Subscription name/id

$SubscriptionObject = az account show --subscription $Subscription | ConvertFrom-Json
if(-not $SubscriptionObject)
{
    Write-Log -Type ERROR -Text "Subscription: $Subscription not found for existing account. Please run `"az login`" to login with right credentials."
    exit
}

# Set as Current Subscription
az account set --subscription $Subscription

# Create or Validate Resource Group 

if(-not (az group exists --name $ResourceGroupName | ConvertFrom-Json))
{
    Write-Log -Type INFO -Text "Creating Resource Group: $ResourceGroupName in Subscription: $Subscription."
    
    $ResourceGroupObject = az group create --name $ResourceGroupName --location $Location | ConvertFrom-Json
    if($ResourceGroupObject.properties.provisioningState -ne "Succeeded")
    {
        Write-Log -Type ERROR -Text "Could not create new ResourceGroup: $ResourceGroupName in Subscription: $Subscription."
        exit
    }

    Write-Log -Type INFO -Text "Created."
}
else
{
    $ResourceGroupObject = az group show --name $ResourceGroupName | ConvertFrom-Json
    if($ResourceGroupObject.location -ne $Location)
    {
        # Resource group creation failed.
        Write-Log -Type ERROR -Text "Resource group: $ResourceGroupName is in incorrect location.  Current value: $($ResourceGroupObject.location), Expected: $Location."
        exit
    }

}

# For windows vms, we require a password, prompt if not specifed
$params = $MyInvocation.BoundParameters;
if($ImageOsType -eq $WindowsString -and -not $params.ContainsKey($ParameterNameVmPassword))
{
    $cred = Get-Credential -UserName $VmUserName -Message "Specify credentials for your windows Vm."
    $VmPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password));

    if(-not $VmPassword)
    {
        Write-Log -Type ERROR -Text "No password specified. Windows VMs require a password. Exiting."
        exit
    }
}

Write-Log -Type INFO -Text "Creating $ImageOsType Vm: $VmName of VmSize: $VmSize."

#$ImageUrn = "$PublisherName`:$Offer`:$Sku`:2016.127.20180815"
$ImageUrn = "$PublisherName`:$Offer`:$Sku`:$ImgVersion"

 Write-Log -Type INFO -Text "Image URN: $ImageUrn"


$UseSSHKeysForAuth = $false

if($ImageOsType -eq $LinuxString)
{
    if(-not $params.ContainsKey($ParameterNameVmPassword))
    {
    
        $Vm_Object = az vm create --name $VMName --resource-group $ResourceGroupName --size $VmSize --admin-username $VmUserName --image $ImageUrn --location $Location --nsg-rule $NsgRule --ssh-key-value $publickeyfilepath | ConvertFrom-Json
    }
    else
    {
        $Vm_Object = az vm create --name $VMName --resource-group $ResourceGroupName --size $VmSize --admin-username $VmUserName --admin-password $VmPassword --image $ImageUrn --location $Location --nsg-rule $NsgRule -ssh-key-value $publickeyfilepath --authentication-type $all | ConvertFrom-Json
    }    
    $UseSSHKeysForAuth = $true
}
elseif ($ImageOsType -eq $WindowsString)
{
    if(-not $params.ContainsKey($ParameterNameVmPassword))
    {
    
        $Vm_Object = az vm create --name $VMName --resource-group $ResourceGroupName --size $VmSize --admin-username $VmUserName --image $ImageUrn --location $Location --nsg-rule $NsgRule | ConvertFrom-Json
    }
    $UseSSHKeysForAuth = $false
}

$VmPassword = "";

if($Vm_Object.publicIpAddress)
{
    Write-Log -Type INFO -Text "VM Created: $VmName, Public IP: $($Vm_Object.publicIpAddress)"
    
    if($UseSSHKeysForAuth)
    {
        Write-Log -Type INFO -Text "SSH key: $publickeyfilepath"
    }
}
else
{
    Write-Log -Type ERROR -Text "VM Creation failed."
}
