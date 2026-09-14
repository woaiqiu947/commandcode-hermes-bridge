#requires -version 5
<#
  CommandCode bridge 一键自检（Windows / PowerShell）

  用法:
    powershell -ExecutionPolicy Bypass -File platforms\pc\doctor.ps1
    powershell -ExecutionPolicy Bypass -File platforms\pc\doctor.ps1 -BridgeDir C:\Users\me\commandcode-bridge
    powershell -ExecutionPolicy Bypass -File platforms\pc\doctor.ps1 -Base http://127.0.0.1:9992

  逐层检查 bridge 是否可用，并在结尾给出结论。配套文档:
    docs/TROUBLESHOOTING-CONNECTION.md

  安全: 只打印 key 的“有值/长度”，绝不打印 key 本身。
  编码: 本文件必须存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会乱码。
#>
param(
  [string]$Base      = "http://127.0.0.1:9992",
  [string]$BridgeDir = (Join-Path $env:USERPROFILE "commandcode-bridge")
)

$EnvFile  = Join-Path $BridgeDir ".env"
$Problems = 0

function Ok($m)   { Write-Host "  [+] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [x] $m" -ForegroundColor Red }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Hr       { Write-Host ("-" * 60) }

function Get-EnvVal([string]$key) {
  if (-not (Test-Path $EnvFile)) { return "" }
  $hit = Select-String -Path $EnvFile -Pattern ("^" + [regex]::Escape($key) + "=") -ErrorAction SilentlyContinue |
         Select-Object -First 1
  if (-not $hit) { return "" }
  return $hit.Line.Substring($hit.Line.IndexOf('=') + 1).Trim()
}
function ShotLen($val, $label) {
  if ($val) { Ok ("{0} 已设置（长度 {1}）" -f $label, $val.Length) }
  else      { Bad ("{0} 缺失/为空" -f $label); $script:Problems++ }
}

Write-Host "CommandCode bridge 自检" -ForegroundColor White
Write-Host "bridge 接口: $Base"
Write-Host "bridge 目录: $BridgeDir"
Write-Host "env  文件  : $EnvFile"
Hr

# ---------- (1) bridge 活着吗 ----------
Write-Host "[1] bridge 是否在监听"
$Health = $null
$HealthErr = ""
try {
  $Health = Invoke-RestMethod -Uri "$Base/health" -TimeoutSec 10 -ErrorAction Stop
} catch {
  $Health = $null
  $HealthErr = $_.Exception.Message
}
$Ver = ""
if ($Health) {
  $Ver = [string]$Health.version
  Ok ("bridge 存活（version={0}）" -f $(if ($Ver) { $Ver } else { "?" }))
  Warn ("终端服务 upstream = " + [string]$Health.upstream)
} else {
  Bad ("连不上 {0} -- bridge 没运行{1}" -f $Base, $(if ($HealthErr) { "（错误: ${HealthErr}）" } else { "" }))
  Warn "查任务计划: Get-ScheduledTask -TaskName CommandCodeBridgeWatchdog | Get-ScheduledTaskInfo"
  Warn "查进程:     Get-Process node -ErrorAction SilentlyContinue | Select Id,Path"
  Warn "见 TROUBLESHOOTING-CONNECTION.md 第 1 层"
  $Problems++
}
Hr

# ---------- (2) 上游 key 配置了吗 ----------
Write-Host "[2] .env 的上游 COMMANDCODE_API_KEY"
if ($Health) {
  $cfg = [string]$Health.auth.commandcode_api_key_configured
  if ($cfg -eq "True" -or $cfg -eq "true") { Ok "/health 报告 commandcode_api_key_configured=true" }
  else { Bad ("/health 报告 commandcode_api_key_configured={0} -- 上游 key 没被 bridge 读到" -f $cfg); $Problems++ }
}
ShotLen (Get-EnvVal 'COMMANDCODE_API_KEY') 'COMMANDCODE_API_KEY'
Hr

# ---------- (3) 本地访问 key 是否两端一致 ----------
Write-Host "[3] 本地访问 key（bridge 的 BRIDGE_API_KEY <-> 客户端的 COMMANDCODE_BRIDGE_API_KEY）"
$BKey = Get-EnvVal 'BRIDGE_API_KEY'
ShotLen $BKey 'bridge 侧 BRIDGE_API_KEY'

