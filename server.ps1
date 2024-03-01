Import-Module "/usr/local/share/powershell/Modules/SQLite/PSSQLite.psm1"
Import-Module "/database.psm1"

# Algumas variáveis para ajudar a configurar o servidor
$port = $env:PORT

$databasePath = "/app/data/database.db"
$scriptPath = "/app/scripts/init.sql"
$tabelas = @("clientes", "transacoes", "saldos")
$tabelasValidas = 0


class Database {
    [string] $databasePath = "/app/data/database.db"
    [int] $maxPoolSize = 200
    [System.Collections.Generic.List[object]] $connectionPool

    Database() {
        $this.connectionPool = [System.Collections.Generic.List[object]]::new()

        # Inicializa o pool de conexão
        for ($i = 0; $i -lt $this.maxPoolSize; $i++) {
            $connection = New-SQLiteConnection -DataSource $this.databasePath
            $this.connectionPool.Add($connection)
        }
        $this.SetJournalModeWAL()
        $this.SetSynchronousNormal()
        $this.SetBusyTimeout(15000)
    }
    [void] SetJournalModeWAL() {
        $query = "PRAGMA journal_mode = WAL;"
        foreach ($conn in $this.connectionPool) {
            $command = $conn.CreateCommand()
            $command.CommandText = $query
            $command.ExecuteNonQuery()
        }
    }
    [void] SetBusyTimeout($timeout) {
        $query = "PRAGMA busy_timeout = $timeout;"
        foreach ($conn in $this.connectionPool) {
            $command = $conn.CreateCommand()
            $command.CommandText = $query
            $command.ExecuteNonQuery()
        }
    }
    [void] SetSynchronousNormal() {
        $query = "PRAGMA synchronous = NORMAL;"
        foreach ($conn in $this.connectionPool) {
            $command = $conn.CreateCommand()
            $command.CommandText = $query
            $command.ExecuteNonQuery()
        }
    }
    [object] GetConnectionFromPool() {
        foreach ($conn in $this.connectionPool) {
            if ($conn.State -eq 'Open') {
                return $conn
            }
        }

        # Se não houver conexões disponíveis no pool, cria uma nova
        $connection = New-SQLiteConnection -DataSource $this.databasePath
        $this.connectionPool.Add($connection)
        return $connection
    }

    [bool] isClient($id) {
        $sqlQuery = "SELECT id FROM clientes WHERE id = $id;"
        $selectedRecord = Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
        if($selectedRecord){
            return $true
        }
        return $false
    }

    [object] getClient($id) {
        $sqlQuery = "SELECT nome, limite FROM clientes WHERE id = ${id};"
        $cliente = Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
        return $cliente
    }

    [object] getSaldo($id) {
        $sqlQuery = "SELECT valor FROM saldos WHERE cliente_id = ${id};"
        $saldo = Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
        return $saldo
    }

    [void] updateSaldo($id, $saldo) {
        $sqlQuery = "UPDATE saldos SET valor = $saldo WHERE cliente_id = $id;"
        Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
    }

    [void] saveTransacao($id, $valor, $tipo, $descricao) {
        $sqlQuery = "INSERT INTO transacoes (cliente_id, valor, tipo, descricao, realizada_em) VALUES ($id, $valor, '$tipo', '$descricao', datetime('now'));"
        Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
    }

    [object] getTransacoes($id) {
        $sqlQuery = "SELECT valor, tipo, descricao, realizada_em FROM transacoes WHERE cliente_id = $id ORDER BY realizada_em DESC LIMIT 10;"
        $transacoes = Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
        return $transacoes
    }

    [object] getExtrato($id) {
        $sqlQuery = "SELECT c.limite as limite, datetime('now', 'localtime') as data_extrato, s.valor as total 
        FROM clientes c 
        JOIN saldos s on c.id = s.cliente_id 
        WHERE c.id = $id;"
        $transacoes = Invoke-SqliteQuery -Query $sqlQuery -SQLiteConnection $this.GetConnectionFromPool()
        return $transacoes
    }

    [void] BeginTransaction() {
        $connection = $this.GetConnectionFromPool()
        Invoke-SqliteQuery -Query "BEGIN EXCLUSIVE;" -SQLiteConnection $connection
    }

    [void] CommitTransaction() {
        $connection = $this.GetConnectionFromPool()
        Invoke-SqliteQuery -Query "COMMIT;" -SQLiteConnection $connection
    }

    [void] RollbackTransaction() {
        $connection = $this.GetConnectionFromPool()
        Invoke-SqliteQuery -Query "ROLLBACK;" -SQLiteConnection $connection
    }

    # Fecha todas as conexões no pool
    [void] CloseConnection() {
        foreach ($conn in $this.connectionPool) {
            $conn.Close()
        }
    }
}

# Verificar se o banco de dados existe
if($env:MIGRATE){
    Check-Database -databasePath $databasePath -scriptPath $scriptPath -tabelas $tabelas -tabelasValidas $tabelasValidas
}

