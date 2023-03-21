Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "Specifies the parent telemetry scope for the telemetry signal", Mandatory = $false)]
    [string] $parentTelemetryScopeJson = '7b7d',
    [Parameter(HelpMessage = "Projects to deploy", Mandatory = $false)]
    [string] $projects = '',
    [Parameter(HelpMessage = "Type of target of deployment (LocalContainer or OnPrem BC Service)", Mandatory = $true)]
    [ValidateSet('LocalContainer', 'OnPrem')]
    [string] $deploymentType,
    [Parameter(HelpMessage = "Name of environment to deploy to", Mandatory = $true)]
    [string] $environmentName,
    [Parameter(HelpMessage = "Tenant to deploy to", Mandatory = $false)]
    [string] $tenant = 'default',
    [Parameter(HelpMessage = "Artifacts to deploy", Mandatory = $true)]
    [string] $artifacts,
    [Parameter(HelpMessage = "Type of deployment (CD or Publish)", Mandatory = $false)]
    [ValidateSet('CD', 'Publish')]
    [string] $type = "CD",
    [Parameter(HelpMessage = "Sync mode of deployment", Mandatory = $false)]
    [ValidateSet('Add', 'Clean', 'Development', 'ForceSync')]
    [string] $syncMode = "Add"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$telemetryScope = $null
$bcContainerHelperPath = $null

# IMPORTANT: No code that can fail should be outside the try/catch

