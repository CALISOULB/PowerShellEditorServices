# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$PsesSubmodulePath = "$PSScriptRoot/module",

    [string]$ModulesJsonPath = "$PSScriptRoot/modules.json",

    [string]$DefaultModuleRepository = "PSGallery",

    # See: https://docs.microsoft.com/en-us/dotnet/core/testing/selective-unit-tests
    [string]$TestFilter = '',

    # See: https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-test
    # E.g. use @("--logger", "console;verbosity=detailed") for detailed console output instead
    [string[]]$TestArgs = @("--logger", "trx")
)

#Requires -Modules @{ModuleName="InvokeBuild";ModuleVersion="3.2.1"}

$script:dotnetTestArgs = @(
    "test"
    $TestArgs
    if ($TestFilter) { "--filter", $TestFilter }
    "--framework"
)

$script:IsNix = $IsLinux -or $IsMacOS
# For Apple M1, pwsh might be getting emulated, in which case we need to check
# for the proc_translated flag, otherwise we can check the architecture.
$script:IsAppleM1 = $IsMacOS -and ((sysctl -n sysctl.proc_translated) -eq 1 -or (uname -m) -eq "arm64")
$script:BuildInfoPath = [System.IO.Path]::Combine($PSScriptRoot, "src", "PowerShellEditorServices.Hosting", "BuildInfo.cs")
$script:PsesCommonProps = [xml](Get-Content -Raw "$PSScriptRoot/PowerShellEditorServices.Common.props")

$script:NetRuntime = @{
    PS7 = 'netcoreapp3.1'
    PS72 = 'net6.0'
    Desktop = 'net461'
    Standard = 'netstandard2.0'
}

$script:HostCoreOutput = "$PSScriptRoot/src/PowerShellEditorServices.Hosting/bin/$Configuration/$($script:NetRuntime.PS7)/publish"
$script:HostDeskOutput = "$PSScriptRoot/src/PowerShellEditorServices.Hosting/bin/$Configuration/$($script:NetRuntime.Desktop)/publish"
$script:PsesOutput = "$PSScriptRoot/src/PowerShellEditorServices/bin/$Configuration/$($script:NetRuntime.Standard)/publish"
$script:VSCodeOutput = "$PSScriptRoot/src/PowerShellEditorServices.VSCode/bin/$Configuration/$($script:NetRuntime.Standard)/publish"

if (Get-Command git -ErrorAction SilentlyContinue) {
    # ignore changes to this file
    git update-index --assume-unchanged "$PSScriptRoot/src/PowerShellEditorServices.Hosting/BuildInfo.cs"
}

function Install-Dotnet {
    param (
        [string[]]$Channel,
        [switch]$Runtime
    )

    $env:DOTNET_INSTALL_DIR = "$PSScriptRoot/.dotnet"

    $components = if ($Runtime) { "Runtime " } else { "SDK and Runtime " }
    $components += $Channel -join ', '

    Write-Host "Installing .NET $components" -ForegroundColor Green

    # The install script is platform-specific
    $installScriptExt = if ($script:IsNix) { "sh" } else { "ps1" }
    $installScript = "dotnet-install.$installScriptExt"

    # Download the official installation script and run it
    $installScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) $installScript
    Invoke-WebRequest "https://dot.net/v1/$installScript" -OutFile $installScriptPath

    # Download and install the different .NET channels
    foreach ($dotnetChannel in $Channel)
    {
        if ($script:IsNix) {
            chmod +x $installScriptPath
        }

        $params = if ($script:IsNix) {
            @('-Channel', $dotnetChannel, '-InstallDir', $env:DOTNET_INSTALL_DIR, '-NoPath', '-Verbose')
        } else {
            @{
                Channel = $dotnetChannel
                InstallDir = $env:DOTNET_INSTALL_DIR
                NoPath = $true
                Verbose = $true
            }
        }

        # Install just the runtime, not the SDK
        if ($Runtime) {
            if ($script:IsNix) { $params += @('-Runtime', 'dotnet') }
            else { $params['Runtime'] = 'dotnet' }
        }

        exec { & $installScriptPath @params }
    }

    $env:PATH = $env:DOTNET_INSTALL_DIR + [System.IO.Path]::PathSeparator + $env:PATH

    Write-Host '.NET installation complete' -ForegroundColor Green
}

