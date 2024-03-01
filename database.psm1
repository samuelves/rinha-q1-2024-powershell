Import-Module "/usr/local/share/powershell/Modules/SQLite/PSSQLite.psm1"

function Check-Database {
  param (
    [string]$databasePath,
    [string]$scriptPath,
    [array]$tabelas,
    [int]$tabelasValidas
  )
  if (Test-Path $databasePath) {
    Write-Output "O arquivo SQLite já existe."
    $tabelas = @("clientes", "transacoes", "saldos")

    # Loop através das tabelas
    foreach ($tabela in $tabelas) {
      # Consulta SQL para verificar a existência da tabela na tabela sqlite_master
      $query = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$tabela';"

      # Executar a consulta
      $resultado = Invoke-SQLiteQuery -DataSource $databasePath -Query $query

      # Acessar o valor real retornado pela consulta
      $count = $resultado.'COUNT(*)'

      # Verificar o resultado
      if ($count -gt 0) {
        Write-Output "A tabela '$tabela' existe no banco de dados."
        $tabelasValidas++
      } else {
        Write-Output "A tabela '$tabela' não existe no banco de dados."
      }
    }
    if ($tabelasValidas -eq 3) {
      Write-Output "O banco de dados está pronto para uso."
    } else {
      Write-Output "O banco de dados não está pronto para uso."
      $data = Get-Content -Path $scriptPath -Raw
      Invoke-SqliteQuery -DataSource $databasePath -Query $data
    }
  } else {
    # Criar o arquivo SQLite
    New-Item -Path $databasePath -ItemType File
    Write-Output "Arquivo SQLite criado com sucesso."
    $data = Get-Content -Path $scriptPath -Raw
    Invoke-SqliteQuery -DataSource $databasePath -Query $data
  }
}

Export-ModuleMember -Function Check-Database