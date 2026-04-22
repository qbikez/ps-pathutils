using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Provider;
using System.Text.RegularExpressions;

namespace PathUtils
{
    internal sealed class GitWorktreeInfo
    {
        public string Name { get; set; }
        public string Path { get; set; }
        public string CommitHash { get; set; }
        public string Branch { get; set; }
        public bool IsDetached { get; set; }
        public bool IsPrunable { get; set; }
        public bool IsMain { get; set; }
    }

    [CmdletProvider("WtProvider", ProviderCapabilities.None)]
    public sealed class WtProvider : NavigationCmdletProvider
    {
        private static readonly Regex WorktreeLineRegex = new Regex(@"^\s*(.+?)\s{2,}([a-f0-9]+)\s+(\[(.+?)\]|\((.+?)\))", RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static string RunGit(string workingDirectory, string arguments)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "git",
                Arguments = arguments,
                WorkingDirectory = workingDirectory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };

            using (var process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Failed to start git process.");
                }

                var stdout = process.StandardOutput.ReadToEnd();
                var stderr = process.StandardError.ReadToEnd();
                process.WaitForExit();

                if (process.ExitCode != 0)
                {
                    var msg = string.IsNullOrWhiteSpace(stderr) ? "git command failed" : stderr.Trim();
                    throw new InvalidOperationException(msg);
                }