task SetupDotNet -Before Clean, Build, TestServerWinPS, TestServerPS7, TestServerPS72, TestE2E {

    $dotnetPath = "$PSScriptRoot/.dotnet"
    $dotnetExePath = if ($script:IsNix) { "$dotnetPath/dotnet" } else { "$dotnetPath/dotnet.exe" }

    if (!(Test-Path $dotnetExePath)) {
        # TODO: Test .NET 5 with PowerShell 7.1
        #
        # We use the .NET 6 SDK, so we always install it and its runtime.
        Install-Dotnet -Channel '6.0' # SDK and runtime
        # Anywhere other than on a Mac with an M1 processor, we additionally
        # install the .NET 3.1 and 5.0 runtimes (but not their SDKs).
        if (!$script:IsAppleM1) { Install-Dotnet -Channel '3.1','5.0' -Runtime }
    }

    # This variable is used internally by 'dotnet' to know where it's installed
    $script:dotnetExe = Resolve-Path $dotnetExePath
    if (!$env:DOTNET_INSTALL_DIR)
    {
        $dotnetExeDir = [System.IO.Path]::GetDirectoryName($script:dotnetExe)
        $env:PATH = $dotnetExeDir + [System.IO.Path]::PathSeparator + $env:PATH
        $env:DOTNET_INSTALL_DIR = $dotnetExeDir
    }

    Write-Host "`n### Using dotnet v$(& $script:dotnetExe --version) at path $script:dotnetExe`n" -ForegroundColor Green
}

task BinClean {
    Remove-Item $PSScriptRoot\.tmp -Recurse -Force -ErrorAction Ignore
    Remove-Item $PSScriptRoot\module\PowerShellEditorServices\bin -Recurse -Force -ErrorAction Ignore
    Remove-Item $PSScriptRoot\module\PowerShellEditorServices.VSCode\bin -Recurse -Force -ErrorAction Ignore
}

task Clean BinClean,{
    exec { & $script:dotnetExe restore }
    exec { & $script:dotnetExe clean }
    Get-ChildItem -Recurse $PSScriptRoot\src\*.nupkg | Remove-Item -Force -ErrorAction Ignore
    Get-ChildItem $PSScriptRoot\PowerShellEditorServices*.zip | Remove-Item -Force -ErrorAction Ignore
    Get-ChildItem $PSScriptRoot\module\PowerShellEditorServices\Commands\en-US\*-help.xml | Remove-Item -Force -ErrorAction Ignore

    # Remove bundled component modules
    $moduleJsonPath = "$PSScriptRoot\modules.json"
    if (Test-Path $moduleJsonPath) {
        Get-Content -Raw $moduleJsonPath |
            ConvertFrom-Json |
            ForEach-Object { $_.PSObject.Properties.Name } |
            ForEach-Object { Remove-Item -Path "$PSScriptRoot/module/$_" -Recurse -Force -ErrorAction Ignore }
    }
}

task CreateBuildInfo -Before Build {
    $buildVersion = "<development-build>"
    $buildOrigin = "Development"
    $buildCommit = git rev-parse HEAD

    # Set build info fields on build platforms
    if ($env:TF_BUILD) {
        if ($env:BUILD_BUILDNUMBER -like "PR-*") {
            $buildOrigin = "PR"
        } elseif ($env:BUILD_DEFINITIONNAME -like "*-CI") {
            $buildOrigin = "CI"
        } else {
            $buildOrigin = "Release"
        }

        $propsXml = [xml](Get-Content -Raw -LiteralPath "$PSScriptRoot/PowerShellEditorServices.Common.props")
        $propsBody = $propsXml.Project.PropertyGroup
        $buildVersion = $propsBody.VersionPrefix

        if ($propsBody.VersionSuffix)
        {
            $buildVersion += '-' + $propsBody.VersionSuffix
        }
    }

    # Allow override of build info fields (except date)
    if ($env:PSES_BUILD_VERSION) {
        $buildVersion = $env:PSES_BUILD_VERSION
    }

    if ($env:PSES_BUILD_ORIGIN) {
        $buildOrigin = $env:PSES_BUILD_ORIGIN
    }

    [string]$buildTime = [datetime]::Now.ToString("s", [System.Globalization.CultureInfo]::InvariantCulture)

    $buildInfoContents = @"
using System.Globalization;

namespace Microsoft.PowerShell.EditorServices.Hosting
{
    public static class BuildInfo
    {
        public static readonly string BuildVersion = "$buildVersion";
        public static readonly string BuildOrigin = "$buildOrigin";
        public static readonly string BuildCommit = "$buildCommit";
        public static readonly System.DateTime? BuildTime = System.DateTime.Parse("$buildTime", CultureInfo.InvariantCulture.DateTimeFormat);
    }
}
"@

    Set-Content -LiteralPath $script:BuildInfoPath -Value $buildInfoContents -Force
}

