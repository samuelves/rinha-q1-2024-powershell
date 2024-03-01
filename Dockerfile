# Use uma imagem do PowerShell como base
FROM mcr.microsoft.com/powershell

# Copie o script PowerShell para dentro do contêiner
COPY server.ps1 /server.ps1
COPY database.psm1 /database.psm1
COPY ./scripts/init.sql /app/scripts/init.sql
#RUN pwsh -Command "Install-Module -Name SQLite -Force -AllowClobber"
# Baixe o arquivo SQLite.zip usando Invoke-WebRequest
RUN pwsh -Command "Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2/package/PSSQLite' -OutFile 'SQLite.zip'"

RUN pwsh -Command "Expand-Archive -Path 'SQLite.zip' -DestinationPath '/usr/local/share/powershell/Modules/SQLite'"


# Exponha a porta 8080 para o servidor
EXPOSE 8080
EXPOSE 8081

# Execute o script PowerShell quando o contêiner for iniciado
CMD ["pwsh", "/server.ps1"]
