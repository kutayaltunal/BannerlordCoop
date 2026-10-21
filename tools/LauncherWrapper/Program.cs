using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using TaleWorlds.Library;
using TaleWorlds.MountAndBlade.Launcher.Library;

namespace TaleWorlds.MountAndBlade.Launcher
{
    internal class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            Directory.SetCurrentDirectory(baseDir);
            string autoConnectFile = Path.Combine(baseDir, "autoconnect.args");

            if (File.Exists(autoConnectFile))
            {
                string extraArgs = File.ReadAllText(autoConnectFile).Trim();
                if (!string.IsNullOrEmpty(extraArgs))
                {
                    bool alreadyHasExtra = args.Any(a =>
                        a.Equals("/autoconnect", StringComparison.OrdinalIgnoreCase) ||
                        a.StartsWith("_MODULES_", StringComparison.OrdinalIgnoreCase));

                    if (!alreadyHasExtra)
                    {
                        string rawCmdLine = Environment.CommandLine;
                        string exePath = Process.GetCurrentProcess().MainModule.FileName;
                        string passedArgs = ExtractArguments(rawCmdLine);
                        string combinedArgs = string.IsNullOrWhiteSpace(passedArgs)
                            ? extraArgs
                            : passedArgs + " " + extraArgs;

                        var psi = new ProcessStartInfo
                        {
                            FileName = exePath,
                            Arguments = combinedArgs,
                            WorkingDirectory = baseDir,
                            UseShellExecute = false
                        };
                        var child = Process.Start(psi);
                        if (child != null)
                        {
                            child.WaitForExit();
                        }
                        return;
                    }

                    RunDirectGame(args);
                    return;
                }
            }

            RunNormalLauncher(args);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void RunDirectGame(string[] args)
        {
            RuntimeHelpers.RunClassConstructor(typeof(TaleWorlds.MountAndBlade.Launcher.Library.Program).TypeHandle);
            Common.PlatformFileHelper = new PlatformFileHelperPC("Mount and Blade II Bannerlord");
            Common.SetInvariantCulture();

            var argsList = args.ToList();
            LauncherPlatform.Initialize(argsList);
            LauncherPlatform.SetLauncherMode(false);
            LauncherPlatform.Destroy();

            TaleWorlds.Starter.Library.Program.Main(argsList.ToArray());
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void RunNormalLauncher(string[] args)
        {
            TaleWorlds.MountAndBlade.Launcher.Library.Program.Main(args);
        }

        private static string ExtractArguments(string commandLine)
        {
            if (string.IsNullOrEmpty(commandLine)) return string.Empty;
            int i = 0;
            bool inQuotes = false;
            while (i < commandLine.Length)
            {
                char c = commandLine[i];
                if (c == '"') inQuotes = !inQuotes;
                else if (!inQuotes && char.IsWhiteSpace(c)) break;
                i++;
            }
            return i < commandLine.Length ? commandLine.Substring(i).TrimStart() : string.Empty;
        }
    }
}