task SetupHelpForTests {
    if (-not (Get-Help Write-Host).Examples) {
        Write-Host "Updating help for tests"
        Update-Help -Module Microsoft.PowerShell.Utility -Force -Scope CurrentUser
    }
    else
    {
        Write-Host "Write-Host help found -- Update-Help skipped"
    }
}

Task Build {
    exec { & $script:dotnetExe publish -c $Configuration .\src\PowerShellEditorServices\PowerShellEditorServices.csproj -f $script:NetRuntime.Standard }
    exec { & $script:dotnetExe publish -c $Configuration .\src\PowerShellEditorServices.Hosting\PowerShellEditorServices.Hosting.csproj -f $script:NetRuntime.PS7 }
    if (-not $script:IsNix)
    {
        exec { & $script:dotnetExe publish -c $Configuration .\src\PowerShellEditorServices.Hosting\PowerShellEditorServices.Hosting.csproj -f $script:NetRuntime.Desktop }
    }

    # Build PowerShellEditorServices.VSCode module
    exec { & $script:dotnetExe publish -c $Configuration .\src\PowerShellEditorServices.VSCode\PowerShellEditorServices.VSCode.csproj -f $script:NetRuntime.Standard }
}

task Test SetupHelpForTests,TestServer,TestE2E

task TestServer TestServerWinPS,TestServerPS7,TestServerPS72

task TestServerWinPS -If (-not $script:IsNix) {
    Set-Location .\test\PowerShellEditorServices.Test\
    exec { & $script:dotnetExe $script:dotnetTestArgs $script:NetRuntime.Desktop }
}

task TestServerPS7 -If (-not $script:IsAppleM1) {
    Set-Location .\test\PowerShellEditorServices.Test\
    exec { & $script:dotnetExe $script:dotnetTestArgs $script:NetRuntime.PS7 }
}

task TestServerPS72 {
    Set-Location .\test\PowerShellEditorServices.Test\
    exec { & $script:dotnetExe $script:dotnetTestArgs $script:NetRuntime.PS72 }
}

task TestE2E {
    Set-Location .\test\PowerShellEditorServices.Test.E2E\

    $env:PWSH_EXE_NAME = if ($IsCoreCLR) { "pwsh" } else { "powershell" }
    $NetRuntime = if ($IsAppleM1) { $script:NetRuntime.PS72 } else { $script:NetRuntime.PS7 }
    exec { & $script:dotnetExe $script:dotnetTestArgs $NetRuntime }

    # Run E2E tests in ConstrainedLanguage mode.
    if (!$script:IsNix) {
        try {
            [System.Environment]::SetEnvironmentVariable("__PSLockdownPolicy", "0x80000007", [System.EnvironmentVariableTarget]::Machine);
            exec { & $script:dotnetExe $script:dotnetTestArgs $script:NetRuntime.PS7 }
        } finally {
            [System.Environment]::SetEnvironmentVariable("__PSLockdownPolicy", $null, [System.EnvironmentVariableTarget]::Machine);
        }
    }
}