try {
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
    $BcContainerHelperPath = DownloadAndImportBcContainerHelper -baseFolder $ENV:GITHUB_WORKSPACE -bcContainerHelperVersion "preview"

    # import-module (Join-Path -path $PSScriptRoot -ChildPath "..\TelemetryHelper.psm1" -Resolve)
    # $telemetryScope = CreateScope -eventId 'DO0075' -parentTelemetryScopeJson $parentTelemetryScopeJson

    $artifacts = $artifacts.Replace('/', ([System.IO.Path]::DirectorySeparatorChar)).Replace('\', ([System.IO.Path]::DirectorySeparatorChar))

    $apps = @()
    $baseFolder = Join-Path $ENV:GITHUB_WORKSPACE ".artifacts"
    $baseFolderCreated = $false
    if ($artifacts -eq ".artifacts") {
        $artifacts = $baseFolder
    }

    if ($artifacts -like "$($ENV:GITHUB_WORKSPACE)*") {
        if (Test-Path $artifacts -PathType Container) {
            $projects.Split(',') | ForEach-Object {
                $project = $_.Replace('\', '_')
                $refname = "$ENV:GITHUB_REF_NAME".Replace('/', '_')
                Write-Host "project '$project'"
                $apps += @((Get-ChildItem -Path $artifacts -Filter "$project-$refname-Apps-*.*.*.*") | ForEach-Object { $_.FullName })
                if (!($apps)) {
                    throw "There is no artifacts present in $artifacts matching $project-$refname-Apps-<version>."
                }
                $apps += @((Get-ChildItem -Path $artifacts -Filter "$project-$refname-Dependencies-*.*.*.*") | ForEach-Object { $_.FullName })
            }
        }
        elseif (Test-Path $artifacts) {
            $apps = $artifacts
        }
        else {
            throw "Artifact $artifacts was not found. Make sure that the artifact files exist and files are not corrupted."
        }
    }
    elseif ($artifacts -eq "current" -or $artifacts -eq "prerelease" -or $artifacts -eq "draft") {
        # latest released version
        $releases = GetReleases -token $token -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY
        if ($artifacts -eq "current") {
            $release = $releases | Where-Object { -not ($_.prerelease -or $_.draft) } | Select-Object -First 1
        }
        elseif ($artifacts -eq "prerelease") {
            $release = $releases | Where-Object { -not ($_.draft) } | Select-Object -First 1
        }
        elseif ($artifacts -eq "draft") {
            $release = $releases | Select-Object -First 1
        }
        if (!($release)) {
            throw "Unable to locate $artifacts release"
        }
        New-Item $baseFolder -ItemType Directory | Out-Null
        $baseFolderCreated = $true
        DownloadRelease -token $token -projects $projects -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY -release $release -path $baseFolder -mask "Apps"
        DownloadRelease -token $token -projects $projects -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY -release $release -path $baseFolder -mask "Dependencies"
        $apps = @((Get-ChildItem -Path $baseFolder) | ForEach-Object { $_.FullName })
        if (!$apps) {
            throw "Artifact $artifacts was not found on any release. Make sure that the artifact files exist and files are not corrupted."
        }
    }
    else {
        New-Item $baseFolder -ItemType Directory | Out-Null
        $baseFolderCreated = $true
        $allArtifacts = @(GetArtifacts -token $token -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY -mask "Apps" -projects $projects -Version $artifacts -branch "main")
        $allArtifacts += @(GetArtifacts -token $token -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY -mask "Dependencies" -projects $projects -Version $artifacts -branch "main")
        if ($allArtifacts) {
            $allArtifacts | ForEach-Object {
                $appFile = DownloadArtifact -token $token -artifact $_ -path $baseFolder
                if (!(Test-Path $appFile)) {
                    throw "Unable to download artifact $($_.name)"
                }
                $apps += @($appFile)
            }
        }
        else {
            throw "Could not find any Apps artifacts for projects $projects, version $artifacts"
        }
    }

    $packageType = 'Extension'
    $scope = 'Global'
    $force = $true
    $ignoreIfAppExists = $true
    $SkipVerification = $true
    $language = 'es-ES'

    Write-Host "Apps to deploy"
    $apps | Out-Host

    Set-Location $ENV:GITHUB_WORKSPACE

    $envName = $environmentName.Split(' ')[0]

    $appFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    #$appFiles = CopyAppFilesToFolder -appFiles $apps -folder $appFolder
    $appFiles = @()
    Write-Host "Expanding into $appFolder"
    Expand-Archive "$apps" -DestinationPath $appFolder -Force
    Get-ChildItem -Path $appFolder -Recurse | Where-Object { $_.Name -like "*.app" } | % {
        $appFiles += $_.FullName
    }

    try {
        if ($deploymentType -eq 'LocalContainer') {
            Write-Host "Publishing apps to container $environmentName"

            Publish-BcContainerApp -containerName $envName -appFile $apps -skipVerification -sync -install -syncMode $syncMode -upgrade -checkAlreadyInstalled
        }
        elseif ($deploymentType -eq 'OnPrem') {
    
            Write-Host "Publishing apps to OnPrem BC Service $environmentName"
            $serverInstance = $environmentName

            $BCServerPath = (Get-Process -Id (Get-WmiObject -Class Win32_Service | Where-Object { $_.Name -eq "MicrosoftDynamicsNavServer`$$serverInstance" } | Select-Object ProcessId).ProcessId).Path
            if ($BCServerPath -match '\\(\d+)\\') {
                $bcversion = $matches[1]
                Write-Host "Business Central version: $bcversion"
            }
            else {
                Throw "Business Central version not found"
            }

            Import-Module "C:\Program Files\Microsoft Dynamics 365 Business Central\$bcversion\Service\NavAdminTool.ps1"

            # Ordenar apps por dependencias
            #$appFiles = @(Sort-AppFilesByDependencies -appFiles $appFiles -includeOnlyAppIds $includeOnlyAppIds -excludeInstalledApps $installedApps -WarningAction SilentlyContinue)
            $appFiles = @(Sort-AppFilesByDependencies -appFiles $appFiles -WarningAction SilentlyContinue)
            $appFiles | Where-Object { $_ } | ForEach-Object {
                # Por cada app, publicar, sincronizar e instalar/upgrade
                $appFile = $_

                $sync = $true
                $install = $true
                $upgrade = $true
                $unPublishOldVersion = $true
                
                $publishArgs = @{ "packageType" = $packageType }
                if ($scope) {
                    $publishArgs += @{ "Scope" = $scope }
                    if ($scope -eq "Tenant") {
                        $publishArgs += @{ "Tenant" = $tenant }
                    }
                }

                if ($force) {
                    $publishArgs += @{ "Force" = $true }
                }
            
                $publishIt = $true
                if ($ignoreIfAppExists) {
                    $navAppInfo = Get-NAVAppInfo -Path $appFile
                    $addArg = @{
                        "tenantSpecificProperties" = $true
                        "tenant"                   = $tenant
                    }
                    if ($packageType -eq "SymbolsOnly") {
                        $addArg = @{ "SymbolsOnly" = $true }
                    }
                    $appInfo = (Get-NAVAppInfo -ServerInstance $serverInstance -Name $navAppInfo.Name -Publisher $navAppInfo.Publisher -Version $navAppInfo.Version @addArg)
                    if ($appInfo) {
                        $publishIt = $false
                        Write-Host "$($navAppInfo.Name) is already published"
                        if ($appInfo.IsInstalled) {
                            $install = $false
                            $upgrade = $false
                            $unPublishOldVersion = $false
                            Write-Host "$($navAppInfo.Name) is already installed"
                        }
                    }
                }
                
                if ($publishIt) {
                    Write-Host "Publishing $appFile"
                    Publish-NavApp -ServerInstance $ServerInstance -Path $appFile -SkipVerification:$SkipVerification @publishArgs
                }
        
                if ($sync -or $install -or $upgrade) {
        
                    $navAppInfo = Get-NAVAppInfo -Path $appFile
                    $appPublisher = $navAppInfo.Publisher
                    $appName = $navAppInfo.Name
                    $appVersion = $navAppInfo.Version
        
                    $syncArgs = @{}
                    if ($syncMode) {
                        $syncArgs += @{ "Mode" = $syncMode }
                    }
        
                    if ($sync) {
                        Write-Host "Synchronizing $appName on tenant $tenant"
                        Sync-NavTenant -ServerInstance $ServerInstance -Tenant $tenant -Force
                        Sync-NavApp -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant @syncArgs -force -WarningAction Ignore
                    }
        
                    if ($upgrade -and $install) {
                        $navAppInfoFromDb = Get-NAVAppInfo -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant -TenantSpecificProperties
                        if ($null -eq $navAppInfoFromDb.ExtensionDataVersion -or $navAppInfoFromDb.ExtensionDataVersion -eq $navAppInfoFromDb.Version) {
                            $upgrade = $false
                            $unPublishOldVersion = $false
                        }
                        else {
                            $install = $false
                            if ($unPublishOldVersion) {
                                $oldAppVersion = $navAppInfoFromDb.ExtensionDataVersion
                            }
                        }
                    }
                
                    if ($install) {
        
                        $languageArgs = @{}
                        if ($language) {
                            $languageArgs += @{ "Language" = $language }
                        }
                        Write-Host "Installing $appName on tenant $tenant"
                        Install-NavApp -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant @languageArgs
                    }
        
                    if ($upgrade) {
        
                        $languageArgs = @{}
                        if ($language) {
                            $languageArgs += @{ "Language" = $language }
                        }
                        Write-Host "Upgrading $appName on tenant $tenant"
                        Start-NavAppDataUpgrade -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant @languageArgs
                    }

                    if ($unPublishOldVersion) {
                        Write-Host "UnPublish old version $oldAppVersion of $appName on tenant $tenant"
                        UnPublish-NavApp -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -version $oldAppVersion
                    }
                }
            }
        }
    }
    catch {
        OutputError -message "Deploying to $environmentName failed.$([environment]::Newline) $($_.Exception.Message)"
        exit
    }

    if ($baseFolderCreated) {
        Remove-Item $baseFolder -Recurse -Force
    }

    TrackTrace -telemetryScope $telemetryScope

}
catch {
    OutputError -message "Deploy action failed.$([environment]::Newline)Error: $($_.Exception.Message)$([environment]::Newline)Stacktrace: $($_.scriptStackTrace)"
    TrackException -telemetryScope $telemetryScope -errorRecord $_
}
finally {
    CleanupAfterBcContainerHelper -bcContainerHelperPath $bcContainerHelperPath
}
