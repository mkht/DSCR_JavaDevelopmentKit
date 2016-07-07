enum Ensure
{
    Absent
    Present
}

<# ++++++++++++++++++++++++++++++++++++++++++++++
環境変数PATHから指定の値を削除する
+++++++++++++++++++++++++++++++++++++++++++++++++ #>
function Remove-EnvironmentPath {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string] $Path, # 削除する値

        [Parameter(Mandatory=$true, Position=1)]
        [ValidateSet("User", "Machine")]
        [string]$Target # UserかMachineか選ぶ
    )

    $PathEnv = New-Object System.Collections.ArrayList
    ([System.Environment]::GetEnvironmentVariable("Path", $Target)) -split ';' | foreach {$PathEnv.Add($_)} | Out-Null
    if($PathEnv -contains $Path){
        $PathEnv = ($PathEnv -ne $Path)
        [System.Environment]::SetEnvironmentVariable("Path", ($PathEnv -join ';'), $Target)
    }
    [System.Environment]::GetEnvironmentVariable("Path", $Target)
}

<# ++++++++++++++++++++++++++++++++++++++++++++++
環境変数PATHの末尾に指定の値を追加する
+++++++++++++++++++++++++++++++++++++++++++++++++ #>
function Add-EnvironmentPath {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string] $Path, # 追加する値

        [Parameter(Mandatory=$true, Position=1)]
        [ValidateSet("User", "Machine")]
        [string]$Target # UserかMachineか選ぶ
    )

    $PathEnv = New-Object System.Collections.ArrayList
    ([System.Environment]::GetEnvironmentVariable("Path", $Target)) -split ';' | foreach {$PathEnv.Add($_)} | Out-Null
    if($PathEnv-notcontains $Path){
        $PathEnv.Add($Path)
        [System.Environment]::SetEnvironmentVariable("Path", ($PathEnv -join ';'), $Target)
    }
    [System.Environment]::GetEnvironmentVariable("Path", $Target)
}

<# ++++++++++++++++++++++++++++++++++++++++++++++
コマンドを新規プロセスで実行する
+++++++++++++++++++++++++++++++++++++++++++++++++ #>
function Start-Command {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string] $FilePath, # 実行ファイル
        [Parameter(Mandatory=$false, Position=1)]
        [string[]]$ArgumentList # 引数
    )
    if(-not (Test-Path $FilePath)){ throw New-Object System.IO.FileNotFoundException ("File not found") }
    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = $FilePath
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.Arguments = [string]$ArgumentList
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    $Process.Start() | Out-Null
    $Process.WaitForExit()
    $Process.ExitCode
}

<# ++++++++++++++++++++++++++++++++++++++++++++++
# Java Development Kitのインストールを制御するDSC Resource
+++++++++++++++++++++++++++++++++++++++++++++++++ #>
[DscResource()]
class cJavaDevelopmentKit
{
    # インストールされていてほしいJDKバージョン('1.8.0_74'など)
    [DscProperty(Key)]
    [string] $Version

    # インストール -> Present , アンインストール -> Absent
    # 注意:Absentの場合Versionの値は関係なくインストールされているすべてのJDKとJREを消す
    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    # インストーラのパス
    [DscProperty(Mandatory)]
    [string] $InstallerPath = ""

    [DscProperty()]
    [pscredential] $Credential

    [DscProperty()]
    [bool] $AddToPath = $true   #インストールしたJDKとJavaをPATHに追加するか否か

    # インストール時のオプション
    [bool] $DisableSponsorsOffer = $true
    [bool] $DisableAutoUpdate = $false
    [bool] $NoStartMenu = $false

    [bool] $isInstalled

    <# ================== GET ================== #>
    [cJavaDevelopmentKit] Get()
    {
        Write-Verbose "Check JDK is installed or not."
        $Jdk = $this.GetJDK()

        $RetObj = [cJavaDevelopmentKit]::new()

        $RetObj.isInstalled = $Jdk.IsInstalled
        if($RetObj.IsInstalled -eq $true){
            if($Jdk | where {$_.Version -eq $this.Version}){
                Write-Verbose ("Desired version of JDK is installed. ({0})" -f $this.Version)
                $RetObj.Ensure = [Ensure]::Present
            }
            else{
                Write-Verbose ("JDK is installed, but it is NOT desired version. ({0})" -f [string]$Jdk.Version)
                $RetObj.Ensure = [Ensure]::Absent
            }
        }
        else{
            Write-Verbose "JDK is NOT installed."
            $RetObj.Ensure = [Ensure]::Absent
        }

        return $RetObj
    } # End of Get()