# 客户端 key: 先看进程环境变量, 再看 Hermes 私有 env
$CKey = $env:COMMANDCODE_BRIDGE_API_KEY
$Src  = "环境变量"
if (-not $CKey) {
  $hermesEnv = $null
  try { $hermesEnv = (& hermes config env-path 2>$null | Select-Object -First 1) } catch { $hermesEnv = $null }
  if ([string]::IsNullOrWhiteSpace([string]$hermesEnv)) {
    $hermesEnv = Join-Path $env:LOCALAPPDATA "hermes\.env"
  }
  if (Test-Path $hermesEnv) {
    $hit = Select-String -Path $hermesEnv -Pattern '^COMMANDCODE_BRIDGE_API_KEY=' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { $CKey = $hit.Line.Substring($hit.Line.IndexOf('=') + 1).Trim(); $Src = $hermesEnv }
  }
}
if ($CKey) {
  if ($BKey -and ($CKey -eq $BKey)) { Ok ("客户端 COMMANDCODE_BRIDGE_API_KEY 与 bridge 一致（来源: {0}）" -f $Src) }
  else { Bad ("客户端 key 与 bridge 的 BRIDGE_API_KEY 不一致（会导致每次 401）（来源: {0}）" -f $Src); $Problems++ }
} else {
  Warn "未找到客户端 COMMANDCODE_BRIDGE_API_KEY（环境变量 / Hermes env 都没有）-- 见手册第 4 节"
}
Hr

# ---------- (4) 版本一致性 ----------
Write-Host "[4] 版本一致性（COMMANDCODE_CLI_VERSION <-> bridge 版本）"
$CliVer = Get-EnvVal 'COMMANDCODE_CLI_VERSION'
if ($CliVer) {
  $a = [string]$Ver   -replace '\.a$',''
  $b = [string]$CliVer -replace '\.a$',''
  if ($Ver -and ($a -eq $b)) { Ok ("CLI_VERSION=$CliVer 与 bridge=$Ver 一致") }
  else { Warn ("CLI_VERSION={0} 与 bridge={1} 不一致 -- 见文档第 4 层" -f $CliVer, $(if ($Ver) { $Ver } else { "?" })) }
} else {
  Warn ".env 没有 COMMANDCODE_CLI_VERSION（Windows 精简模板早期不含此项，建议与 bridge 版本一致）"
}
Hr

# ---------- (5) 模型目录 + 凭证并发 ----------
Write-Host "[5] 模型目录（/v1/models）与凭证"
if ($BKey) {
  $models = $null
  $MErr = ""
  try {
    $models = Invoke-RestMethod -Uri "$Base/v1/models" -Headers @{ Authorization = "Bearer $BKey" } -TimeoutSec 15 -ErrorAction Stop
  } catch {
    $models = $null
    $MErr = $_.Exception.Message
  }
  if ($models) {
    $cnt = @($models.data).Count
    if ($cnt -gt 0) { Ok "/v1/models 返回 $cnt 个模型" }
    else { Warn "/v1/models 返回 0 个模型 -- 见手册 5.1 节" }
  } else {
    Bad ("/v1/models 拿不到数据{0}（key 不对会 401）" -f $(if ($MErr) { "（错误: ${MErr}）" } else { "" })); $Problems++
  }
}
if ($Health) {
  Warn ("凭证数 credential_count = " + [string]$Health.auth.commandcode_credential_count)
  Warn ("每凭证并发上限 max_in_flight_per_credential = " + [string]$Health.auth.commandcode_max_in_flight_per_credential)
  Warn "多机共用同一凭证时，注意上面的并发上限（现象为“时好时坏”，见文档第 5 层）"
}
Hr

# ---------- 结论 ----------
if (-not $Health) {
  Write-Host "结论: bridge 未运行 -- 先解决第 1 层。" -ForegroundColor Red
} elseif ($Problems -eq 0) {
  Write-Host "结论: 检查全部通过。" -ForegroundColor Green
} else {
  Write-Host ("结论: 发现 {0} 处问题（见上面的 [x]）。" -f $Problems) -ForegroundColor Red
}

exit 0
