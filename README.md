# DSCR_JavaDevelopmentKit

PowerShell DSC Resource to install or uninstall Oracle Java Develoment Kit

:warning:  
This module has not been ready for production

## Install
Clone this repo and place to the PowerShell module directory (`C:\Program Files\Windows PowerShell\Modules`)  

## Usage
This is example DSC configuration.

```PowerShell
cJavaDevelopmentKit JDK8_Install
{
    Ensure = "Present"
    Version = '1.8.0_181'
    InstallerPath = "C:\jdk-8u181-windows-i586.exe"
    AddToPath = $true
    DisableSponsorsOffer = $true
    NoStartMenuShortcut = $true
    DisableAutoUpdate = $false
}
```
