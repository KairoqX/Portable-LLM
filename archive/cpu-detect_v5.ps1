$ErrorActionPreference = 'Stop'

# Windows processor-feature IDs: 39 = AVX, 40 = AVX2.
# This reports OS-enabled CPU support; it does not inspect the executable's build flags.
try {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CpuFeatureCheck {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool IsProcessorFeaturePresent(int feature);
}
'@ -ErrorAction SilentlyContinue

    if ([CpuFeatureCheck]::IsProcessorFeaturePresent(40)) {
        'AVX2'
    }
    elseif ([CpuFeatureCheck]::IsProcessorFeaturePresent(39)) {
        'AVX'
    }
    else {
        'BASELINE'
    }
}
catch {
    'UNKNOWN'
}
