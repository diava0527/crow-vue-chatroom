# 发布打包：把编译产物、MySQL 运行库、VC++ 运行库、前端产物组装成可分发的 zip。
# 注意：本脚本只负责“打出一个 zip”，不启动服务、不连数据库、不提交 git、不打 tag。
# 用法：
#   标准流程：./release.ps1 -Version v1.0.0
#   已编译过、只想重新组装：./release.ps1 -Version v1.0.0 -SkipBuild
#   MySQL 装在别处：./release.ps1 -Version v1.0.0 -MysqlRootDir "D:\MySQL"

param(
    [string]$Version = 'v1.0.0',
    [string]$Config = 'Release',
    [string]$MysqlRootDir = 'C:\Program Files\MySQL\MySQL Server 8.0',
    [switch]$SkipBuild,
    [switch]$SkipFrontendCheck
)

$ErrorActionPreference = 'Stop'
$projectDirectory = $PSScriptRoot
$packageName = "crow-vue-chatroom-$Version-win-x64"
$releaseRoot = Join-Path $projectDirectory 'out\release'
$stagePath = Join-Path $releaseRoot $packageName
$zipPath = Join-Path $releaseRoot "$packageName.zip"

$validConfigs = @('Release', 'RelWithDebInfo')
if ($Config -notin $validConfigs) {
    throw "发布包只支持 $($validConfigs -join ' / ')，当前：$Config"
}

# 1. 版本号必须是 vX.Y.Z，避免把 tag 打歪
if ($Version -notmatch '^v\d+\.\d+\.\d+$') {
    throw "版本号格式应为 vX.Y.Z，当前：$Version"
}

# 2. 编译（默认 Release，产物目录里不带 PDB）
if (!$SkipBuild) {
    Write-Host "编译发布版本：build.ps1 -Config $Config"
    & (Join-Path $projectDirectory 'build.ps1') -Config $Config
}

$exePath = Join-Path $projectDirectory "out\build\app\$Config\browser_chatroom_architecture.exe"
if (!(Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "未找到编译产物：$exePath（先执行 ./build.ps1 -Config $Config）"
}

# 3. 前置检查：缺少任何一项都直接报错，避免打出跑不起来的包
$mysqlClientDll = Join-Path $MysqlRootDir 'lib\libmysql.dll'
$mysqlSslDll = Join-Path $MysqlRootDir 'bin\libssl-3-x64.dll'
$mysqlCryptoDll = Join-Path $MysqlRootDir 'bin\libcrypto-3-x64.dll'
foreach ($file in @($mysqlClientDll, $mysqlSslDll, $mysqlCryptoDll)) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "缺少 MySQL 运行库：$file（请安装 MySQL Server 8.0，或用 -MysqlRootDir 指定安装目录）"
    }
}
if (!$SkipFrontendCheck -and !(Test-Path -LiteralPath (Join-Path $projectDirectory 'frontend\index.html'))) {
    throw '缺少前端产物 frontend/index.html，先在 chatroom-app 下执行 npm run build:backend。'
}
foreach ($file in @('LICENSE', 'start-backend.ps1', '.env.example', 'README.md')) {
    if (!(Test-Path -LiteralPath (Join-Path $projectDirectory $file))) {
        throw "缺少发布必需文件：$file"
    }
}

# 4. VC++ 运行库：exe 动态链接 MSVCP140/VCRUNTIME140，随包分发才能免装运行库
$crtFiles = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$crtSource = Get-ChildItem -Path 'C:\Program Files\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT' `
    -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Parent.Parent.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Parent.Parent.Name } -Descending |
    Select-Object -First 1
if ($crtSource) {
    $crtMissing = @($crtFiles | Where-Object { !(Test-Path -LiteralPath (Join-Path $crtSource.FullName $_)) })
    if ($crtMissing.Count -gt 0) {
        Write-Warning "VC++ 运行库目录缺少：$($crtMissing -join ', ')，包内将不含这些 DLL"
        $crtSource = $null
    }
} else {
    Write-Warning '未找到 VC++ 运行库目录，包内不含 MSVCP140/VCRUNTIME140；目标机器需自行安装 VC++ 2015-2022 x64 运行库。'
}

# 5. 组装发布目录（只写 out\release，已被 .gitignore 忽略）
if (Test-Path -LiteralPath $stagePath) {
    Remove-Item -LiteralPath $stagePath -Recurse -Force
}
New-Item -ItemType Directory -Path $stagePath -Force | Out-Null

Copy-Item -LiteralPath $exePath -Destination $stagePath
Copy-Item -LiteralPath @($mysqlClientDll, $mysqlSslDll, $mysqlCryptoDll) -Destination $stagePath
if ($crtSource) {
    foreach ($name in $crtFiles) {
        Copy-Item -LiteralPath (Join-Path $crtSource.FullName $name) -Destination $stagePath
    }
}
Copy-Item -LiteralPath (Join-Path $projectDirectory 'frontend') -Destination $stagePath -Recurse
foreach ($file in @('start-backend.ps1', '.env.example', 'README.md', 'LICENSE')) {
    Copy-Item -LiteralPath (Join-Path $projectDirectory $file) -Destination $stagePath
}

$quickStart = @'
网络聊天室 Windows 预编译包
============================

1. 先装 MySQL 8.0（只需一次），并建库和账号：
   CREATE DATABASE IF NOT EXISTS chatroom CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
   CREATE USER IF NOT EXISTS 'chat_app'@'127.0.0.1' IDENTIFIED BY '你的密码';
   GRANT ALL PRIVILEGES ON chatroom.* TO 'chat_app'@'127.0.0.1';
   FLUSH PRIVILEGES;

2. 在本目录打开 PowerShell（资源管理器地址栏输入 pwsh 回车），执行：
   ./start-backend.ps1

3. 按提示输入 MySQL 密码（输入时不显示字符），然后浏览器打开：
   http://localhost:8080/

说明：
- 首次启动会自动建表，看到日志里数据库连接成功即可。
- 想省掉每次输入密码，可把 .env.example 复制成 .env 并填写 DB_PASSWORD。
- 完整文档见同目录 README.md。
'@
Set-Content -LiteralPath (Join-Path $stagePath '快速开始.txt') -Value $quickStart -Encoding utf8

# 6. 压缩（保留顶层目录，解压后是一个完整文件夹）
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Write-Host "压缩：$zipPath"
Compress-Archive -Path $stagePath -DestinationPath $zipPath -CompressionLevel Optimal

# 7. 输出摘要
$zipSize = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
$stageSize = [math]::Round(((Get-ChildItem -LiteralPath $stagePath -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash

Write-Host ''
Write-Host "发布包：$zipPath"
Write-Host "解压后：$stageSize MB / 压缩后：$zipSize MB"
Write-Host "SHA256：$hash"
Write-Host ''
Write-Host '下一步：解压到临时目录试跑一次；确认无误后打 tag 并在 GitHub 网页上传这个 zip。'