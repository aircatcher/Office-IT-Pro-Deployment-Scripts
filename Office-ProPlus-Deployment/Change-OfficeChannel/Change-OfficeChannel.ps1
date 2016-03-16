﻿Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
   public enum Channel
   {
      Current,
      Deferred,
      FirstReleaseCurrent,
      FirstReleaseDeferred
   }
"@


Function Change-OfficeChannel {
<#
.Synopsis
Uses OfficeC2RClient.exe tool to change version and branch of installed office
.DESCRIPTION
This function will upgrade or downgrade the version of Office to the version specified, or to the
most recent version of office found in the update folder in the Channel specified.  This function
also simultaneously changes the channel of Office installed on the client.
.NOTES   
Name: Change-OfficeChannel
DateUpdated: 2016-03-15
.PARAMETER Channel
The Channel associated with Office Updates ie Current, Deferred, etc.
.PARAMETER Version
The version of Office to install.  The install files must be located in the Channel update path
.EXAMPLE
Change-OfficeChannel -Channel Current
Description:
Switches the Channel of the Office install to Current, updates the current Office install to the most up recent update available in the
UpdateURL path.
.EXAMPLE
Change-OfficeChannel -Channel Current -Version 16.0.6001.1068
Description:
Switches the Channel of the Office install to Current, updates the current Office install to the version specified, as long as that version
is available in the UpdateURL path.
#>
  param(
    [Parameter(Mandatory=$true)]
    [Channel]$Channel
  )

  begin {

    $defaultDisplaySet = 'OldUpdatePath','NewUpdatePath','Version'
    $defaultDisplayPropertySet = New-Object System.Management.Automation.PSPropertySet(‘DefaultDisplayPropertySet’,[string[]]$defaultDisplaySet)
    $PSStandardMembers = [System.Management.Automation.PSMemberInfo[]]@($defaultDisplayPropertySet)

    $UpdateURLKey = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'  #UpdateURL
    $Office2RClientKey = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' #ClientFolder
}

  process {
    $results = new-object PSObject[] 0;
    $scriptPath = Get-ScriptPath

    $OldUpdatePath = $UpdateURLPath
    $UpdateURLPath = Change-UpdatePathToChannel -Channel $Channel -UpdatePath $UpdateURLPath

    $validSource = Test-UpdateSource -UpdateSource $UpdateURLPath
    if (!($validSource)) {
      throw "UpdateSource not Valid $UpdateURLPath"
    }

    $oldUpdatePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration").UpdateUrl
    if ($oldUpdatePath) {
       New-ItemProperty $Office2RClientKey -Name BackupUpdateUrl -PropertyType String -Value $oldUpdatePath -Force | Out-Null
    }

    New-ItemProperty $Office2RClientKey -Name UpdateUrl -PropertyType String -Value $UpdateURLPath -Force | Out-Null

    Set-OfficeCDNUrl -Channel $Channel

    $OfficeUpdatePath = Get-OfficeC2Rexe
    if (!($OfficeUpdatePath)) {
      throw "Cannot find OfficeC2RClient.exe file"
    }
    
    $Version = Get-LatestVersion -UpdateURLPath $UpdateURLPath

    $arguments = "/update user displaylevel=false updatepromptuser=false updatetoversion=$Version"
       
    #run update exe file
    Start-Process -FilePath $OfficeUpdatePath -ArgumentList $arguments
     
    Wait-ForOfficeCTRUpadate

    if ($oldUpdatePath) {
       New-ItemProperty $Office2RClientKey -Name UpdateUrl -PropertyType String -Value $oldUpdatePath -Force | Out-Null
    }

    $object = New-Object PSObject -Property @{OldUpdatePath = $OldUpdatePath; NewUpdatePath = $UpdateURLPath; Version = $Version }
    $object | Add-Member MemberSet PSStandardMembers $PSStandardMembers
    $results += $object
    
    $results | fl 
  }

}

Function Get-ScriptPath() {
  [CmdletBinding()]
  param(

  )

  process {
    #get local path
    $scriptPath = "."

    if ($PSScriptRoot) {
        $scriptPath = $PSScriptRoot
    } else {
        $scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
    }
    retur
  }
}

