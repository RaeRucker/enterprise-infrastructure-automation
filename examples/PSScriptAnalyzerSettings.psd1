# Settings for examples/ only. New-ExampleOutput.ps1 defines stub functions that must
# keep the exact signatures of the module's private wrappers (so the real public
# functions can call them); most stub parameters are therefore intentionally unused,
# and the computer names are fictional fixtures.
@{
    ExcludeRules = @(
        'PSReviewUnusedParameter'
        'PSAvoidUsingComputerNameHardcoded'
    )
}
