# Settings for tests/ only. src/ is analyzed with the default rule set.
@{
    ExcludeRules = @(
        # Pester assigns variables in BeforeAll that are read in It blocks; the analyzer
        # can't see across those script blocks (documented false positive).
        'PSUseDeclaredVarsMoreThanAssignments'
        # Tests pass fictional server names (SRV-APP01) on purpose; they are fixtures.
        'PSAvoidUsingComputerNameHardcoded'
        # Test-only helpers like New-Stale build fixture objects; they change no system state.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