Function Get-OfficeC2Rexe() {
    [CmdletBinding()]
    Param(

    )
    process {
        $Office2RClientKey = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' #ClientFolder

        #find update exe file
        $OfficeUpdatePath = Get-ItemProperty -Path $Office2RClientKey | Select-Object -Property ClientFolder
        $temp = Out-String -InputObject $OfficeUpdatePath
        $temp = $temp.Substring($temp.LastIndexOf('-')+2)
        $temp = $temp.Trim()
        $OfficeUpdatePath = $temp
        $OfficeUpdatePath+= '\OfficeC2RClient.exe'
        return $OfficeUpdatePath
    }
}

Function Wait-ForOfficeCTRUpadate() {
    [CmdletBinding()]
    Param(
        [Parameter()]
        [int] $TimeOutInMinutes = 120
    )

    begin {
        $HKLM = [UInt32] "0x80000002"
        $HKCR = [UInt32] "0x80000000"
    }

    process {
       Write-Host "Waiting for Update process to Complete..."

       [datetime]$operationStart = Get-Date
       [datetime]$totalOperationStart = Get-Date

       Start-Sleep -Seconds 10

       $mainRegPath = Get-OfficeCTRRegPath
       $scenarioPath = $mainRegPath + "\scenario"

       $regProv = Get-Wmiobject -list "StdRegProv" -namespace root\default -ErrorAction Stop

       [DateTime]$startTime = Get-Date

       [string]$executingScenario = ""
       $failure = $false
       $cancelled = $false
       $updateRunning=$false
       [string[]]$trackProgress = @()
       [string[]]$trackComplete = @()
       [int]$noScenarioCount = 0

       do {
           $allComplete = $true
           $executingScenario = $regProv.GetStringValue($HKLM, $mainRegPath, "ExecutingScenario").sValue
           
           $scenarioKeys = $regProv.EnumKey($HKLM, $scenarioPath)
           foreach ($scenarioKey in $scenarioKeys.sNames) {
              if (!($executingScenario)) { continue }
              if ($scenarioKey.ToLower() -eq $executingScenario.ToLower()) {
                $taskKeyPath = Join-Path $scenarioPath "$scenarioKey\TasksState"
                $taskValues = $regProv.EnumValues($HKLM, $taskKeyPath).sNames

                foreach ($taskValue in $taskValues) {
                    [string]$status = $regProv.GetStringValue($HKLM, $taskKeyPath, $taskValue).sValue
                    $operation = $taskValue.Split(':')[0]
                    $keyValue = $taskValue
                   
                    if ($status.ToUpper() -eq "TASKSTATE_FAILED") {
                        $failure = $true
                    }

                    if ($status.ToUpper() -eq "TASKSTATE_CANCELLED") {
                        $cancelled = $true
                    }

                    if (($status.ToUpper() -eq "TASKSTATE_COMPLETED") -or`
                        ($status.ToUpper() -eq "TASKSTATE_CANCELLED") -or`
                        ($status.ToUpper() -eq "TASKSTATE_FAILED")) {
                        if (($trackProgress -contains $keyValue) -and !($trackComplete -contains $keyValue)) {
                            $displayValue = $operation + "`t" + $status + "`t" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                            #Write-Host $displayValue
                            $trackComplete += $keyValue 

                            $statusName = $status.Split('_')[1];

                            if (($operation.ToUpper().IndexOf("DOWNLOAD") -gt -1) -or `
                                ($operation.ToUpper().IndexOf("APPLY") -gt -1)) {

                                $operationTime = getOperationTime -OperationStart $operationStart

                                $displayText = $statusName + "`t" + $operationTime

                                Write-Host $displayText
                            }
                        }
                    } else {
                        $allComplete = $false
                        $updateRunning=$true


                        if (!($trackProgress -contains $keyValue)) {
                             $trackProgress += $keyValue 
                             $displayValue = $operation + "`t" + $status + "`t" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

                             $operationStart = Get-Date

                             if ($operation.ToUpper().IndexOf("DOWNLOAD") -gt -1) {
                                Write-Host "Downloading Update: " -NoNewline
                             }

                             if ($operation.ToUpper().IndexOf("APPLY") -gt -1) {
                                Write-Host "Applying Update: " -NoNewline
                             }

                             if ($operation.ToUpper().IndexOf("FINALIZE") -gt -1) {
                                Write-Host "Finalizing Update: " -NoNewline
                             }

                             #Write-Host $displayValue
                        }
                    }
                }
              }
           }

           if ($allComplete) {
              break;
           }

           if ($startTime -lt (Get-Date).AddHours(-$TimeOutInMinutes)) {
              throw "Waiting for Update Timed-Out"
              break;
           }

           Start-Sleep -Seconds 5
       } while($true -eq $true) 

       $operationTime = getOperationTime -OperationStart $operationStart

       $displayValue = ""
       if ($cancelled) {
         $displayValue = "CANCELLED`t" + $operationTime
       } else {
         if ($failure) {
            $displayValue = "FAILED`t" + $operationTime
         } else {
            $displayValue = "COMPLETED`t" + $operationTime
         }
       }

       Write-Host $displayValue

       $totalOperationTime = getOperationTime -OperationStart $totalOperationStart

       if ($updateRunning) {
          if ($failure) {
            Write-Host "Update Failed"
          } else {
            Write-Host "Update Completed - Total Time: $totalOperationTime"
          }
       } else {
          Write-Host "Update Not Running"
       } 
    }
}