# Função para Processar as transações
function Processar-Transacao {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [System.Net.HttpListenerResponse]$Response,
        [Database]$database
    )
    $url = $Request.RawUrl.Split("/")
    $IdDoCliente = $url[-2]
   
    if($IdDoCliente -gt 5) {
        $Response.StatusCode = 404
        $Response.StatusDescription = "Not Found"
        return $Response.Close()
    }

    $database.BeginTransaction()
    $isCliente = $database.isClient($IdDoCliente)
    Write-Host $isCliente
    if(!$isCliente){
        $database.RollbackTransaction();
        $Response.StatusCode = 404
        $Response.StatusDescription = "Not Found"
        return $Response.Close()
    }
    $body = $request.InputStream
    $streamReader = New-Object System.IO.StreamReader($body, [System.Text.Encoding]::UTF8)
    $json = $streamReader.ReadToEnd()
    $streamReader.Close()

    # Converter o JSON em objeto PowerShell
    $transacao = ConvertFrom-Json $json
    $integerNumber = 0
    Write-Host $transacao
    $isInt = [int]::TryParse($transacao.valor, [ref]$integerNumber)
    $valor = $transacao.valor
    Write-Host $isInt
    if ($isInt) {
       $valor = $integerNumber
    } else {
        $database.RollbackTransaction();
        Write-Host "Valor inválido"
        $Response.StatusCode = 422
        $Response.StatusDescription = "Unprocessable Entity"
        return $Response.Close()
    }
    if ($valor -le 0) {
        $database.RollbackTransaction();
        Write-Host "Valor inválido"
        $Response.StatusCode = 422
        $Response.StatusDescription = "Unprocessable Entity"
        return $Response.Close()
    }
    
    if($transacao.tipo -notin @('c', 'd')) {
        $database.RollbackTransaction();
        Write-Host "Tipo inválido"
        $Response.StatusCode = 422
        $Response.StatusDescription = "Unprocessable Entity"
        return $Response.Close()
    }
    
    if($transacao.descricao.Length -gt 10 -or $transacao.descricao -eq "" -or $transacao.descricao -eq $null){
        $database.RollbackTransaction();
        Write-Host "Descrição inválida"
        $Response.StatusCode = 422
        $Response.StatusDescription = "Unprocessable Entity"
        return $Response.Close()
    }
    $novoSaldo = 0;
    $cliente = $database.getClient($IdDoCliente)
    $saldo = $database.getSaldo($IdDoCliente)
    Write-Host $cliente
    Write-Host $saldo
    $novoSaldo = $saldo.valor + $valor
    Write-Host $novoSaldo
    if($transacao.tipo -eq 'd'){
        $novoSaldo = $saldo.valor - $valor
        if($novoSaldo -lt -$cliente.limite){
            $database.RollbackTransaction();
            $Response.StatusCode = 422
            $Response.StatusDescription = "Unprocessable Entity"
            return $Response.Close()
        }
    }
    $database.updateSaldo($IdDoCliente, $novoSaldo)
    $database.saveTransacao($IdDoCliente, $valor, $transacao.tipo, $transacao.descricao)
    $responseJson = @{
        limite = $cliente.limite
        saldo = $novoSaldo
    } | ConvertTo-Json
    
    # Configurar o status de resposta (200 OK)
    $Response.StatusCode = 200
    $Response.StatusDescription = "OK"
    $Response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($responseJson), 0, $responseJson.Length)
    $database.CommitTransaction();
    # Fechar o OutputStream
    return $Response.Close()
}
function Gerar-Extrato {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [System.Net.HttpListenerResponse]$Response,
        [Database]$database
    )
    $url = $Request.RawUrl.Split("/")
    $IdDoCliente = $url[-2]
    if($IdDoCliente -gt 5) {
        $Response.StatusCode = 404
        $Response.StatusDescription = "Not Found"
        return $Response.Close()
    }
    Write-Host $url
    $database.BeginTransaction()
    $isCliente = $database.isClient($IdDoCliente)
    Write-Host $isCliente
    if(!$isCliente){
        $database.RollbackTransaction();
        $Response.StatusCode = 404
        $Response.StatusDescription = "Not Found"
        return $Response.Close()
    }

    $transacoes = $database.getTransacoes($IdDoCliente)
    $saldo = $database.getExtrato($IdDoCliente)
    Write-Host $saldo
    Write-Host $transacoes
    $database.CommitTransaction();

    $transacoesList = foreach ($row in $transacoes) {
        @{
            valor = $row.valor_transacao
            tipo = $row.tipo_transacao
            descricao = $row.descricao_transacao
            realizada_em = $row.data_transacao
        }
    }

    # Formatar os resultados como JSON
    $jsonResult = @{
        saldo = @{
            total = $saldo.total
            data_extrato = $saldo.data_extrato
            limite = $saldo.limite
        }
        ultimas_transacoes = $transacoes
    } | ConvertTo-Json
     # Definir o cabeçalho de resposta
     $response.StatusCode = 200
     $response.ContentType = "application/json"
     # Escrever os resultados na resposta
     $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($jsonResult), 0, $jsonResult.Length)

    # Configurar o status de resposta (200 OK)
    $Response.StatusCode = 200
    $Response.StatusDescription = "OK"

    # Fechar o OutputStream
    return $Response.Close()
}

$patternRouteTx = "\/clientes\/(\d+)\/transacoes$"
$patternRouteExtrato = "\/clientes\/(\d+)\/extrato$"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://*:$port/")
# Inicia o listener
$listener.Start()

Write-Host "Servidor web iniciado. Aguardando requisições..."

try {
    $database = [Database]::new()
    while ($true) {
        # Aguarda de forma assíncrona por uma requisição
        $context = $listener.GetContext()

        # Obtém a requisição e a resposta do contexto
        $request = $context.Request
        $response = $context.Response
        Write-Host "Requisição recebida: $($request.HttpMethod) $($request.Url.AbsolutePath)"
        # Verifique se a URL da requisição corresponde ao padrão
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match $patternRouteTx) {
            # Se corresponder, processe a transação
            Write-Host "Processando transação..."
            Processar-Transacao $request $response $database
        }
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match $patternRouteExtrato) {
            # Se corresponder, processe a transação
            Write-Host "Gerando Extrato..."
            Gerar-Extrato $request $response $database
        }
    }
}
finally {
    # Certifica-se de que o listener seja fechado adequadamente
    $listener.Stop()
    $listener.Close()
}