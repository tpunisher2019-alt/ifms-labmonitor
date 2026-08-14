# Contrato reservado para uma versão futura. Este arquivo não instala hooks,
# não observa teclado e não coleta a janela ativa na versão 1.
function Start-LmForegroundProvider {
    param([scriptblock]$OnForegroundChanged)
    return $null
}

function Stop-LmForegroundProvider {
    param($ProviderHandle)
}