    <# ================== TEST ================== #>
    [bool] Test()
    {
        $EnsureParam = $this.Ensure
        if($EnsureParam -eq [Ensure]::Absent){   # インストールされていてほしくない
            return (-not $this.Get().isInstalled)   # インストールされている場合$falseを、されていない場合$trueを返す
        }
        
        return ($this.Get().Ensure -eq $EnsureParam)
    } # End of Test()

    <# ================== SET ================== #>
    [void] Set()
    {
        if($this.Ensure -eq [Ensure]::Absent){
            Write-Verbose ("Uninstall all of JREs and JDKs.")
            $Jdk = $this.GetJDK()
            $Jre = $this.GetJRE()
            $this.UninstallJava(($Jdk + $Jre))

            Write-Verbose ("All tasks of this configruation is done.")                    
        }
        elseif($this.Ensure -eq [Ensure]::Present){
            [System.Uri]$InstallerUri = $this.InstallerPath -as [System.Uri]
            if($InstallerUri.IsLoopback -eq $null){
                # インストーラパスが正しくない
                Write-Warning ("InstallerPath is not valid Uri")
                throw New-Object "System.InvalidCastException"
            }

            $GUID = New-Guid
            try{
                # インストーラのパスがURLの場合ダウンロードしてから実行する
                # インストーラの場所によって処理分岐(ローカル or 共有フォルダ or Web)
                if($InstallerUri.IsLoopback){
                    # ローカルインストーラ使用
                    $Installer = $InstallerUri.LocalPath
                }
                else{
                    $DownloadFolder = Join-Path $env:TEMP $GUID
                    if(! (Test-Path $DownloadFolder)){
                        # ダウンロードフォルダが存在しない場合は作る
                        Write-Verbose ("Create Temp folder ({0})" -f $DownloadFolder)
                        New-Item -ItemType Directory -Path $DownloadFolder -ErrorAction stop | Out-Null
                    }
                    $Installer = Join-Path $DownloadFolder ([System.IO.Path]::GetFileName($InstallerUri.LocalPath)) -ErrorAction Stop
                    if($InstallerUri.IsUnc){
                        # インストーラを共有フォルダからローカルにDLする
                        Write-Verbose ("Get installer from '{0}'" -f $InstallerUri.LocalPath)
                        Copy-Item -Path $InstallerUri.LocalPath -Destination $Installer -Credential $this.Credential -ErrorAction Stop
                    }
                    elseif($InstallerUri.Scheme -match 'http|https|ftp'){
                        # インストーラをWebからDL
                        Write-Verbose ("Get installer from '{0}'" -f $InstallerUri.AbsoluteUri)
                        Invoke-WebRequest -Uri $InstallerUri.AbsoluteUri -OutFile $Installer -Credential $this.Credential -TimeoutSec 300 -ErrorAction stop
                    }
                }
                
                if(-not (Test-Path $Installer)){
                    # インストーラが見つからない(パス指定ミスか、DL失敗か)
                    Write-Error ("Installer file not Found at {0}" -f $Installer)
                    throw (New-Object System.IO.FileNotFoundException)
                }

                # TODO : インストーラのバージョンチェックを入れるか？
                [string[]]$setupArgs = "/s", "REBOOT=0" # インストールオプション(サイレント&再起動なし)
                if($this.DisableAutoUpdate){ $setupArgs += "AUTO_UPDATE=0" } # 自動更新無効
                if($this.DisableSponsorsOffer){ $setupArgs += "SPONSORS=0" } # スポンサーのオファーを表示しない
                if($this.NoStartMenu){ $setupArgs += "NOSTARTMENU=1" } # スタートメニューにショートカットを追加しない

                Write-Verbose 'Installing Jave Development Kit.'
                $exitCode = Start-Command -FilePath $Installer -ArgumentList $setupArgs    # インストール実行
                if($exitCode -eq 0){
                    Write-Verbose ("Install completed successfully.")
                }
                else{
                    Write-Verbose ("Install Java Development Kit exited with errors. ExitCode : {0}" -f $exitCode)
                    throw ("Install Java Development Kit exited with errors. ExitCode : {0}" -f $exitCode)
                }

                # 現在インストールされているすべてのJDK、JREを取得
                $AllJdk = $this.GetJDK()
                $OldJdk = @($AllJdk | where {$_.Version -ne $this.version})
                $CurrentJdk = @($AllJdk | where {$_.Version -eq $this.version})

                $AllJre = $this.GetJRE()
                $OldJre = @($AllJre | where {$_.Version -ne $this.version})
                $CurrentJre = @($AllJre | where {$_.Version -eq $this.version})
                
                # 古いJavaのアンインストール処理
                if($OldJdk -or $OldJre){ # or と and どっちが適切だろうか...
                    Write-Verbose ("Uninstall previous version of JRE and JDK.")
                    $this.UninstallJava(($OldJdk + $OldJre))
                }

                # パスに追加
                if($this.AddToPath){
                    Write-Verbose ("Add to PATH")
                    if($CurrentJdk) { Add-EnvironmentPath -Path (Join-Path $CurrentJdk.InstallLocation '\bin') -Target Machine | Out-Null }
                    if($CurrentJre) { Add-EnvironmentPath -Path (Join-Path $CurrentJre.InstallLocation '\bin') -Target Machine | Out-Null }
                }

                Write-Verbose ("All tasks of this configruation is done.")                    
            }
            catch{
                throw $_
            }
            finally{
                $DownloadFolder = Join-Path $env:TEMP $GUID
                if(Test-Path $DownloadFolder){
                    # 一時フォルダは消す
                    Remove-Item -Path $DownloadFolder -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } # End of Set()

    <# ================== GetJDK ================== #>
    # インストールされているJDKの情報を取得するヘルパメソッド
    [Object] GetJDK()
    {
        $Params = @{
            RegSoftPath = "HKLM:\\SOFTWARE\JavaSoft\Java Development Kit"
            RegUninstallPath = "HKLM:\\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            SearchName = "Java SE Development Kit \d+ Update \d+"
        }
        return $this.GetJava($Params)
    } # End of GetJDK()

    <# ================== GetJRE ================== #>
    # インストールされているJREの情報を取得するヘルパメソッド
    [Object] GetJRE()
    {   
        $Params = @{
            RegSoftPath = "HKLM:\\SOFTWARE\JavaSoft\Java Runtime Environment"
            RegUninstallPath = "HKLM:\\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            SearchName = "Java \d+ Update \d+"
        }
        return $this.GetJava($Params)
    } # End of GetJRE()

    <# ================== GetJava ================== #>
    # インストールされているJDK or JREの情報を取得するヘルパメソッド
    [Object]GetJava([HashTable]$Params){
        $RegSoftPath = $Params.RegSoftPath
        $RegUninstallPath = $Params.RegUninstallPath
        $SearchName = $Params.SearchName

        if(!($RegSoftPath) -or !(Test-Path $RegSoftPath)){
            return [PSCustomObject]@{
                Version = ''
                ProductId = ''
                DisplayName = ''
                InstallLocation = ''
                IsInstalled = $false
            }
        }
        else{
            # Get JRE Version from Registry.
            $AllJava = dir $RegSoftPath  | select -expa pschildname | where {$_ -match "[\d\.]_"}
            $returnValue = @()
            foreach($java in $AllJava){
                $ret = [PSCustomObject]@{
                    Version = ''    # e.g. "1.8.0_92"
                    ProductId = ''  # e.g. "{26A24AE4-039D-4CA4-87B4-2F83218092F0}"
                    DisplayName = ''    # e.g. "Java 8 Update 92"
                    InstallLocation = ''    # e.g. "C:\Program Files\Java\jre1.8.0_92\"
                    IsInstalled = $false
                }
                $InstallDir = (dir (Join-Path $RegSoftPath $java) | foreach {Get-ItemProperty $_.PsPath}).INSTALLDIR
                $info = (dir -Path $RegUninstallPath | where {($_.GetValue('DisplayName') -match $SearchName) -and ($_.GetValue('InstallLocation') -eq $InstallDir)})
                $ret.IsInstalled = [bool]$info
                $ret.Version = $java
                if($ret.IsInstalled -eq $true){
                    $ret.ProductId = $info[0].PSChildName
                    $ret.DisplayName = $info[0].GetValue('DisplayName')
                    $ret.InstallLocation = $info[0].GetValue('InstallLocation')
                }
                $returnValue += $ret
            }
            return $returnValue
        }
    }

    <# ================== UninstallJava ================== #>
    # Javaをアンインストールするメソッド
    [void]UninstallJava($Javas){
        # 複数のJavaが渡された場合全部アンインストールする
        foreach ($Java in $Javas){
            if($Java.IsInstalled -eq $true){
                try{
                    $fileName = "$env:windir\system32\msiexec.exe"
                    [string[]]$setupArgs = "/qn", ("/X{0}" -f $Java.ProductId)
                    Write-Verbose ("Uninstalling {0}." -f $Java.DisplayName)
                    $exitCode = Start-Command -FilePath $fileName -ArgumentList $setupArgs    # アンインストール実行
                    if($exitCode -eq 0){
                            Write-Verbose ("Uninstall completed successfully.")
                            Remove-EnvironmentPath -Path (Join-Path $Java.InstallLocation '\bin') -Target Machine | Out-Null
                    }
                    else{
                        Write-Verbose ("Uninstall {0} exited with errors. ExitCode : {1}" -f $Java.DisplayName,$exitCode)
                        throw ("Uninstall {0} exited with errors. ExitCode : {1}" -f $Java.DisplayName,$exitCode)
                    }
                }
                catch{
                    throw $_
                }
            }
        }
    }
}