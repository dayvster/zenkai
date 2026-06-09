using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

struct WinApp
{
    [JsonPropertyName("type")]         public string      Type       { get; set; }
    [JsonPropertyName("name")]         public string      Name       { get; set; }
    [JsonPropertyName("version")]     public string?     Version    { get; set; }
    [JsonPropertyName("comment")]     public string?     Comment    { get; set; }
    [JsonPropertyName("icon")]        public string?     Icon       { get; set; }
    [JsonPropertyName("try_exec")]    public string?     TryExec    { get; set; }
    [JsonPropertyName("exec")]        public string?     Exec       { get; set; }
    [JsonPropertyName("install_path")] public string?     InstallPath { get; set; }
    [JsonPropertyName("url")]         public string?     Url        { get; set; }
    [JsonPropertyName("categories")]   public List<string> Categories { get; set; }
    [JsonPropertyName("no_display")]   public bool        NoDisplay  { get; set; }
    [JsonPropertyName("hidden")]      public bool        Hidden     { get; set; }
}

class Program
{
    static void Main()
    {
        var apps = new List<WinApp>();

        apps.AddRange(GetRegistryApps());
        apps.AddRange(GetUwpApps());
        apps.AddRange(GetStartMenuApps());

        var opts = new JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };
        Console.WriteLine(JsonSerializer.Serialize(apps, opts));
    }

    static List<WinApp> GetRegistryApps()
    {
        var result = new List<WinApp>();
        var seen   = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        {
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                using var root = RegistryKey.OpenBaseKey(hive, view);

                foreach (var keyPath in new[]
                {
                    @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                    @"SOFTWARE\Classes\Installer\Products"
                })
                {
                    using var key = root.OpenSubKey(keyPath);
                    if (key == null) continue;

                    foreach (var sub in key.GetSubKeyNames())
                    {
                        using var subKey = key.OpenSubKey(sub);
                        if (subKey == null) continue;

                        var name = subKey.GetValue("DisplayName") as string;
                        if (string.IsNullOrWhiteSpace(name)) continue;
                        if (seen.Contains(name)) continue;
                        if ((subKey.GetValue("SystemComponent") as int?) == 1) continue;
                        if (subKey.GetValue("ParentDisplayName") != null) continue;
                        seen.Add(name);

                        var installLoc = subKey.GetValue("InstallLocation") as string;
                        var iconPath   = subKey.GetValue("DisplayIcon") as string;
                        var version    = subKey.GetValue("DisplayVersion") as string;
                        var publisher  = subKey.GetValue("Publisher") as string;
                        var comment    = subKey.GetValue("Comments") as string ?? name;

                        if (iconPath != null && iconPath.Contains(','))
                            iconPath = iconPath[..iconPath.IndexOf(',')];
                        if (iconPath != null && !File.Exists(iconPath))
                            iconPath = null;
                        if (!string.IsNullOrEmpty(installLoc))
                            installLoc = Environment.ExpandEnvironmentVariables(installLoc);

                        var exec = BestExe(installLoc, name);

                        result.Add(new WinApp
                        {
                            Type = "Application",
                            Name = name,
                            Version = version,
                            Comment = comment,
                            Icon = iconPath,
                            TryExec = exec,
                            Exec = exec,
                            InstallPath = installLoc,
                            Categories = publisher != null
                                ? new List<string> { publisher }
                                : new List<string>()
                        });
                    }
                }
            }
        }
        return result;
    }

    static List<WinApp> GetUwpApps()
    {
        var result = new List<WinApp>();
        var psCode = new StringBuilder();
        psCode.Append("$enc=[Console]::OutputEncoding=[Text.Encoding]::UTF8;");
        psCode.Append("Get-AppxPackage -AllUsers|ForEach-Object{");
        psCode.Append("$p=$_;$a=$p.AppList;");
        psCode.Append("if(-not$a){");
        psCode.Append("[PSCustomObject]@{");
        psCode.Append("N=$p.Name;");
        psCode.Append("V=\"$($p.Version.Major).$($p.Version.Minor).$($p.Version.Build).$($p.Version.Revision)\";");
        psCode.Append("L=$p.InstallLocation;");
        psCode.Append("P=$p.PublisherId;");
        psCode.Append("A=$null");
        psCode.Append("}}else{");
        psCode.Append("$a|ForEach-Object{");
        psCode.Append("[PSCustomObject]@{");
        psCode.Append("N=$p.Name;");
        psCode.Append("V=\"$($p.Version.Major).$($p.Version.Minor).$($p.Version.Build).$($p.Version.Revision)\";");
        psCode.Append("L=$p.InstallLocation;");
        psCode.Append("P=$p.PublisherId;");
        psCode.Append("A=$_.AppUserModelId");
        psCode.Append("}}}");
        psCode.Append("}|ConvertTo-Json -Compress");

        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(psCode.ToString()));

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -EncodedCommand " + encoded,
                RedirectStandardOutput = true,
                StandardOutputEncoding = Encoding.UTF8,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc == null) return result;

            var output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(15_000);

            if (string.IsNullOrWhiteSpace(output) || output == "null")
                return result;

            if (!output.TrimStart().StartsWith("["))
                output = "[" + output + "]";

            using var doc = JsonDocument.Parse(output);
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                var name    = el.GetProperty("N").GetString();
                var ver     = el.GetProperty("V").GetString();
                var loc     = el.GetProperty("L").GetString();
                var pub     = el.GetProperty("P").GetString();
                var aumid   = el.GetProperty("A").GetString();

                if (string.IsNullOrEmpty(name)) continue;

                result.Add(new WinApp
                {
                    Type = "Application",
                    Name = name,
                    Version = ver,
                    Icon = aumid,
                    TryExec = aumid,
                    Exec = aumid != null ? $"shell:AppsFolder\\{aumid}" : null,
                    Url = $"ms-{name.ToLowerInvariant()}:",
                    InstallPath = loc,
                    Categories = new List<string> { "UWP" }
                });
            }
        }
        catch { }

        return result;
    }

    static List<WinApp> GetStartMenuApps()
    {
        var result = new List<WinApp>();
        var seen   = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var dirs = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs")
        };

        foreach (var dir in dirs.Distinct())
        {
            if (!Directory.Exists(dir)) continue;

            foreach (var lnk in Directory.EnumerateFiles(dir, "*.lnk", SearchOption.AllDirectories))
            {
                var name   = Path.GetFileNameWithoutExtension(lnk);
                if (seen.Contains(name)) continue;
                seen.Add(name);

                var target = ResolveLnk(lnk);
                if (target == null) continue;

                result.Add(new WinApp
                {
                    Type = "Application",
                    Name = name,
                    Icon = target,
                    TryExec = target,
                    Exec = target,
                    InstallPath = Path.GetDirectoryName(target)
                });
            }
        }
        return result;
    }

    static string? BestExe(string? dir, string? appName)
    {
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return null;

        return Directory.EnumerateFiles(dir, "*.exe", SearchOption.TopDirectoryOnly)
            .OrderByDescending(f =>
            {
                var fn    = Path.GetFileNameWithoutExtension(f);
                var fnLow = fn.ToLowerInvariant();

                if (fnLow.Contains("unins") || fnLow.Contains("uninstall")) return -100;
                if (fnLow is "setup" or "install" or "redist")             return  -50;

                int s = 0;
                if (appName != null)
                {
                    if (fn.StartsWith(appName, StringComparison.OrdinalIgnoreCase)) s += 30;
                    else if (fn.Contains(appName, StringComparison.OrdinalIgnoreCase)) s += 20;
                    if (appName.Contains(fn, StringComparison.OrdinalIgnoreCase)) s += 10;
                }
                return s;
            })
            .ThenBy(f => Path.GetFileNameWithoutExtension(f).Length)
            .FirstOrDefault();
    }

    [DllImport("ole32.dll")]
    static extern int CoInitializeEx(IntPtr pv, uint dwCoInit);

    [DllImport("ole32.dll")]
    static extern void CoUninitialize();

    static string? ResolveLnk(string lnkPath)
    {
        try
        {
            CoInitializeEx(IntPtr.Zero, 2);
            var shell = Type.GetTypeFromProgID("WScript.Shell");
            if (shell == null) return null;

            dynamic wsh  = Activator.CreateInstance(shell)!;
            dynamic sc   = wsh.CreateShortcut(lnkPath);
            var target   = (string)sc.TargetPath;
            return string.IsNullOrWhiteSpace(target) ? null : target;
        }
        catch { return null; }
        finally { CoUninitialize(); }
    }
}