task LayoutModule -After Build {
    $modulesDir = "$PSScriptRoot/module"
    $psesVSCodeBinOutputPath = "$modulesDir/PowerShellEditorServices.VSCode/bin"
    $psesOutputPath = "$modulesDir/PowerShellEditorServices"
    $psesBinOutputPath = "$PSScriptRoot/module/PowerShellEditorServices/bin"
    $psesDepsPath = "$psesBinOutputPath/Common"
    $psesCoreHostPath = "$psesBinOutputPath/Core"
    $psesDeskHostPath = "$psesBinOutputPath/Desktop"

    foreach ($dir in $psesDepsPath,$psesCoreHostPath,$psesDeskHostPath,$psesVSCodeBinOutputPath)
    {
        New-Item -Force -Path $dir -ItemType Directory
    }

    # Copy Third Party Notices.txt to module folder
    Copy-Item -Force -Path "$PSScriptRoot\Third Party Notices.txt" -Destination $psesOutputPath

    # Assemble PSES module

    $includedDlls = [System.Collections.Generic.HashSet[string]]::new()
    [void]$includedDlls.Add('System.Management.Automation.dll')

    # PSES/bin/Common
    foreach ($psesComponent in Get-ChildItem $script:PsesOutput)
    {
        if ($psesComponent.Name -eq 'System.Management.Automation.dll' -or
            $psesComponent.Name -eq 'System.Runtime.InteropServices.RuntimeInformation.dll')
        {
            continue
        }

        if ($psesComponent.Extension)
        {
            [void]$includedDlls.Add($psesComponent.Name)
            Copy-Item -Path $psesComponent.FullName -Destination $psesDepsPath -Force
        }
    }

    # PSES/bin/Core
    foreach ($hostComponent in Get-ChildItem $script:HostCoreOutput)
    {
        if (-not $includedDlls.Contains($hostComponent.Name))
        {
            Copy-Item -Path $hostComponent.FullName -Destination $psesCoreHostPath -Force
        }
    }

    # PSES/bin/Desktop
    if (-not $script:IsNix)
    {
        foreach ($hostComponent in Get-ChildItem $script:HostDeskOutput)
        {
            if (-not $includedDlls.Contains($hostComponent.Name))
            {
                Copy-Item -Path $hostComponent.FullName -Destination $psesDeskHostPath -Force
            }
        }
    }

    # Assemble the PowerShellEditorServices.VSCode module

    foreach ($vscodeComponent in Get-ChildItem $script:VSCodeOutput)
    {
        if (-not $includedDlls.Contains($vscodeComponent.Name))
        {
            Copy-Item -Path $vscodeComponent.FullName -Destination $psesVSCodeBinOutputPath -Force
        }
    }
}

task RestorePsesModules -After Build {
    $submodulePath = (Resolve-Path $PsesSubmodulePath).Path + [IO.Path]::DirectorySeparatorChar
    Write-Host "`nRestoring EditorServices modules..."

    # Read in the modules.json file as a hashtable so it can be splatted
    $moduleInfos = @{}

    (Get-Content -Raw $ModulesJsonPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
        $name = $_.Name
        $body = @{
            Name = $name
            Version = $_.Value.Version
            AllowPrerelease = $_.Value.AllowPrerelease
            Repository = if ($_.Value.Repository) { $_.Value.Repository } else { $DefaultModuleRepository }
            Path = $submodulePath
        }

        if (-not $name) {
            throw "EditorServices module listed without name in '$ModulesJsonPath'"
        }

        $moduleInfos.Add($name, $body)
    }

    if ($moduleInfos.Keys.Count -gt 0) {
        # `#Requires` doesn't display the version needed in the error message and `using module` doesn't work with InvokeBuild in Windows PowerShell
        # so we'll just use Import-Module to check that PowerShellGet 1.6.0 or higher is installed.
        # This is needed in order to use the `-AllowPrerelease` parameter
        Import-Module -Name PowerShellGet -MinimumVersion 1.6.0 -ErrorAction Stop
    }

    # Save each module in the modules.json file
    foreach ($moduleName in $moduleInfos.Keys) {
        if (Test-Path -Path (Join-Path -Path $submodulePath -ChildPath $moduleName)) {
            Write-Host "`tModule '${moduleName}' already detected. Skipping"
            continue
        }

        $moduleInstallDetails = $moduleInfos[$moduleName]

        $splatParameters = @{
           Name = $moduleName
           RequiredVersion = $moduleInstallDetails.Version
           AllowPrerelease = $moduleInstallDetails.AllowPrerelease
           Repository = if ($moduleInstallDetails.Repository) { $moduleInstallDetails.Repository } else { $DefaultModuleRepository }
           Path = $submodulePath
        }

        Write-Host "`tInstalling module: ${moduleName} with arguments $(ConvertTo-Json $splatParameters)"

        Save-Module @splatParameters
    }

    Write-Host "`n"
}

task BuildCmdletHelp {
    New-ExternalHelp -Path $PSScriptRoot\module\docs -OutputPath $PSScriptRoot\module\PowerShellEditorServices\Commands\en-US -Force
    New-ExternalHelp -Path $PSScriptRoot\module\PowerShellEditorServices.VSCode\docs -OutputPath $PSScriptRoot\module\PowerShellEditorServices.VSCode\en-US -Force
}

# The default task is to run the entire CI build
task . Clean, Build, Test, BuildCmdletHelp
