# Minimal ASCII-safe Rename-Journal.ps1
# 修正点：RegexのUnicode指定を \x{...} から \u... (最も互換性が高い形式) に変更

Param(
  [string]$Path = $PSScriptRoot,
  [switch]$Recurse,
  [switch]$Execute,
  [string[]]$Targets
)

# --- Regex Patterns ---
# \uFF08 = 全角カッコ（
# \uFF09 = 全角カッコ）
# これにより、スクリプトファイルの文字コード(UTF-8/SJIS)に関係なく確実にマッチさせます。

$patternList = @(
  # パターン1: 2020 9月 13（日） / 2020 9月 13 (日)
  # 変更点: \x{FF08} -> \uFF08 に修正
  '^\s*(?<y>\d{4})\D*(?<m>\d{1,2})\D*(?<d>\d{1,2})\D*(?:[\(\uFF08][^\)\uFF09]*[\)\uFF09])?\s*(?<tail>.*)$',
  
  # パターン2: 2020-09-13
  '^\s*(?<y>\d{4})-(?<m>\d{1,2})-(?<d>\d{1,2})(?:-[^- ._]+)?\s*(?<tail>.*)$'
)

# --- Regex Options Setup ---
# オプションを事前に計算して変数に入れる（構文エラー回避）
$regOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor 
           [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor 
           [System.Text.RegularExpressions.RegexOptions]::Compiled

$regexes = foreach($p in $patternList){
  New-Object System.Text.RegularExpressions.Regex($p, $regOpts)
}

# --- File Enumeration ---
Write-Host "Searching files in: $Path" -ForegroundColor Cyan
if ($Targets -and $Targets.Count -gt 0) {
  $fileList = @()
  foreach($t in $Targets){
    $fileArgs = @{ Path = (Join-Path $Path $t); File = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recurse){ $fileArgs.Recurse = $true }
    $fileList += Get-ChildItem @fileArgs
  }
  $files = $fileList | Sort-Object FullName -Unique
} else {
  $fileArgs = @{ Path = $Path; Filter = '*.md'; File = $true }
  if ($Recurse){ $fileArgs.Recurse = $true }
  $files = Get-ChildItem @fileArgs
}

if (-not $files) { Write-Warning 'No target files found.'; exit }

# --- Culture Setup ---
$ja = [System.Globalization.CultureInfo]::GetCultureInfo('ja-JP')

function Normalize([string]$s){
  if ($null -eq $s) { return $s }
  $n = $s.Normalize([System.Text.NormalizationForm]::FormKC)
  $n = ($n -replace '\p{C}','') -replace '\s+',' '
  $n.Trim()
}

$plan = @()

# --- Main Loop ---
foreach($f in $files){
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
  $ext  = [System.IO.Path]::GetExtension($f.Name)
  $norm = Normalize $stem

  # Try matching
  $m = $null
  foreach($rx in $regexes){ $m = $rx.Match($norm); if($m.Success){ break } }
  
  if(-not $m.Success){ continue }

  $y  = $m.Groups['y'].Value
  $mo = $m.Groups['m'].Value
  $d  = $m.Groups['d'].Value

  # Parse Date
  try {
    $dt = [datetime]::ParseExact("$y-$mo-$d",'yyyy-M-d',[System.Globalization.CultureInfo]::InvariantCulture)
  } catch { 
    continue 
  }

  # Generate New Name: yyyy-MM-dd-ddd.ext
  $youbi = $dt.ToString('ddd',$ja)
  $newBase = ('{0:0000}-{1:00}-{2:00}-{3}' -f $dt.Year,$dt.Month,$dt.Day,$youbi)
  $newName = $newBase + $ext

  # Skip if name is already correct
  if ($f.Name -ceq $newName) { continue }

  $plan += [pscustomobject]@{
    Dir      = $f.DirectoryName
    Original = $f.Name
    NewName  = $newName
    NewBase  = $newBase
    Ext      = $ext
  }
}

if (-not $plan) { 
    Write-Warning 'Nothing to rename based on patterns.'
    Write-Host "Files found but no patterns matched. Check if filenames match regex." -ForegroundColor Gray
    exit 
}

# --- Execution / Dry Run ---
if (-not $Execute) {
  Write-Host "=== DRY RUN (No changes made) ===" -ForegroundColor Yellow
  Write-Host "Use '.\Rename-Journal.ps1 -Execute' to apply changes." -ForegroundColor Gray
  $plan | Select-Object Original, NewName | Format-Table -AutoSize
  exit
}

# Execute
$done = 0
foreach($p in $plan){
  $finalName = $p.NewName
  
  # Collision Check
  $i = 1
  while(Test-Path -LiteralPath (Join-Path $p.Dir $finalName)){
    $finalName = ("{0} ({1}){2}" -f $p.NewBase, $i, $p.Ext)
    $i++
  }
  
  try {
    Rename-Item -LiteralPath (Join-Path $p.Dir $p.Original) -NewName $finalName -ErrorAction Stop
    $done++
  } catch {
    Write-Error "Failed to rename '$($p.Original)': $_"
  }
}

Write-Host "DONE: Renamed $done files." -ForegroundColor Green