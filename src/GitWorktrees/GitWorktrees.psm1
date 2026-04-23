. (Join-Path $PSScriptRoot "git-helpers.ps1")

$formatFile = Join-Path $PSScriptRoot "GitWorktrees.format.ps1xml"
if (Test-Path -LiteralPath $formatFile) {
    Update-FormatData -PrependPath $formatFile -ErrorAction SilentlyContinue
}
