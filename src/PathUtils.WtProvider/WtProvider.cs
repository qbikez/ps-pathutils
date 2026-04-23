using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Provider;

namespace PathUtils
{
    internal enum WorktreeErrorKind
    {
        GitCommandFailure,
        ParseFailure,
    }

    internal sealed class WorktreeRetrievalException : Exception
    {
        public WorktreeRetrievalException(WorktreeErrorKind kind, string message, Exception innerException = null) : base(message, innerException)
        {
            Kind = kind;
        }

        public WorktreeErrorKind Kind { get; }
    }

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
        private const string DebugEnvVarName = "PATHUTILS_WTPROVIDER_DEBUG";
        private static bool IsDebugEnabled()
        {
            var value = Environment.GetEnvironmentVariable(DebugEnvVarName);
            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }

            value = value.Trim();
            return value == "1" ||
                   value.Equals("true", StringComparison.OrdinalIgnoreCase) ||
                   value.Equals("yes", StringComparison.OrdinalIgnoreCase) ||
                   value.Equals("on", StringComparison.OrdinalIgnoreCase);
        }

        private static void WriteDebugLog(string message)
        {
            Console.Error.WriteLine("[WtProvider debug] " + message);
        }

        private static string RunGit(string workingDirectory, string arguments)
        {
            var debugEnabled = IsDebugEnabled();
            if (debugEnabled)
            {
                WriteDebugLog("executing command:");
                WriteDebugLog("cwd: " + workingDirectory);
                WriteDebugLog("git " + arguments);
            }

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

                if (debugEnabled)
                {
                    WriteDebugLog("exit code: " + process.ExitCode);
                    WriteDebugLog("stdout begin");
                    WriteDebugLog(stdout);
                    WriteDebugLog("stdout end");
                    WriteDebugLog("stderr begin");
                    WriteDebugLog(stderr);
                    WriteDebugLog("stderr end");
                }

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
            string repoRoot;
            try
            {
                repoRoot = RunGit(cwd, "rev-parse --show-toplevel");
            }
            catch (Exception ex)
            {
                throw new WorktreeRetrievalException(WorktreeErrorKind.GitCommandFailure, "Failed to locate git repository root.", ex);
            }

            repoRoot = System.IO.Path.GetFullPath(repoRoot);

            string output;
            try
            {
                output = RunGit(repoRoot, "worktree list --porcelain");
            }
            catch (Exception ex)
            {
                throw new WorktreeRetrievalException(WorktreeErrorKind.GitCommandFailure, "Failed to retrieve git worktree list.", ex);
            }

            var lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
            var list = new List<GitWorktreeInfo>();
            var unmatchedLines = new List<string>();
            GitWorktreeInfo current = null;

            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (trimmed.Length == 0)
                {
                    if (current != null)
                    {
                        if (!string.IsNullOrEmpty(current.Path) && !string.IsNullOrEmpty(current.CommitHash))
                        {
                            list.Add(current);
                        }
                        else
                        {
                            unmatchedLines.Add(line);
                        }

                        current = null;
                    }
                    continue;
                }

                if (trimmed.StartsWith("worktree ", StringComparison.Ordinal))
                {
                    if (current != null)
                    {
                        if (!string.IsNullOrEmpty(current.Path) && !string.IsNullOrEmpty(current.CommitHash))
                        {
                            list.Add(current);
                        }
                        else
                        {
                            unmatchedLines.Add(trimmed);
                        }
                    }

                    var path = trimmed.Substring("worktree ".Length);
                    string fullPath;
                    string name;
                    try
                    {
                        fullPath = System.IO.Path.GetFullPath(path);
                        name = new DirectoryInfo(fullPath).Name;
                    }
                    catch (Exception ex)
                    {
                        throw new WorktreeRetrievalException(WorktreeErrorKind.ParseFailure, "Failed to parse git worktree output.", ex);
                    }

                    var gitDirPath = System.IO.Path.Combine(fullPath, ".git");
                    var isMain = Directory.Exists(gitDirPath);

                    current = new GitWorktreeInfo
                    {
                        Name = name,
                        Path = fullPath,
                        IsMain = isMain,
                        IsDetached = false,
                        IsPrunable = false,
                    };

                    continue;
                }

                if (current == null)
                {
                    unmatchedLines.Add(trimmed);
                    continue;
                }

                if (trimmed.StartsWith("HEAD ", StringComparison.Ordinal))
                {
                    current.CommitHash = trimmed.Substring("HEAD ".Length);
                    continue;
                }

                if (trimmed.StartsWith("branch ", StringComparison.Ordinal))
                {
                    var branchRef = trimmed.Substring("branch ".Length);
                    const string branchPrefix = "refs/heads/";
                    current.Branch = branchRef.StartsWith(branchPrefix, StringComparison.Ordinal)
                        ? branchRef.Substring(branchPrefix.Length)
                        : branchRef;
                    continue;
                }

                if (string.Equals(trimmed, "detached", StringComparison.Ordinal))
                {
                    current.IsDetached = true;
                    current.Branch = null;
                    continue;
                }

                if (trimmed.StartsWith("prunable", StringComparison.Ordinal))
                {
                    current.IsPrunable = true;
                    current.Branch = null;
                    continue;
                }

                if (trimmed.StartsWith("locked", StringComparison.Ordinal) ||
                    trimmed.StartsWith("bare", StringComparison.Ordinal))
                {
                    // Valid porcelain metadata not currently modeled.
                    continue;
                }

                unmatchedLines.Add(trimmed);
            }

            if (current != null)
            {
                if (!string.IsNullOrEmpty(current.Path) && !string.IsNullOrEmpty(current.CommitHash))
                {
                    list.Add(current);
                }
                else
                {
                    unmatchedLines.Add("incomplete worktree entry");
                }
            }

            if (unmatchedLines.Count > 0)
            {
                var sample = string.Join("; ", unmatchedLines.Where(l => !string.IsNullOrWhiteSpace(l)).Take(2));
                throw new WorktreeRetrievalException(
                    WorktreeErrorKind.ParseFailure,
                    "Failed to parse git worktree output. Unrecognized lines: " + sample);
            }

            return list;
        }

        private bool TryGetWorktrees(out List<GitWorktreeInfo> worktrees, out WorktreeRetrievalException error)
        {
            worktrees = null;
            error = null;

            try
            {
                worktrees = GetWorktrees();
                return true;
            }
            catch (WorktreeRetrievalException ex)
            {
                error = ex;
                return false;
            }
            catch (Exception ex)
            {
                error = new WorktreeRetrievalException(WorktreeErrorKind.GitCommandFailure, "Unexpected error while retrieving git worktrees.", ex);
                return false;
            }
        }

        private void WriteWorktreeRetrievalError(WorktreeRetrievalException ex, object targetObject)
        {
            var errorId = ex.Kind == WorktreeErrorKind.ParseFailure ? "GitWorktreeParseFailed" : "GitWorktreeCommandFailed";
            var category = ex.Kind == WorktreeErrorKind.ParseFailure ? ErrorCategory.ParserError : ErrorCategory.InvalidOperation;
            var message = ex.InnerException == null ? ex.Message : ex.Message + " " + ex.InnerException.Message;
            var wrapped = new InvalidOperationException(message, ex);
            WriteError(new ErrorRecord(wrapped, errorId, category, targetObject));
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

        private bool TryResolveFileSystemPath(string path, out string resolvedPath, out bool isRoot, out bool isWorktreeNode, out bool hadWorktreeError)
        {
            resolvedPath = null;
            isRoot = false;
            isWorktreeNode = false;
            hadWorktreeError = false;

            var normalized = NormalizePath(path);
            if (string.IsNullOrEmpty(normalized))
            {
                isRoot = true;
                return true;
            }

            List<GitWorktreeInfo> worktrees;
            WorktreeRetrievalException worktreeError;
            if (!TryGetWorktrees(out worktrees, out worktreeError))
            {
                WriteWorktreeRetrievalError(worktreeError, path);
                hadWorktreeError = true;
                return false;
            }

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
                bool hadWorktreeError;
                if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode, out hadWorktreeError))
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
            bool hadWorktreeError;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode, out hadWorktreeError))
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
            bool hadWorktreeError;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode, out hadWorktreeError))
            {
                if (hadWorktreeError)
                {
                    return;
                }

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
            bool hadWorktreeError;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode, out hadWorktreeError))
            {
                if (hadWorktreeError)
                {
                    return;
                }

                var ex = new ItemNotFoundException("Worktree path not found: " + path);
                WriteError(new ErrorRecord(ex, "WorktreePathNotFound", ErrorCategory.ObjectNotFound, path));
                return;
            }

            if (isRoot)
            {
                List<GitWorktreeInfo> worktrees;
                WorktreeRetrievalException worktreeError;
                if (!TryGetWorktrees(out worktrees, out worktreeError))
                {
                    WriteWorktreeRetrievalError(worktreeError, path);
                    return;
                }

                foreach (var wt in worktrees)
                {
                    WriteItemObject(wt, wt.Name, true);
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
            bool hadWorktreeError;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode, out hadWorktreeError))
            {
                return;
            }

            if (isRoot)
            {
                List<GitWorktreeInfo> worktrees;
                WorktreeRetrievalException worktreeError;
                if (!TryGetWorktrees(out worktrees, out worktreeError))
                {
                    WriteWorktreeRetrievalError(worktreeError, path);
                    return;
                }

                foreach (var wt in worktrees)
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
            bool hadWorktreeError;
            if (!TryResolveFileSystemPath(path, out fsPath, out isRoot, out isWorktreeNode, out hadWorktreeError))
            {
                return false;
            }

            if (isRoot)
            {
                List<GitWorktreeInfo> worktrees;
                WorktreeRetrievalException worktreeError;
                if (!TryGetWorktrees(out worktrees, out worktreeError))
                {
                    WriteWorktreeRetrievalError(worktreeError, path);
                    return false;
                }

                return worktrees.Count > 0;
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