                return stdout.TrimEnd();
            }
        }

        private string GetCurrentFileSystemPath()
        {
            var fsPath = SessionState.Path.CurrentFileSystemLocation?.Path;
            if (!string.IsNullOrWhiteSpace(fsPath))
            {
                return fsPath;
            }

            return Environment.CurrentDirectory;
        }

        private List<GitWorktreeInfo> GetWorktrees()
        {
            var cwd = GetCurrentFileSystemPath();
            var repoRoot = RunGit(cwd, "rev-parse --show-toplevel");
            repoRoot = System.IO.Path.GetFullPath(repoRoot);

            var output = RunGit(repoRoot, "worktree list");
            var lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
            var list = new List<GitWorktreeInfo>();

            foreach (var line in lines)
            {
                var match = WorktreeLineRegex.Match(line);
                if (!match.Success)
                {
                    continue;
                }

                var path = match.Groups[1].Value;
                var status = (match.Groups[4].Value + match.Groups[5].Value).Trim();
                var isDetached = string.Equals(status, "detached", StringComparison.OrdinalIgnoreCase);
                var isPrunable = string.Equals(status, "prunable", StringComparison.OrdinalIgnoreCase);
                var branch = (!isDetached && !isPrunable) ? status : null;
                var fullPath = System.IO.Path.GetFullPath(path);
                var name = new DirectoryInfo(fullPath).Name;
                var isMain = string.Equals(fullPath, repoRoot, StringComparison.OrdinalIgnoreCase);

                list.Add(new GitWorktreeInfo
                {
                    Name = name,
                    Path = fullPath,
                    CommitHash = match.Groups[2].Value,
                    Branch = branch,
                    IsDetached = isDetached,
                    IsPrunable = isPrunable,
                    IsMain = isMain,
                });
            }

            return list;
        }

        private GitWorktreeInfo FindWorktree(string selector, List<GitWorktreeInfo> worktrees)
        {
            if (string.IsNullOrWhiteSpace(selector))
            {
                return worktrees.FirstOrDefault(w => w.IsMain);
            }

            var exact = worktrees.FirstOrDefault(w => string.Equals(w.Name, selector, StringComparison.OrdinalIgnoreCase));
            if (exact != null)
            {
                return exact;
            }

            return worktrees.FirstOrDefault(w => w.Name.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private static string NormalizePath(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return string.Empty;
            }

            return path.Replace('/', '\\').Trim('\\');
        }

        private bool TryResolveFileSystemPath(string path, out string resolvedPath, out bool isRoot, out bool isWorktreeNode)
        {
            resolvedPath = null;
            isRoot = false;
            isWorktreeNode = false;

            var normalized = NormalizePath(path);
            if (string.IsNullOrEmpty(normalized))
            {
                isRoot = true;
                return true;
            }

            var worktrees = GetWorktrees();
            var parts = normalized.Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
            var selector = parts[0];
            var worktree = FindWorktree(selector, worktrees);
            if (worktree == null)
            {
                return false;
            }

            if (parts.Length == 1)
            {
                isWorktreeNode = true;
                resolvedPath = worktree.Path;
                return true;
            }

            var relative = string.Join("\\", parts.Skip(1));
            resolvedPath = System.IO.Path.Combine(worktree.Path, relative);
            return true;
        }

        protected override bool ItemExists(string path)
        {
            try
            {
                string fsPath;
                bool isRoot;
                bool isWorktreeNode;
                if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode))
                {
                    return false;
                }

                if (isRoot)
                {
                    return true;
                }

                if (isWorktreeNode)
                {
                    return true;
                }

                return Directory.Exists(fsPath) || File.Exists(fsPath);
            }
            catch
            {
                return false;
            }
        }

        protected override bool IsItemContainer(string path)
        {
            string fsPath;
            bool isRoot;
            bool isWorktreeNode;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode))
            {
                return false;
            }

            if (isRoot || isWorktreeNode)
            {
                return true;
            }

            return Directory.Exists(fsPath);
        }

        protected override void GetItem(string path)
        {
            string fsPath;
            bool isRoot;
            bool isWorktreeNode;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode))
            {
                var ex = new ItemNotFoundException("Worktree path not found: " + path);
                WriteError(new ErrorRecord(ex, "WorktreePathNotFound", ErrorCategory.ObjectNotFound, path));
                return;
            }

            if (isRoot)
            {
                WriteItemObject(new { Name = "wt", IsRoot = true }, path, true);
                return;
            }

            if (Directory.Exists(fsPath))
            {
                WriteItemObject(new DirectoryInfo(fsPath), path, true);
                return;
            }

            if (File.Exists(fsPath))
            {
                WriteItemObject(new FileInfo(fsPath), path, false);
                return;
            }

            var missing = new ItemNotFoundException("Item not found: " + path);
            WriteError(new ErrorRecord(missing, "ItemNotFound", ErrorCategory.ObjectNotFound, path));
        }

        protected override void GetChildItems(string path, bool recurse, uint depth)
        {
            string fsPath;
            bool isRoot;
            bool isWorktreeNode;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode))
            {
                var ex = new ItemNotFoundException("Worktree path not found: " + path);
                WriteError(new ErrorRecord(ex, "WorktreePathNotFound", ErrorCategory.ObjectNotFound, path));
                return;
            }

            if (isRoot)
            {
                foreach (var wt in GetWorktrees())
                {
                    WriteItemObject(new
                    {
                        wt.Name,
                        wt.Path,
                        wt.Branch,
                        wt.CommitHash,
                        wt.IsDetached,
                        wt.IsPrunable,
                        wt.IsMain,
                    }, wt.Name, true);
                }
                return;
            }

            if (!Directory.Exists(fsPath))
            {
                return;
            }

            WriteDirectoryItems(fsPath, recurse, depth);
        }

        private void WriteDirectoryItems(string basePath, bool recurse, uint depth)
        {
            foreach (var dir in Directory.GetDirectories(basePath))
            {
                var directoryInfo = new DirectoryInfo(dir);
                WriteItemObject(directoryInfo, directoryInfo.FullName, true);
            }

            foreach (var file in Directory.GetFiles(basePath))
            {
                var fileInfo = new FileInfo(file);
                WriteItemObject(fileInfo, fileInfo.FullName, false);
            }

            if (!recurse)
            {
                return;
            }

            if (depth == 0)
            {
                return;
            }

            var nextDepth = depth == uint.MaxValue ? uint.MaxValue : depth - 1;
            foreach (var dir in Directory.GetDirectories(basePath))
            {
                WriteDirectoryItems(dir, true, nextDepth);
            }
        }

        protected override void GetChildNames(string path, ReturnContainers returnContainers)
        {
            string fsPath;
            bool isRoot;
            bool isWorktreeNode;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode))
            {
                return;
            }

            if (isRoot)
            {
                foreach (var wt in GetWorktrees())
                {
                    WriteItemObject(wt.Name, wt.Name, true);
                }
                return;
            }

            if (!Directory.Exists(fsPath))
            {
                return;
            }

            foreach (var dir in Directory.GetDirectories(fsPath))
            {
                WriteItemObject(new DirectoryInfo(dir).Name, dir, true);
            }

            if (returnContainers == ReturnContainers.ReturnAllContainers)
            {
                return;
            }

            foreach (var file in Directory.GetFiles(fsPath))
            {
                WriteItemObject(new FileInfo(file).Name, file, false);
            }
        }

        protected override bool HasChildItems(string path)
        {
            string fsPath;
            bool isRoot;
            bool isWorktreeNode;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode))
            {
                return false;
            }

            if (isRoot)
            {
                return GetWorktrees().Count > 0;
            }

            if (!Directory.Exists(fsPath))
            {
                return false;
            }

            return Directory.EnumerateFileSystemEntries(fsPath).Any();
        }

        protected override string MakePath(string parent, string child)
        {
            if (string.IsNullOrEmpty(parent))
            {
                return child ?? string.Empty;
            }

            if (string.IsNullOrEmpty(child))
            {
                return parent;
            }

            return parent.TrimEnd('\\') + "\\" + child.TrimStart('\\');
        }

        protected override string GetParentPath(string path, string root)
        {
            var normalized = NormalizePath(path);
            if (string.IsNullOrEmpty(normalized))
            {
                return string.Empty;
            }

            var index = normalized.LastIndexOf('\\');
            if (index < 0)
            {
                return string.Empty;
            }

            return normalized.Substring(0, index);
        }

        protected override string GetChildName(string path)
        {
            var normalized = NormalizePath(path);
            if (string.IsNullOrEmpty(normalized))
            {
                return string.Empty;
            }

            var index = normalized.LastIndexOf('\\');
            if (index < 0)
            {
                return normalized;
            }

            return normalized.Substring(index + 1);
        }

        protected override string NormalizeRelativePath(string path, string basePath)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return NormalizePath(basePath);
            }

            if (path.StartsWith("\\") || path.StartsWith("/"))
            {
                return NormalizePath(path);
            }

            var normalizedBase = NormalizePath(basePath);
            if (string.IsNullOrWhiteSpace(normalizedBase))
            {
                return NormalizePath(path);
            }

            return NormalizePath(normalizedBase + "\\" + path);
        }

        protected override bool IsValidPath(string path)
        {
            return path != null;
        }
    }
}
