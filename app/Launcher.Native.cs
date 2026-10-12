using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public sealed class XingliLaunchProbeResult {
    public bool HasAppProcess;
    public bool HasWindow;
    public bool Responding;
    public long WindowHandle;
    public int ProcessId;
    public int[] ProcessIds;
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IXingliLaunchActivationManager {
    [PreserveSig] int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        uint options, out uint processId);
}
[ComImport, Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
internal class XingliLaunchActivationManager { }

public static class XingliLaunchNative {
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] private struct Rect {
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeout(
        IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(
        IntPtr process, uint flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetApplicationUserModelId(
        IntPtr process, ref uint length, StringBuilder appUserModelId);

    private static bool IsCodexProcess(int processId) {
        IntPtr handle = OpenProcess(0x1000, false, processId);
        if (handle == IntPtr.Zero) return false;
        try {
            uint length = 0;
            GetApplicationUserModelId(handle, ref length, null);
            if (length > 0 && length < 4096) {
                var aumid = new StringBuilder((int)length);
                if (GetApplicationUserModelId(handle, ref length, aumid) == 0 &&
                    aumid.ToString().StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase)) return true;
            }
            var image = new StringBuilder(4096);
            int size = image.Capacity;
            if (!QueryFullProcessImageName(handle, 0, image, ref size)) return false;
            string path = image.ToString();
            return path.IndexOf("\\WindowsApps\\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0 &&
                (path.EndsWith("\\ChatGPT.exe", StringComparison.OrdinalIgnoreCase) ||
                 path.EndsWith("\\Codex.exe", StringComparison.OrdinalIgnoreCase));
        } finally { CloseHandle(handle); }
    }

    // Call this on the launcher worker, not a WPF DispatcherTimer callback.
    public static XingliLaunchProbeResult Probe() {
        var result = new XingliLaunchProbeResult();
        var ids = new HashSet<int>();
        foreach (string name in new string[] { "ChatGPT", "Codex" }) {
            foreach (Process process in Process.GetProcessesByName(name)) {
                using (process) {
                    try { if (IsCodexProcess(process.Id)) ids.Add(process.Id); } catch { }
                }
            }
        }
        result.ProcessIds = new int[ids.Count];
        ids.CopyTo(result.ProcessIds);
        result.HasAppProcess = ids.Count != 0;
        if (!result.HasAppProcess) return result;
        EnumWindows((hwnd, parameter) => {
            if (!IsWindowVisible(hwnd)) return true;
            uint processId;
            GetWindowThreadProcessId(hwnd, out processId);
            if (!ids.Contains((int)processId)) return true;
            Rect rect;
            if (!GetWindowRect(hwnd, out rect)) return true;
            if (!IsIconic(hwnd) && (rect.Right - rect.Left < 180 || rect.Bottom - rect.Top < 100)) return true;
            IntPtr ignored;
            bool responding = SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, 100, out ignored) != IntPtr.Zero;
            // Prefer a responding window if an app has more than one top-level window.
            if (!result.HasWindow || responding) {
                result.HasWindow = true;
                result.Responding = responding;
                result.WindowHandle = hwnd.ToInt64();
                result.ProcessId = (int)processId;
            }
            return !responding;
        }, IntPtr.Zero);
        return result;
    }

    public static uint Activate(string appUserModelId) {
        var manager = (IXingliLaunchActivationManager)new XingliLaunchActivationManager();
        try {
            uint processId;
            int status = manager.ActivateApplication(appUserModelId, String.Empty, 0, out processId);
            Marshal.ThrowExceptionForHR(status);
            return processId;
        } finally {
            if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
        }
    }

    // Focus is intentionally separate so Codex does not interrupt the splash.
    public static bool Focus(long windowHandle) {
        var hwnd = new IntPtr(windowHandle);
        if (!IsWindow(hwnd)) return false;
        ShowWindowAsync(hwnd, IsIconic(hwnd) ? 9 : 5);
        return SetForegroundWindow(hwnd);
    }
}
