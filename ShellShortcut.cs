using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

public sealed class FlowSwitchShortcutInfo
{
    public string TargetPath { get; set; }
    public string Arguments { get; set; }
    public string WorkingDirectory { get; set; }
    public string IconLocation { get; set; }
    public string Description { get; set; }
    public int WindowStyle { get; set; }
    public FlowSwitchShortcutInfo() { WindowStyle = 1; }
}

// Use the wide-character Shell interface for both link contents and its filename.
// Keep this separate from the already-loaded desktop branding type during updates.
public static class FlowSwitchShellShortcut
{
    private const int BufferSize = 32768;
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        // Method order follows the Windows SDK shobjidl_core.h IShellLinkW vtable.
        [PreserveSig] int GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, IntPtr findData, uint flags);
        [PreserveSig] int GetIDList(out IntPtr list);
        [PreserveSig] int SetIDList(IntPtr list);
        [PreserveSig] int GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int length);
        [PreserveSig] int SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        [PreserveSig] int GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length);
        [PreserveSig] int SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        [PreserveSig] int GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int length);
        [PreserveSig] int SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        [PreserveSig] int GetHotkey(out ushort hotkey);
        [PreserveSig] int SetHotkey(ushort hotkey);
        [PreserveSig] int GetShowCmd(out int command);
        [PreserveSig] int SetShowCmd(int command);
        [PreserveSig] int GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, out int index);
        [PreserveSig] int SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        [PreserveSig] int SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        [PreserveSig] int Resolve(IntPtr window, uint flags);
        [PreserveSig] int SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    private static object Open(string path, bool writable)
    {
        if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path) || !String.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("An absolute shortcut path is required.", "path");
        if (!writable && !File.Exists(path)) throw new FileNotFoundException("Shortcut not found.", path);
        object shortcut = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        try
        {
            if (File.Exists(path)) ((IPersistFile)shortcut).Load(path, writable ? 2 : 0);
            return shortcut;
        }
        catch { Marshal.ReleaseComObject(shortcut); throw; }
    }

    public static FlowSwitchShortcutInfo Read(string path)
    {
        object shortcut = Open(path, false);
        try
        {
            var link = (IShellLinkW)shortcut;
            var result = new FlowSwitchShortcutInfo();
            var buffer = new StringBuilder(BufferSize);
            // SLGP_RAWPATH reads the saved target without resolving/searching or showing UI.
            Marshal.ThrowExceptionForHR(link.GetPath(buffer, buffer.Capacity, IntPtr.Zero, 4));
            // Match WScript.TargetPath's expanded value using only string expansion.
            result.TargetPath = Environment.ExpandEnvironmentVariables(buffer.ToString()); buffer.Length = 0;
            Marshal.ThrowExceptionForHR(link.GetArguments(buffer, buffer.Capacity));
            result.Arguments = buffer.ToString(); buffer.Length = 0;
            Marshal.ThrowExceptionForHR(link.GetWorkingDirectory(buffer, buffer.Capacity));
            result.WorkingDirectory = buffer.ToString(); buffer.Length = 0;
            Marshal.ThrowExceptionForHR(link.GetDescription(buffer, buffer.Capacity));
            result.Description = buffer.ToString(); buffer.Length = 0;
            int iconIndex, showCommand;
            Marshal.ThrowExceptionForHR(link.GetIconLocation(buffer, buffer.Capacity, out iconIndex));
            result.IconLocation = buffer.Length == 0 ? "" : buffer.ToString() + "," + iconIndex.ToString(CultureInfo.InvariantCulture);
            Marshal.ThrowExceptionForHR(link.GetShowCmd(out showCommand));
            result.WindowStyle = showCommand;
            return result;
        }
        finally { Marshal.ReleaseComObject(shortcut); }
    }

    public static void Write(string path, string target, string arguments, string workingDirectory, string iconLocation, string description, int windowStyle)
    {
        Write(path, new FlowSwitchShortcutInfo { TargetPath = target, Arguments = arguments, WorkingDirectory = workingDirectory,
            IconLocation = iconLocation, Description = description, WindowStyle = windowStyle });
    }

    public static void Write(string path, FlowSwitchShortcutInfo info)
    {
        if (info == null) throw new ArgumentNullException("info");
        object shortcut = Open(path, true);
        try
        {
            var link = (IShellLinkW)shortcut;
            Marshal.ThrowExceptionForHR(link.SetPath(info.TargetPath ?? ""));
            Marshal.ThrowExceptionForHR(link.SetArguments(info.Arguments ?? ""));
            Marshal.ThrowExceptionForHR(link.SetWorkingDirectory(info.WorkingDirectory ?? ""));
            Marshal.ThrowExceptionForHR(link.SetDescription(info.Description ?? ""));
            Marshal.ThrowExceptionForHR(link.SetShowCmd(info.WindowStyle));
            string icon = info.IconLocation ?? "";
            int index = 0, separator = icon.LastIndexOf(',');
            if (separator >= 0 && Int32.TryParse(icon.Substring(separator + 1).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out index))
                icon = icon.Substring(0, separator);
            else index = 0;
            Marshal.ThrowExceptionForHR(link.SetIconLocation(icon.Trim('"'), index));
            // Loading before editing retains unrelated Shell properties, including AppID.
            // IPersistFile marshals its LPCOLESTR filename as Unicode independently of ACP.
            ((IPersistFile)shortcut).Save(path, true);
        }
        finally { Marshal.ReleaseComObject(shortcut); }
    }
}