Function Get-OfficeCTRRegPath() {
    $path15 = 'SOFTWARE\Microsoft\Office\15.0\ClickToRun'
    $path16 = 'SOFTWARE\Microsoft\Office\ClickToRun'
    if (Test-Path "HKLM:\$path16") {
        return $path16
    }
    else {
        if (Test-Path "HKLM:\$path15") {
            return $path15
        }
    }
}

Function getOperationTime() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [DateTime] $OperationStart
    )

    $operationTime = ""

    $dateDiff = NEW-TIMESPAN –Start $OperationStart –End (GET-DATE)
    $strHours = formatTimeItem -TimeItem $dateDiff.Hours.ToString() 
    $strMinutes = formatTimeItem -TimeItem $dateDiff.Minutes.ToString() 
    $strSeconds = formatTimeItem -TimeItem $dateDiff.Seconds.ToString() 

    if ($dateDiff.Days -gt 0) {
        $operationTime += "Days: " + $dateDiff.Days.ToString() + ":"  + $strHours + ":" + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Hours -gt 0 -and $dateDiff.Days -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Hours: " + $strHours + ":" + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Minutes -gt 0 -and $dateDiff.Days -eq 0 -and $dateDiff.Hours -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Minutes: " + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Seconds -gt 0 -and $dateDiff.Days -eq 0 -and $dateDiff.Hours -eq 0 -and $dateDiff.Minutes -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Seconds: " + $strSeconds
    }

    return $operationTime
}

Function formatTimeItem() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $TimeItem = ""
    )

    [string]$returnItem = $TimeItem
    if ($TimeItem.Length -eq 1) {
       $returnItem = "0" + $TimeItem
    }
    return $returnItem
}

Function Test-UpdateSource() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $UpdateSource = $NULL
    )

  	$uri = [System.Uri]$UpdateSource

    [bool]$sourceIsAlive = $false

    if($uri.Host){
	    $sourceIsAlive = Test-Connection -Count 1 -computername $uri.Host -Quiet
    }else{
        $sourceIsAlive = Test-Path $uri.LocalPath -ErrorAction SilentlyContinue
    }

    if ($sourceIsAlive) {
        $sourceIsAlive = Validate-UpdateSource -UpdateSource $UpdateSource
    }

    return $sourceIsAlive
}

