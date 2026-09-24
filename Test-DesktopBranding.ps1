[CmdletBinding()]
param([string]$PackageDirectory='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if(-not ('FlowSwitchDesktop' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'DesktopBranding.cs')}
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @'
using System;using System.Runtime.InteropServices;using System.Runtime.InteropServices.ComTypes;using System.Windows.Forms;
public class BrandTestForm:Form { public void RecreateForTest(){RecreateHandle();} }
public static class BrandNativeTest {
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)]private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr value);
 [DllImport("user32.dll")]public static extern IntPtr SendMessage(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)]public static extern uint ExtractIconEx(string path,int index,[Out] IntPtr[] large,[Out] IntPtr[] small,uint count);
 [DllImport("user32.dll")]public static extern bool DestroyIcon(IntPtr icon);
 public static string ProcessId(){IntPtr value;Marshal.ThrowExceptionForHR(GetCurrentProcessExplicitAppUserModelID(out value));try{return Marshal.PtrToStringUni(value);}finally{Marshal.FreeCoTaskMem(value);}}
 [StructLayout(LayoutKind.Sequential)]private struct Key {public Guid Format;public uint Id;}
 [StructLayout(LayoutKind.Explicit,Size=24)]private struct Variant {[FieldOffset(0)]public ushort Type;[FieldOffset(8)]public IntPtr Value;}
 [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]private interface Store {
 [PreserveSig]int GetCount(out uint count);[PreserveSig]int GetAt(uint index,out Key key);[PreserveSig]int GetValue(ref Key key,out Variant value);[PreserveSig]int SetValue(ref Key key,ref Variant value);[PreserveSig]int Commit();}
 public static void LegacyShortcut(string path){
 object link=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
 try{((IPersistFile)link).Load(path,2);var key=new Key{Format=new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),Id=5};var value=new Variant{Type=31,Value=Marshal.StringToCoTaskMemUni("FlowSwitch.Desktop")};
 try{Marshal.ThrowExceptionForHR(((Store)link).SetValue(ref key,ref value));Marshal.ThrowExceptionForHR(((Store)link).Commit());((IPersistFile)link).Save(path,true);}finally{Marshal.FreeCoTaskMem(value.Value);}}
 finally{Marshal.ReleaseComObject(link);}}
}
'@
$script:BrandPass=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:BrandPass++}
function Same-Pixels([Drawing.Bitmap]$Left,[Drawing.Bitmap]$Right){
    if($Left.Size -ne $Right.Size){return $false}
    for($y=0;$y -lt $Left.Height;$y++){for($x=0;$x -lt $Left.Width;$x++){if($Left.GetPixel($x,$y).ToArgb() -ne $Right.GetPixel($x,$y).ToArgb()){return $false}}}
    return $true
}
$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$qaRoot=Join-Path $temporaryRoot ('FlowSwitch-brand-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qaRoot)
$previousData=$env:PROXY_SWITCH_DATA_DIR
$form=$null;$formIcon=$null;$shell=$null
try{
    [FlowSwitchDesktop]::Initialize()
    Check ([BrandNativeTest]::ProcessId() -ceq [FlowSwitchDesktop]::AppId) 'Process taskbar identity differs from the shared brand identity.'
    Check ([FlowSwitchDesktop]::AppId -ceq 'FlowSwitch.Desktop.DualPortal') 'Dual-portal identity must stay stable across releases.'
    $iconPath=Join-Path $PSScriptRoot 'assets\FlowSwitch.ico'
    $form=New-Object BrandTestForm;$form.ShowInTaskbar=$false
    $formIcon=New-Object Drawing.Icon($iconPath);$form.Icon=$formIcon
    $desktopCommand='"C:\测试 package\FlowSwitch.exe" --data-directory "C:\测试 settings"'
    $form.Add_HandleCreated({[void][FlowSwitchDesktop]::ConfigureWindow($form.Handle,$desktopCommand,$iconPath)})
    $form.Show();[Windows.Forms.Application]::DoEvents()
    foreach($pass in 1,2){
        if($pass -eq 2){$form.RecreateForTest();[Windows.Forms.Application]::DoEvents()}
        Check ([FlowSwitchDesktop]::ReadWindowProperty($form.Handle,5) -ceq [FlowSwitchDesktop]::AppId) 'Native window lost its taskbar identity after handle creation.'
        Check ([FlowSwitchDesktop]::ReadWindowProperty($form.Handle,2) -ceq $desktopCommand) 'Relaunch command changed its Unicode path or explicit data directory.'
        Check ([FlowSwitchDesktop]::ReadWindowProperty($form.Handle,3) -ceq ($iconPath+',0')) 'Relaunch icon does not use the selected dual-portal asset.'
        foreach($pair in @(@(0,16),@(1,32))){
            $handle=[BrandNativeTest]::SendMessage($form.Handle,127,[IntPtr]$pair[0],[IntPtr]::Zero)
            Check ($handle -ne [IntPtr]::Zero) 'WM_GETICON did not return a native window icon.'
            $actual=[Drawing.Icon]::FromHandle($handle).ToBitmap();$expectedIcon=New-Object Drawing.Icon($iconPath,$pair[1],$pair[1]);$expected=$expectedIcon.ToBitmap()
            try{Check (Same-Pixels $actual $expected) 'Native taskbar/titlebar icon pixels differ from the approved ICO.'}finally{$actual.Dispose();$expected.Dispose();$expectedIcon.Dispose()}
        }
    }
    $form.Close();$form.Dispose();$form=$null
    # The installer runs against a complete temporary source copy and a fake desktop.
    $app=Join-Path $qaRoot 'app';$desktop=Join-Path $qaRoot 'Desktop';$data=Join-Path $qaRoot 'settings'
    [void][IO.Directory]::CreateDirectory($app);[void][IO.Directory]::CreateDirectory($desktop);[void][IO.Directory]::CreateDirectory((Join-Path $app 'assets'))
    foreach($name in @('ProxySwitch.ps1','Storage.ps1','Preferences.ps1','DesktopBranding.cs','Install-Shortcut.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $app $name)}
    Copy-Item -LiteralPath $iconPath -Destination (Join-Path $app 'assets\FlowSwitch.ico')
    $installer=Join-Path $app 'Install-Shortcut.ps1';$original=[IO.File]::ReadAllText($installer);$needle='$desktop=[Environment]::GetFolderPath(''Desktop'')'
    Check ($original.Contains($needle)) 'Installer isolation hook is missing; refusing to access the real desktop.'
    [IO.File]::WriteAllText($installer,$original.Replace($needle,('$desktop='''+$desktop.Replace("'","''")+'''')),(New-Object Text.UTF8Encoding($true)))
    $env:PROXY_SWITCH_DATA_DIR=$data
    $shell=New-Object -ComObject WScript.Shell
    $destination=Join-Path $desktop '流向 FlowSwitch.lnk'
    $legacy=$shell.CreateShortcut($destination);$legacy.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$legacy.Arguments='-File "C:\old\ProxySwitch.ps1"';$legacy.Description='FlowSwitch old brand';$legacy.Save()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($legacy)
    [BrandNativeTest]::LegacyShortcut($destination)
    $oldHash=(Get-FileHash -LiteralPath $destination).Hash
    & $installer|Out-Null
    Check ([FlowSwitchDesktop]::ReadShortcutProperty($destination,5) -ceq [FlowSwitchDesktop]::AppId) 'Installer did not migrate the old taskbar identity.'
    $backup=@(Get-ChildItem -LiteralPath (Join-Path $data 'backups') -Filter '*.lnk')
    Check ($backup.Count -eq 1 -and (Get-FileHash -LiteralPath $backup[0].FullName).Hash -ceq $oldHash) 'Existing shortcut was not backed up byte-for-byte.'
    Check ([FlowSwitchDesktop]::ReadShortcutProperty($backup[0].FullName,5) -ceq 'FlowSwitch.Desktop') 'Backup no longer preserves the old identity for rollback.'
    $saved=$shell.CreateShortcut($destination)
    try{Check ($saved.IconLocation -ieq ((Join-Path $app 'assets\FlowSwitch.ico')+',0') -and $saved.Arguments.Contains($data)) 'Shortcut lost its current icon or selected data directory.'}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($saved)}
    $foreign=Join-Path $desktop 'Other.lnk';$link=$shell.CreateShortcut($foreign);$link.TargetPath=Join-Path $env:SystemRoot 'System32\notepad.exe';$link.Save();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    $foreignHash=(Get-FileHash -LiteralPath $foreign).Hash;$rejected=$false
    try{& $installer -Name 'Other'|Out-Null}catch{$rejected=$true}
    Check ($rejected -and (Get-FileHash -LiteralPath $foreign).Hash -ceq $foreignHash) 'Installer overwrote a shortcut belonging to another application.'
    if($PackageDirectory){
        $package=[IO.Path]::GetFullPath($PackageDirectory);$exe=Join-Path $package 'FlowSwitch.exe';$packageIcon=Join-Path $package 'app\assets\FlowSwitch.ico'
        [IntPtr[]]$large=@([IntPtr]::Zero);[IntPtr[]]$small=@([IntPtr]::Zero)
        $extracted=[BrandNativeTest]::ExtractIconEx($exe,0,$large,$small,1)
        Check ($extracted -gt 0 -and $large[0] -ne [IntPtr]::Zero -and $small[0] -ne [IntPtr]::Zero) 'Packaged EXE did not contain both icon sizes.'
        try{foreach($pair in @(@($small[0],16),@($large[0],32))){
            $actual=[Drawing.Icon]::FromHandle($pair[0]).ToBitmap();$expectedIcon=New-Object Drawing.Icon($packageIcon,$pair[1],$pair[1]);$expected=$expectedIcon.ToBitmap()
            try{Check (Same-Pixels $actual $expected) 'Packaged EXE still embeds a different brand icon.'}finally{$actual.Dispose();$expected.Dispose();$expectedIcon.Dispose()}
        }}finally{foreach($handle in @($large[0],$small[0])){if($handle -ne [IntPtr]::Zero){[void][BrandNativeTest]::DestroyIcon($handle)}}}
    }
    Write-Output ('PASS: '+$script:BrandPass+' desktop branding checks; native icons, recreated window, relaunch data and isolated shortcut identity migration. No real shortcuts, taskbar pins, Explorer caches or network settings were changed.')
}finally{
    if($form){$form.Dispose()};if($formIcon){$formIcon.Dispose()};if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    $env:PROXY_SWITCH_DATA_DIR=$previousData
    $resolved=[IO.Path]::GetFullPath($qaRoot)
    if($resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^FlowSwitch-brand-[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
