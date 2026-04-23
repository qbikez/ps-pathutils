@{

    RootModule        = 'GitWorktrees.psm1'
    ModuleVersion     = '1.0.1'
    GUID              = 'f478d9cc-6f8d-4c8a-a0a4-1134fd274300'
    Author            = 'jakub.pawlowski'
    CompanyName       = 'Unknown'
    Copyright         = '(c) 2026 jakub.pawlowski. All rights reserved.'
    Description       = 'Git worktree provider and navigation helpers for PowerShell.'

    FunctionsToExport = '*'
    CmdletsToExport   = '*'
    VariablesToExport = '*'
    AliasesToExport   = '*'

    FileList          = @(
        'GitWorktrees.psd1',
        'GitWorktrees.psm1',
        'git-helpers.ps1',
        'lib/PathUtils.WtProvider.dll'
    )

    PrivateData       = @{
        PSData = @{
            Tags       = @("git", "worktree", "provider")
            ProjectUri = 'https://github.com/qbikez/ps-pathutils'
        }
    }
}