Function Validate-UpdateSource() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $UpdateSource = $NULL
    )

    Process {
    [bool]$validUpdateSource = $false
    [string]$cabPath = ""

    if ($UpdateSource) {
        $mainRegPath = Get-OfficeCTRRegPath
        $configRegPath = $mainRegPath + "\Configuration"
        $currentplatform = (Get-ItemProperty HKLM:\$configRegPath -Name Platform -ErrorAction SilentlyContinue).Platform
        $updateToVersion = (Get-ItemProperty HKLM:\$configRegPath -Name UpdateToVersion -ErrorAction SilentlyContinue).UpdateToVersion

        if ($updateToVersion) {
            if ($currentplatform.ToLower() -eq "x86") {
               $cabPath = $UpdateSource + "\Office\Data\v32_" + $updateToVersion + ".cab"
            }
            if ($currentplatform.ToLower() -eq "x64") {
               $cabPath = $UpdateSource + "\Office\Data\v64_" + $updateToVersion + ".cab"
            }
        } else {
            if ($currentplatform.ToLower() -eq "x86") {
               $cabPath = $UpdateSource + "\Office\Data\v32.cab"
            }
            if ($currentplatform.ToLower() -eq "x64") {
               $cabPath = $UpdateSource + "\Office\Data\v64.cab"
            }
        }

        if ($cabPath.ToLower().StartsWith("http")) {
           $cabPath = $cabPath.Replace("\", "/")
           $validUpdateSource = Test-URL -url $cabPath
        } else {
           $validUpdateSource = Test-Path -Path $cabPath
        }
        
        if (!$validUpdateSource) {
           throw "Invalid UpdateSource. File Not Found: $cabPath"
        }
    }

    return $validUpdateSource
    }
}

Function Get-LatestVersion() {
  [CmdletBinding()]
  Param(
     [Parameter(Mandatory=$true)]
     [string] $UpdateURLPath
  )

  process {
    [array]$totalVersion = @()
    $Version = $null

    $LatestBranchVersionPath = $UpdateURLPath + '\Office\Data'
    if(Test-Path $LatestBranchVersionPath){
        $DirectoryList = Get-ChildItem $LatestBranchVersionPath
        Foreach($listItem in $DirectoryList){
            if($listItem.GetType().Name -eq 'DirectoryInfo'){
                $totalVersion+=$listItem.Name
            }
        }
    }

    $totalVersion = $totalVersion | Sort-Object
    
    #sets version number to the newest version in directory for channel if version is not set by user in argument  
    if($totalVersion.Count -gt 0){
        $Version = $totalVersion[0]
    }

    return $Version
  }
}

function Change-UpdatePathToChannel {
   [CmdletBinding()]
   param( 
     [Parameter()]
     [string] $UpdatePath,
     
     [Parameter()]
     [Channel] $Channel
   )

   $newUpdatePath = $UpdatePath

   $branchShortName = "DC"
   if ($Channel.ToString().ToLower() -eq "current") {
      $branchShortName = "CC"
   }
   if ($Channel.ToString().ToLower() -eq "firstreleasecurrent") {
      $branchShortName = "FRCC"
   }
   if ($Channel.ToString().ToLower() -eq "firstreleasedeferred") {
      $branchShortName = "FRDC"
   }
   if ($Channel.ToString().ToLower() -eq "deferred") {
      $branchShortName = "DC"
   }

   $channelNames = @("FRCC", "CC", "FRDC", "DC")

   $madeChange = $false
   foreach ($channelName in $channelNames) {
      if ($UpdatePath.ToUpper().EndsWith("\$channelName")) {
         $newUpdatePath = $newUpdatePath -replace "\\$channelName", "\$branchShortName"
         $madeChange = $true
      } 
      if ($UpdatePath.ToUpper().Contains("\$channelName\")) {
         $newUpdatePath = $newUpdatePath -replace "\\$channelName\\", "\$branchShortName\"
         $madeChange = $true
      } 
      if ($UpdatePath.ToUpper().EndsWith("/$channelName")) {
         $newUpdatePath = $newUpdatePath -replace "\/$channelName", "/$branchShortName"
         $madeChange = $true
      }
      if ($UpdatePath.ToUpper().Contains("/$channelName/")) {
         $newUpdatePath = $newUpdatePath -replace "\/$channelName\/", "/$branchShortName/"
         $madeChange = $true
      }
   }

   if (!($madeChange)) {
      if ($newUpdatePath.Contains("/")) {
         if ($newUpdatePath.EndsWith("/")) {
           $newUpdatePath += "$branchShortName"
         } else {
           $newUpdatePath += "/$branchShortName"
         }
      }
      if ($newUpdatePath.Contains("\")) {
         if ($newUpdatePath.EndsWith("\")) {
           $newUpdatePath += "$branchShortName"
         } else {
           $newUpdatePath += "\$branchShortName"
         }
      }
   }

   try {
     $pathAlive = Test-UpdateSource -UpdateSource $newUpdatePath
   } catch {
     $pathAlive = $false
   }
   
   if ($pathAlive) {
     return $newUpdatePath
   } else {
     return $UpdatePath
   }
}

function Detect-Channel() {
   [CmdletBinding()]
   param( 
      
   )

   Process {
      $currentBaseUrl = Get-OfficeCDNUrl
      $channelXml = Get-ChannelXml

      $currentChannel = $channelXml.UpdateFiles.baseURL | Where {$_.URL -eq $currentBaseUrl -and $_.branch -notcontains 'Business' }
      return $currentChannel
   }

}

function Get-ChannelUrl() {
   [CmdletBinding()]
   param( 
      [Parameter(Mandatory=$true)]
      [Channel]$Channel
   )

   Process {
      $channelXml = Get-ChannelXml

      $currentChannel = $channelXml.UpdateFiles.baseURL | Where {$_.branch -eq $Channel.ToString() }
      return $currentChannel
   }

}

function Get-ChannelXml() {
   [CmdletBinding()]
   param( 
      
   )

   process {
       $cabPath = "$PSScriptRoot\ofl.cab"

       if (!(Test-Path -Path $cabPath)) {
           $webclient = New-Object System.Net.WebClient
           $XMLFilePath = "$env:TEMP/ofl.cab"
           $XMLDownloadURL = "http://officecdn.microsoft.com/pr/wsus/ofl.cab"
           $webclient.DownloadFile($XMLDownloadURL,$XMLFilePath)
       }

       $tmpName = "o365client_64bit.xml"
       expand $XMLFilePath $env:TEMP -f:$tmpName | Out-Null
       $tmpName = $env:TEMP + "\o365client_64bit.xml"
       [xml]$channelXml = Get-Content $tmpName

       return $channelXml
   }

}

Function Set-OfficeCDNUrl() {
   [CmdletBinding()]
   param( 
      [Parameter(Mandatory=$true)]
      [Channel]$Channel
   )

   Process {
        $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
        if (!($CDNBaseUrl)) {
           $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
        }

        $path15 = 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\Configuration'
        $path16 = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
        $regPath = $path16

        if (Test-Path -Path $path16) { $regPath = $path16 }
        if (Test-Path -Path $path15) { $regPath = $path15 }

        $ChannelUrl = Get-ChannelUrl -Channel $Channel
           
        New-ItemProperty $regPath -Name CDNBaseUrl -PropertyType String -Value $ChannelUrl.URL -Force | Out-Null
   }
}

Function Get-OfficeCDNUrl() {
    $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
    if (!($CDNBaseUrl)) {
       $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
    }
    if (!($CDNBaseUrl)) {
        Push-Location
        $path15 = 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\ProductReleaseIDs\Active\stream'
        $path16 = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs\Active\stream'
        if (Test-Path -Path $path16) { Set-Location $path16 }
        if (Test-Path -Path $path15) { Set-Location $path15 }

        $items = Get-Item . | Select-Object -ExpandProperty property
        $properties = $items | ForEach-Object {
           New-Object psobject -Property @{"property"=$_; "Value" = (Get-ItemProperty -Path . -Name $_).$_}
        }

        $value = $properties | Select Value
        $firstItem = $value[0]
        [string] $cdnPath = $firstItem.Value

        $CDNBaseUrl = Select-String -InputObject $cdnPath -Pattern "http://officecdn.microsoft.com/.*/.{8}-.{4}-.{4}-.{4}-.{12}" -AllMatches | % { $_.Matches } | % { $_.Value }
        Pop-Location
    }
    return $CDNBaseUrl
}