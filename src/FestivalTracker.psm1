$Script:NotionVersion = "2022-06-28"
$Script:UserAgent = "FestivalLegalAvailabilityTracker/1.0"

function Get-EnvValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return $value
}

function Get-ObjectProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function ConvertTo-Scalar {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return $null
        }
        return $Value[0]
    }

    return $Value
}

function ConvertTo-OptionalInt {
    param([object]$Value)

    $scalar = ConvertTo-Scalar $Value
    if ($null -eq $scalar) {
        return $null
    }

    $text = [string]$scalar
    if ($text -match '-?\d+') {
        return [int]$Matches[0]
    }

    return $null
}

function ConvertTo-OptionalDouble {
    param([object]$Value)

    $scalar = ConvertTo-Scalar $Value
    if ($null -eq $scalar) {
        return $null
    }

    $text = [string]$scalar
    if ($text -match '-?\d+(\.\d+)?') {
        return [double]$Matches[0]
    }

    return $null
}

function ConvertTo-MutableRecord {
    param([Parameter(Mandatory = $true)][object]$Value)

    $record = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $record[$property.Name] = $property.Value
    }
    return [pscustomobject]$record
}

function Set-RecordProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Value
    )

    if ($null -ne $Record.PSObject.Properties[$Name]) {
        $Record.$Name = $Value
    }
    else {
        $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function New-StringFromCodePoints {
    param([Parameter(Mandatory = $true)][int[]]$CodePoints)
    return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Repair-MojibakeText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $fixed = $Text
    $markerPattern = "[{0}{1}{2}{3}]" -f [char]0x00C2, [char]0x00C3, [char]0x00C6, [char]0x00E2

    if ($fixed -match $markerPattern) {
        try {
            $bytes = [Text.Encoding]::GetEncoding("Windows-1252").GetBytes($fixed)
            $candidate = [Text.Encoding]::UTF8.GetString($bytes)
            if ($candidate.IndexOf([char]0xFFFD) -lt 0) {
                $fixed = $candidate
            }
        }
        catch {
            # Best-effort text repair; fall through to targeted replacements.
        }
    }

    $replacements = @(
        @{ from = @(0x00E2, 0x20AC, 0x0153); to = '"' },
        @{ from = @(0x00E2, 0x20AC, 0x009D); to = '"' },
        @{ from = @(0x00E2, 0x20AC, 0x02DC); to = "'" },
        @{ from = @(0x00E2, 0x20AC, 0x2122); to = "'" },
        @{ from = @(0x00E2, 0x20AC, 0x201C); to = "-" },
        @{ from = @(0x00E2, 0x20AC, 0x201D); to = "-" },
        @{ from = @(0x00E2, 0x20AC, 0x00A6); to = "..." },
        @{ from = @(0x00E2, 0x00A6); to = "..." },
        @{ from = @(0x00C2, 0x00A0); to = " " },
        @{ from = @(0x00C2); to = "" },
        @{ from = @(0x00EF, 0x00BC, 0x008F); to = "/" },
        @{ from = @(0x00EF, 0x00BD, 0x009C); to = "|" }
    )
    foreach ($replacement in $replacements) {
        $fixed = $fixed.Replace((New-StringFromCodePoints $replacement.from), $replacement.to)
    }

    $mojibakeQuote = [string][char]0x00E2
    $fixed = [regex]::Replace(
        $fixed,
        [regex]::Escape($mojibakeQuote) + "([^" + [regex]::Escape($mojibakeQuote) + "]+)" + [regex]::Escape($mojibakeQuote),
        ([string][char]0x201C) + '$1' + ([string][char]0x201D)
    )

    $fixed = $fixed -replace '[\u0080-\u009F]', ''
    $fixed = $fixed -replace '[\t ]+', ' '
    return $fixed.Trim()
}
function Repair-RecordTextFields {
    param([Parameter(Mandatory = $true)][object]$Record)

    foreach ($name in @("title", "original_title", "director", "festival", "region", "section", "source_url", "imdb_id", "overview", "poster_url")) {
        if ($null -ne $Record.PSObject.Properties[$name]) {
            $value = Get-ObjectProperty $Record $name
            if ($null -ne $value -and $value -is [string]) {
                Set-RecordProperty -Record $Record -Name $name -Value (Repair-MojibakeText $value)
            }
        }
    }

    return $Record
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Default = $null
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Default
    }

    $content = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $Default
    }

    $result = $content | ConvertFrom-Json
    if ($null -ne $result -and
        $null -ne $result.PSObject.Properties["value"] -and
        $null -ne $result.PSObject.Properties["Count"] -and
        $result.value -is [array]) {
        return @($result.value)
    }

    return $result
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertTo-NormalizedTitle {
    param([AllowNull()][string]$Title)

    $Title = Repair-MojibakeText $Title
    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $decomposed = $Title.Normalize([Text.NormalizationForm]::FormD)
    $characters = New-Object System.Collections.Generic.List[char]
    foreach ($character in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            $characters.Add($character)
        }
    }

    $normalized = (-join $characters).ToLowerInvariant()
    $normalized = $normalized -replace '&', ' and '
    $normalized = $normalized -replace '[^\p{L}\p{Nd}]+', ' '
    $normalized = $normalized -replace '\s+', ' '
    return $normalized.Trim()
}

function New-StableId {
    param([Parameter(Mandatory = $true)][string]$InputText)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($InputText)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 24)
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][string]$Html)

    $text = $Html -replace '(?is)<script\b[^>]*>.*?</script>', ' '
    $text = $text -replace '(?is)<style\b[^>]*>.*?</style>', ' '
    $text = $text -replace '(?is)<noscript\b[^>]*>.*?</noscript>', ' '
    $text = $text -replace '(?i)</?(br|p|div|li|tr|td|th|h[1-6]|section|article|header)[^>]*>', "`n"
    $text = $text -replace '<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace "`r", "`n"
    $text = $text -replace "[`t ]+", " "
    $text = $text -replace " *`n *", "`n"
    $text = $text -replace "`n{3,}", "`n`n"
    return Repair-MojibakeText $text.Trim()
}

function New-FilmRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$OriginalTitle,
        [string]$Director,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$Section,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year,
        [Nullable[int]]$FilmYear = $null
    )

    $cleanTitle = (Repair-MojibakeText ($Title -replace '\s+', ' ').Trim())
    $cleanDirector = (Repair-MojibakeText ($Director -replace '\s+', ' ').Trim())
    $key = "{0}|{1}|{2}|{3}|{4}" -f $Festival, $Year, (ConvertTo-NormalizedTitle $cleanTitle), (ConvertTo-NormalizedTitle $cleanDirector), $SourceUrl

    [pscustomobject]@{
        id = New-StableId $key
        title = $cleanTitle
        original_title = if ([string]::IsNullOrWhiteSpace($OriginalTitle)) { $cleanTitle } else { Repair-MojibakeText $OriginalTitle.Trim() }
        director = $cleanDirector
        year = $Year
        festival_year = $Year
        film_year = $FilmYear
        festival = $Festival
        region = $Region
        section = $Section
        source_url = $SourceUrl
        tmdb_id = $null
        imdb_id = $null
        match_confidence = 0
        poster_url = $null
        overview = $null
        tmdb_rating = $null
        imdb_rating = $null
        imdb_votes = $null
        imdb_rating_checked_at = $null
        rating_source = $null
        tracking_status = "pending"
        first_available_date = $null
        last_checked = $null
        needs_review = $false
        authorized_source_urls = @()
        notion_page_id = $null
        created_at = (Get-Date).ToString("o")
        updated_at = (Get-Date).ToString("o")
    }
}

function ConvertFrom-TitleByDirectorText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year,
        [string[]]$AllowedSections = @()
    )

    $records = New-Object System.Collections.Generic.List[object]
    $section = $null
    $subSection = $null
    $pendingTitle = $null
    $lines = $Text -split "`n"

    foreach ($rawLine in $lines) {
        $line = ($rawLine -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.Length -lt 80 -and $line -match '(?i)^(in competition|competition|encounters|panorama|forum|premieres|midnight|midnight screenings|cannes premiere|spotlight|shorts|special screenings|out of competition|uncertain regard|un certain regard|directors'' fortnight|quinzaine des cinéastes|critics'' week|semaine de la critique|cannes classics|cinéma de la plage|immersive competition|acide|main slate|galas|discovery|wavelengths|platform|proxima|competition films|new currents|best feature film|best narrative feature|golden horse awards)$') {
            $section = $line
            $subSection = $null
            $pendingTitle = $null
            continue
        }

        if ($line -match '(?i)^(feature films|short films)$') {
            $subSection = $line
            $pendingTitle = $null
            continue
        }

        $effectiveSection = if (-not [string]::IsNullOrWhiteSpace($subSection)) { "$section - $subSection" } else { $section }

        if ($line -cmatch '^by\s+(?<director>[^<>]{2,120})$' -and -not [string]::IsNullOrWhiteSpace($pendingTitle)) {
            $title = $pendingTitle.Trim(" -")
            $director = $Matches.director.Trim(" .")
            if ($title.StartsWith("(") -and $title.EndsWith(")") -and $title.Length -gt 2) {
                $title = $title.Substring(1, $title.Length - 2)
            }
            $sectionAllowed = @($AllowedSections).Count -eq 0 -or $AllowedSections -contains $effectiveSection
            if ($sectionAllowed -and $director -notmatch '(?i)\b(filmmakers|programme|program|festival|screening|opening event|newsletter|tickets?)\b') {
                $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section $effectiveSection -SourceUrl $SourceUrl -Year $Year))
            }
            $pendingTitle = $null
            continue
        }

        if ($line -cmatch '^(?<title>.{2,180})\s+by\s+(?<director>[^<>]{2,120})$') {
            $title = $Matches.title.Trim(" -")
            $director = $Matches.director.Trim(" .")
            if ($director -match '(?i)\b(filmmakers|programme|program|festival|screening|opening event|newsletter|tickets?)\b') {
                continue
            }
            $sectionAllowed = @($AllowedSections).Count -eq 0 -or $AllowedSections -contains $effectiveSection
            if ($sectionAllowed -and $title.Length -ge 2 -and $director.Length -ge 2) {
                $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section $effectiveSection -SourceUrl $SourceUrl -Year $Year))
            }
            $pendingTitle = $null
            continue
        }

        if ($line.Length -ge 2 -and $line.Length -le 180 -and $line -match '\p{L}' -and $line -notmatch '(?i)\b(menu|search|newsletter|ticket|festival|official selection|read more|press|accreditation|schedule|program)\b') {
            $pendingTitle = $line
        }
        else {
            $pendingTitle = $null
        }
    }

    return $records
}

function ConvertFrom-SundanceText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    $allowedSections = @("U.S. DRAMATIC COMPETITION", "WORLD CINEMA DRAMATIC COMPETITION", "NEXT")

    $allSections = @(
        "U.S. DRAMATIC COMPETITION",
        "U.S. DOCUMENTARY COMPETITION",
        "WORLD CINEMA DRAMATIC COMPETITION",
        "WORLD CINEMA DOCUMENTARY COMPETITION",
        "NEXT",
        "PREMIERES",
        "MIDNIGHT",
        "EPISODIC",
        "SPOTLIGHT",
        "FAMILY MATINEE",
        "PARK CITY LEGACY"
    )
    $normalized = ($Text -replace '\s+', ' ').Trim()
    foreach ($section in $allowedSections) {
        $sectionStart = $normalized.IndexOf($section, [System.StringComparison]::Ordinal)
        if ($sectionStart -lt 0) {
            continue
        }

        $segmentStart = $sectionStart + $section.Length
        $segmentEnd = $normalized.Length
        foreach ($candidate in $allSections) {
            if ($candidate -eq $section) {
                continue
            }
            $candidateIndex = $normalized.IndexOf($candidate, $segmentStart, [System.StringComparison]::Ordinal)
            if ($candidateIndex -ge 0 -and $candidateIndex -lt $segmentEnd) {
                $segmentEnd = $candidateIndex
            }
        }

        $segment = $normalized.Substring($segmentStart, $segmentEnd - $segmentStart)
        $pattern = '(?<title>[^/]{2,160})\s*/\s*(?<countries>[^()]{2,180})\s+\((?<credits>.+?)\)\s*[\u2013\u2014-]'
        foreach ($match in [regex]::Matches($segment, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            $title = ($match.Groups["title"].Value -replace '\s+', ' ').Trim()
            $lastSentence = $title.LastIndexOf(". ")
            if ($lastSentence -ge 0 -and $lastSentence -lt ($title.Length - 2)) {
                $title = $title.Substring($lastSentence + 2).Trim()
            }
            $title = Repair-MojibakeText ($title -replace '\s+', ' ')
            $credits = $match.Groups["credits"].Value
            $director = $null
            if ($credits -match 'Directors?[^:]{0,80}:\s*(?<director>.+?)(,\s*(Screenwriters?|Producers?|Producer|Screenwriter):|$)') {
                $director = Repair-MojibakeText ($Matches.director.Trim())
            }

            if (-not [string]::IsNullOrWhiteSpace($title) -and -not [string]::IsNullOrWhiteSpace($director)) {
                $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section $section -SourceUrl $SourceUrl -Year $Year))
            }
        }
    }

    return $records
}

function ConvertTo-OptionalOmdbVotes {
    param([object]$Value)

    $scalar = ConvertTo-Scalar $Value
    if ($null -eq $scalar) {
        return $null
    }

    $text = ([string]$scalar).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "N/A") {
        return $null
    }

    $digits = $text -replace '[^\d]', ''
    if ([string]::IsNullOrWhiteSpace($digits)) {
        return $null
    }

    return [int]$digits
}

function ConvertTo-OptionalImdbVotes {
    param([object]$Value)
    return ConvertTo-OptionalOmdbVotes $Value
}

function Get-ImdbRatingsDatasetPath {
    param([Parameter(Mandatory = $true)][string]$StateDir)

    $directory = Join-Path $StateDir "imdb"
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return Join-Path $directory "title.ratings.tsv.gz"
}

function Update-ImdbRatingsDataset {
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [int]$MaxAgeHours = 24
    )

    $path = Get-ImdbRatingsDatasetPath -StateDir $StateDir
    $shouldDownload = $true
    if (Test-Path $path) {
        $age = (Get-Date) - (Get-Item $path).LastWriteTime
        $shouldDownload = $age.TotalHours -ge $MaxAgeHours
    }

    if (-not $shouldDownload) {
        return $path
    }

    $tmpPath = "$path.tmp"
    Invoke-WebRequest -Uri "https://datasets.imdbws.com/title.ratings.tsv.gz" -OutFile $tmpPath -Headers @{ "User-Agent" = $Script:UserAgent } -ErrorAction Stop
    Move-Item -LiteralPath $tmpPath -Destination $path -Force
    return $path
}

function Get-ImdbRatingsFromDataset {
    param(
        [Parameter(Mandatory = $true)][string]$DatasetPath,
        [Parameter(Mandatory = $true)][string[]]$ImdbIds
    )

    $wanted = @{}
    foreach ($id in @($ImdbIds | Where-Object { $_ -match '^tt\d+$' } | Sort-Object -Unique)) {
        $wanted[$id] = $true
    }
    if ($wanted.Count -eq 0 -or -not (Test-Path $DatasetPath)) {
        return @{}
    }

    $ratings = @{}
    $fileStream = [System.IO.File]::OpenRead($DatasetPath)
    try {
        $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $reader = [System.IO.StreamReader]::new($gzipStream)
            try {
                [void]$reader.ReadLine()
                while (-not $reader.EndOfStream -and $ratings.Count -lt $wanted.Count) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }
                    $parts = $line -split "`t"
                    if ($parts.Count -lt 3) {
                        continue
                    }
                    $id = $parts[0]
                    if (-not $wanted.ContainsKey($id)) {
                        continue
                    }
                    $ratings[$id] = [pscustomobject]@{
                        imdb_id = $id
                        imdb_rating = ConvertTo-OptionalDouble $parts[1]
                        imdb_votes = ConvertTo-OptionalImdbVotes $parts[2]
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $gzipStream.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }

    return $ratings
}

function Get-OmdbMovieByImdbId {
    param([Parameter(Mandatory = $true)][string]$ImdbId)

    $apiKey = Get-EnvValue "OMDB_API_KEY"
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return $null
    }

    if ($ImdbId -notmatch '^tt\d+$') {
        return $null
    }

    $uri = "https://www.omdbapi.com/?i=$([uri]::EscapeDataString($ImdbId))&apikey=$([uri]::EscapeDataString($apiKey))"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ "User-Agent" = $Script:UserAgent } -ErrorAction Stop
        if ([string](Get-ObjectProperty $response "Response" "") -ne "True") {
            return $null
        }
        return $response
    }
    catch {
        Write-Warning "OMDb request failed for ${ImdbId}: $($_.Exception.Message)"
        return $null
    }
}

function Test-ShouldRefreshOmdbRating {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [int]$RefreshDays = 30
    )

    $imdbId = [string](Get-ObjectProperty $Film "imdb_id" "")
    if ($imdbId -notmatch '^tt\d+$') {
        return $false
    }

    $rating = ConvertTo-OptionalDouble (Get-ObjectProperty $Film "imdb_rating" $null)
    $checkedAtText = [string](Get-ObjectProperty $Film "imdb_rating_checked_at" "")
    if ($null -eq $rating -or $rating -le 0) {
        if ([string]::IsNullOrWhiteSpace($checkedAtText)) {
            return $true
        }
        $checkedAt = [datetime]::MinValue
        if ([datetime]::TryParse($checkedAtText, [ref]$checkedAt)) {
            return $checkedAt.Date -lt (Get-Date).Date
        }
        return $true
    }

    if ([string](Get-ObjectProperty $Film "tracking_status" "pending") -eq "available_found") {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($checkedAtText)) {
        return $true
    }

    $lastChecked = [datetime]::MinValue
    if (-not [datetime]::TryParse($checkedAtText, [ref]$lastChecked)) {
        return $true
    }

    return $lastChecked.Date -le (Get-Date).Date.AddDays(-1 * $RefreshDays)
}

function Update-FilmOmdbRatings {
    param(
        [object[]]$Films = @(),
        [int]$RefreshDays = 30,
        [int]$MaxUpdates = 20
    )

    $apiKey = Get-EnvValue "OMDB_API_KEY"
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return @($Films)
    }

    $updated = 0
    foreach ($film in @($Films)) {
        if ($MaxUpdates -gt 0 -and $updated -ge $MaxUpdates) {
            break
        }
        if (-not (Test-ShouldRefreshOmdbRating -Film $film -RefreshDays $RefreshDays)) {
            continue
        }

        $imdbId = [string](Get-ObjectProperty $film "imdb_id" "")
        $omdb = Get-OmdbMovieByImdbId -ImdbId $imdbId
        Set-RecordProperty -Record $film -Name "imdb_rating_checked_at" -Value (Get-Date).ToString("yyyy-MM-dd")
        if ($null -ne $omdb) {
            $rating = ConvertTo-OptionalDouble (Get-ObjectProperty $omdb "imdbRating" $null)
            $votes = ConvertTo-OptionalOmdbVotes (Get-ObjectProperty $omdb "imdbVotes" $null)
            if ($null -ne $rating -and $rating -gt 0) {
                Set-RecordProperty -Record $film -Name "imdb_rating" -Value $rating
                Set-RecordProperty -Record $film -Name "rating_source" -Value "IMDb"
            }
            if ($null -ne $votes -and $votes -gt 0) {
                Set-RecordProperty -Record $film -Name "imdb_votes" -Value $votes
            }
        }
        $updated++
    }

    if ($updated -gt 0) {
        Write-Host "OMDb rating sync checked $updated film(s)."
    }

    return @($Films)
}

function Update-FilmImdbDatasetRatings {
    param(
        [object[]]$Films = @(),
        [Parameter(Mandatory = $true)][string]$StateDir
    )

    $ids = @($Films | ForEach-Object { [string](Get-ObjectProperty $_ "imdb_id" "") } | Where-Object { $_ -match '^tt\d+$' } | Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        return @($Films)
    }

    try {
        $datasetPath = Update-ImdbRatingsDataset -StateDir $StateDir
        $ratings = Get-ImdbRatingsFromDataset -DatasetPath $datasetPath -ImdbIds $ids
    }
    catch {
        Write-Warning "IMDb ratings dataset sync failed: $($_.Exception.Message)"
        return @($Films)
    }

    $updated = 0
    foreach ($film in @($Films)) {
        $imdbId = [string](Get-ObjectProperty $film "imdb_id" "")
        if (-not $ratings.ContainsKey($imdbId)) {
            continue
        }
        $rating = $ratings[$imdbId]
        if ($null -ne $rating.imdb_rating -and $rating.imdb_rating -gt 0) {
            Set-RecordProperty -Record $film -Name "imdb_rating" -Value $rating.imdb_rating
            Set-RecordProperty -Record $film -Name "rating_source" -Value "IMDb Dataset"
            Set-RecordProperty -Record $film -Name "imdb_rating_checked_at" -Value (Get-Date).ToString("yyyy-MM-dd")
            $updated++
        }
        if ($null -ne $rating.imdb_votes -and $rating.imdb_votes -gt 0) {
            Set-RecordProperty -Record $film -Name "imdb_votes" -Value $rating.imdb_votes
        }
    }

    if ($updated -gt 0) {
        Write-Host "IMDb dataset rating sync updated $updated film record(s)."
    }

    return @($Films)
}

function ConvertFrom-VeniceText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    $section = if ($SourceUrl -match 'orizzonti') { "Orizzonti Competition" } else { "Venezia Competition" }
    $scanText = $Text
    if ($section -eq "Orizzonti Competition" -and $scanText -match '(?s)(?<features>Orizzonti Competition.+?)Orizzonti Short Films Competition') {
        $scanText = $Matches.features
    }

    $pattern = 'Read more\s+(?<title>.+?)\s+Director\s+(?<director>.+?)\s+Main Cast\s+(?<meta>.+?)(?=\s+Read more\s+|$)'
    foreach ($match in [regex]::Matches($scanText, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $title = Repair-MojibakeText (($match.Groups["title"].Value -replace '\s+', ' ').Trim())
        $director = Repair-MojibakeText (($match.Groups["director"].Value -replace '\s+', ' ').Trim())
        $meta = ($match.Groups["meta"].Value -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($director)) {
            continue
        }

        $filmYear = $Year
        if ($meta -match '(?<year>(19|20)\d{2})') {
            $filmYear = [int]$Matches.year
        }

        $duration = $null
        if ($meta -match "(?<minutes>\d{2,3})\s*['’]") {
            $duration = [int]$Matches.minutes
        }
        if ($null -ne $duration -and $duration -lt 60) {
            continue
        }

        $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section $section -SourceUrl $SourceUrl -Year $Year -FilmYear $filmYear))
    }

    return $records
}

function ConvertFrom-OscarsText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year,
        [string[]]$AllowedCategories = @()
    )

    $categories = @(
        "Actor in a Leading Role",
        "Actor in a Supporting Role",
        "Actress in a Leading Role",
        "Actress in a Supporting Role",
        "Animated Feature Film",
        "Animated Short Film",
        "Casting",
        "Cinematography",
        "Costume Design",
        "Directing",
        "Documentary Feature Film",
        "Documentary Short Film",
        "Film Editing",
        "International Feature Film",
        "Live Action Short Film",
        "Makeup and Hairstyling",
        "Music (Original Score)",
        "Music (Original Song)",
        "Best Picture",
        "Production Design",
        "Sound",
        "Visual Effects",
        "Writing (Adapted Screenplay)",
        "Writing (Original Screenplay)"
    )
    $actingCategories = @(
        "Actor in a Leading Role",
        "Actor in a Supporting Role",
        "Actress in a Leading Role",
        "Actress in a Supporting Role"
    )

    $recordsByTitle = @{}
    $lines = @($Text -split "`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $currentCategory = $null
    $pendingStatus = $null
    $pendingPersonOrSong = $null

    foreach ($line in $lines) {
        if ($line.StartsWith("Select a Category")) {
            continue
        }

        if ($categories -contains $line) {
            $currentCategory = $line
            $pendingStatus = $null
            $pendingPersonOrSong = $null
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentCategory)) {
            continue
        }
        if (@($AllowedCategories).Count -gt 0 -and $AllowedCategories -notcontains $currentCategory) {
            continue
        }

        if ($line -eq "Winner" -or $line -eq "Nominees") {
            $pendingStatus = if ($line -eq "Winner") { "Winner" } else { "Nominee" }
            $pendingPersonOrSong = $null
            continue
        }

        if ([string]::IsNullOrWhiteSpace($pendingStatus)) {
            continue
        }

        $title = $null
        if ($actingCategories -contains $currentCategory) {
            if ([string]::IsNullOrWhiteSpace($pendingPersonOrSong)) {
                $pendingPersonOrSong = $line
                continue
            }
            $title = $line
        }
        elseif ($currentCategory -eq "Music (Original Song)") {
            if ([string]::IsNullOrWhiteSpace($pendingPersonOrSong)) {
                $pendingPersonOrSong = $line
                continue
            }
            if ($line -match '^from\s+(?<film>.+?);') {
                $title = $Matches.film.Trim()
            }
            else {
                $title = $line
            }
        }
        else {
            $title = $line
        }

        $pendingStatus = $null
        $pendingPersonOrSong = $null
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }
        if ($title -match '(?i)^(written by|screenplay by|music by|production design|set decoration|makeup|hairstyling|sound|visual effects|costume|director:|producer)') {
            continue
        }

        $sectionText = "$currentCategory ($pendingStatus)"
        if ($sectionText -eq "$currentCategory ()") {
            $sectionText = $currentCategory
        }
        $key = ConvertTo-NormalizedTitle $title
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if ($recordsByTitle.ContainsKey($key)) {
            $existing = $recordsByTitle[$key]
            $sections = @($existing.section -split '; ' | Where-Object { $_ })
            if ($sections -notcontains $currentCategory) {
                $existing.section = (@($sections + $currentCategory) -join '; ')
            }
        }
        else {
            $recordsByTitle[$key] = New-FilmRecord -Title $title -Director "" -Festival $Festival -Region $Region -Section $currentCategory -SourceUrl $SourceUrl -Year $Year
        }
    }

    return @($recordsByTitle.Values | Sort-Object title)
}

function ConvertFrom-GoldenHorseAwardsText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    $start = $Text.IndexOf("Best Narrative Feature", [System.StringComparison]::OrdinalIgnoreCase)
    if ($start -lt 0) {
        return $records
    }

    $end = $Text.Length
    foreach ($marker in @("Best Documentary Feature", "Best Animated Feature", "Best Director")) {
        $index = $Text.IndexOf($marker, $start + 1, [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -ge 0 -and $index -lt $end) {
            $end = $index
        }
    }

    $segment = $Text.Substring($start, $end - $start)
    $lines = @($segment -split "`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($i = 1; $i -lt $lines.Count; $i += 2) {
        $title = $lines[$i]
        if ($title -match '(?i)\b(company|companies|production|pictures|films|agency|entertainment|limited|ltd|llc|inc|co\.)\b') {
            continue
        }
        $records.Add((New-FilmRecord -Title $title -Director "" -Festival $Festival -Region $Region -Section "Best Narrative Feature" -SourceUrl $SourceUrl -Year $Year))
    }

    return $records
}

function Get-WikipediaSectionHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$HeadingId
    )

    $escapedId = [regex]::Escape($HeadingId)
    $headingPatterns = @(
        "(?is)<h[2-4][^>]*\bid\s*=\s*['""]$escapedId['""][^>]*>.*?</h[2-4]>",
        "(?is)<span[^>]*\bid\s*=\s*['""]$escapedId['""][^>]*>.*?</span>"
    )

    foreach ($pattern in $headingPatterns) {
        $match = [regex]::Match($Html, $pattern)
        if (-not $match.Success) {
            continue
        }

        $start = $match.Index + $match.Length
        $remaining = $Html.Substring($start)
        $nextHeading = [regex]::Match($remaining, "(?is)<h[2-4][^>]*\bid\s*=\s*['""][^'""]+['""][^>]*>|<span[^>]*\bid\s*=\s*['""][^'""]+['""][^>]*class\s*=\s*['""][^'""]*mw-headline[^'""]*['""][^>]*>")
        if ($nextHeading.Success) {
            return $remaining.Substring(0, $nextHeading.Index)
        }

        return $remaining
    }

    return ""
}

function ConvertFrom-WikipediaOscarsHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year,
        [string[]]$AllowedCategories = @()
    )

    $categoryAliases = [ordered]@{
        "Best Picture" = @("Best_Picture")
        "International Feature Film" = @("Best_International_Feature_Film", "International_Feature_Film")
        "Animated Feature Film" = @("Best_Animated_Feature_Film", "Animated_Feature_Film")
    }

    $allowed = @{}
    if (@($AllowedCategories).Count -gt 0) {
        foreach ($category in $AllowedCategories) {
            $allowed[$category] = $true
            if ($category -notmatch '^Best ' -and $category -ne "International Feature Film" -and $category -ne "Animated Feature Film") {
                continue
            }
        }
    }

    $filmYear = if ($Year -gt 1) { $Year - 1 } else { $null }
    $recordsByTitle = [ordered]@{}
    $addTitle = {
        param(
            [string]$Title,
            [string]$Category
        )

        $cleanTitle = Repair-MojibakeText (($Title -replace '\s+', ' ').Trim())
        if ([string]::IsNullOrWhiteSpace($cleanTitle)) {
            return
        }

        $key = ConvertTo-NormalizedTitle $cleanTitle
        if (-not $recordsByTitle.Contains($key)) {
            $record = New-FilmRecord -Title $cleanTitle -Director "" -Festival $Festival -Region $Region -Section $Category -SourceUrl $SourceUrl -Year $Year -FilmYear $filmYear
            $recordsByTitle[$key] = [pscustomobject]@{
                record = $record
                sections = New-Object System.Collections.Generic.List[string]
            }
        }

        if (-not $recordsByTitle[$key].sections.Contains($Category)) {
            $recordsByTitle[$key].sections.Add($Category) | Out-Null
        }
    }

    $categoryLabelAliases = @{
        "Best Picture" = "Best Picture"
        "Best International Feature Film" = "International Feature Film"
        "International Feature Film" = "International Feature Film"
        "Best Animated Feature Film" = "Animated Feature Film"
        "Animated Feature Film" = "Animated Feature Film"
    }

    $awardTableMatch = [regex]::Match($Html, "(?is)<table[^>]*\bwikitable\b[^>]*>.*?</table>")
    if ($awardTableMatch.Success) {
        foreach ($cellMatch in [regex]::Matches($awardTableMatch.Value, "(?is)<td\b[^>]*>.*?</td>")) {
            $cellHtml = $cellMatch.Value
            $labelMatch = [regex]::Match($cellHtml, "(?is)<div[^>]*>\s*<b>\s*<a[^>]*>(?<label>.*?)</a>\s*</b>\s*</div>")
            if (-not $labelMatch.Success) {
                continue
            }

            $label = ((ConvertTo-PlainText $labelMatch.Groups["label"].Value) -replace '\s+', ' ').Trim()
            if (-not $categoryLabelAliases.ContainsKey($label)) {
                continue
            }

            $canonicalCategory = $categoryLabelAliases[$label]
            if (@($AllowedCategories).Count -gt 0 -and -not $allowed.ContainsKey($canonicalCategory)) {
                continue
            }

            $cellHtml = [regex]::Replace($cellHtml, "(?is)<sup\b.*?</sup>", "")
            foreach ($titleMatch in [regex]::Matches($cellHtml, "(?is)<i\b[^>]*>(?<title>.*?)</i>")) {
                $title = ConvertTo-PlainText $titleMatch.Groups["title"].Value
                & $addTitle $title $canonicalCategory
            }
        }
    }

    foreach ($canonicalCategory in $categoryAliases.Keys) {
        if (@($AllowedCategories).Count -gt 0 -and -not $allowed.ContainsKey($canonicalCategory)) {
            continue
        }

        $sectionHtml = ""
        foreach ($headingId in $categoryAliases[$canonicalCategory]) {
            $sectionHtml = Get-WikipediaSectionHtml -Html $Html -HeadingId $headingId
            if (-not [string]::IsNullOrWhiteSpace($sectionHtml)) {
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($sectionHtml)) {
            continue
        }

        $tableMatch = [regex]::Match($sectionHtml, "(?is)<table[^>]*\bwikitable\b[^>]*>.*?</table>")
        if (-not $tableMatch.Success) {
            continue
        }

        foreach ($rowMatch in [regex]::Matches($tableMatch.Value, "(?is)<tr\b[^>]*>.*?</tr>")) {
            $rowHtml = [regex]::Replace($rowMatch.Value, "(?is)<sup\b.*?</sup>", "")
            $titleMatch = [regex]::Match($rowHtml, "(?is)<i\b[^>]*>(?<title>.*?)</i>")
            if (-not $titleMatch.Success) {
                continue
            }

            $title = Repair-MojibakeText ((ConvertTo-PlainText $titleMatch.Groups["title"].Value) -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($title)) {
                continue
            }

            & $addTitle $title $canonicalCategory
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $recordsByTitle.Values) {
        Set-RecordProperty -Record $entry.record -Name "section" -Value (($entry.sections.ToArray()) -join "; ")
        $records.Add($entry.record) | Out-Null
    }

    return $records
}

function ConvertFrom-NyffMainSlateText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    $recordsByTitle = @{}
    $lines = @($Text -split "`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($i = 0; $i -lt ($lines.Count - 1); $i++) {
        $title = $lines[$i]
        $meta = $lines[$i + 1]
        if ($title.Length -lt 2 -or $title.Length -gt 180) {
            continue
        }
        if ($title -match '(?i)\b(courtesy|secure your tickets|festival passes|film at lincoln center|read more|premiere|release)\b') {
            continue
        }
        if ($meta -notmatch '^(?<director>[^,]{2,120}),\s*(?<year>(19|20)\d{2}),\s*(?<details>.+?)(?<duration>\d{2,3})m\b') {
            continue
        }

        $director = Repair-MojibakeText $Matches.director.Trim()
        $filmYear = [int]$Matches.year
        $key = ConvertTo-NormalizedTitle $title
        if ([string]::IsNullOrWhiteSpace($key) -or $recordsByTitle.ContainsKey($key)) {
            continue
        }

        $recordsByTitle[$key] = $true
        $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section "Main Slate" -SourceUrl $SourceUrl -Year $Year -FilmYear $filmYear))
    }

    return $records
}

function ConvertTo-CleanHtmlText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $clean = $Text -replace '<[^>]+>', ' '
    $clean = [System.Net.WebUtility]::HtmlDecode($clean)
    $clean = $clean -replace '\s+', ' '
    return Repair-MojibakeText $clean.Trim()
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Href
    )

    try {
        return ([Uri]::new([Uri]$BaseUrl, $Href)).AbsoluteUri
    }
    catch {
        return $Href
    }
}

function Get-SectionNameFromSourceUrl {
    param(
        [Parameter(Mandatory = $true)][string]$SourceUrl,
        [string]$Default = ""
    )

    if ($SourceUrl -match 'asian-vision|6055') { return "Asian Vision Competition" }
    if ($SourceUrl -match 'international-competition|6056') { return "International Competition" }
    if ($SourceUrl -match 'taiwan-competition|6057') { return "Taiwan Competition" }
    if ($SourceUrl -match 'crystal-globe-competition') { return "Crystal Globe Competition" }
    if ($SourceUrl -match 'proxima-competition') { return "Proxima Competition" }
    return $Default
}

function Get-TidfDirectorFromFilmPage {
    param([Parameter(Mandatory = $true)][string]$FilmUrl)

    try {
        $filmHtml = Invoke-TextRequest -Url $FilmUrl
        $directorMatches = [regex]::Matches($filmHtml, '<div class="director-info">.*?<div class="entity-name">(?<name>[^<]+)</div>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $directors = @($directorMatches | ForEach-Object {
            ConvertTo-CleanHtmlText $_.Groups["name"].Value
        } | Where-Object { $_ } | Select-Object -Unique)
        return ($directors -join ", ")
    }
    catch {
        Write-Warning "Failed to fetch TIDF film detail ${FilmUrl}: $($_.Exception.Message)"
        return ""
    }
}

function ConvertFrom-TidfCategoryHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    $section = Get-SectionNameFromSourceUrl -SourceUrl $SourceUrl -Default "Competition"
    $pattern = '<h3 class="views-field views-field-title entity-title">\s*<a href="(?<href>[^"]+)">(?<title>[^<]+)</a>\s*</h3>.*?<div class="views-field views-field-field-year-start entity-start-date">(?<year>\d{4})</div>'
    foreach ($match in [regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $title = ConvertTo-CleanHtmlText $match.Groups["title"].Value
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $filmYear = $Year
        if ($match.Groups["year"].Value -match '^\d{4}$') {
            $filmYear = [int]$match.Groups["year"].Value
        }
        $filmUrl = Join-Url -BaseUrl $SourceUrl -Href $match.Groups["href"].Value
        $director = Get-TidfDirectorFromFilmPage -FilmUrl $filmUrl
        $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section $section -SourceUrl $filmUrl -Year $Year -FilmYear $filmYear))
    }

    return $records
}

function ConvertFrom-KviffArchiveHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    $section = Get-SectionNameFromSourceUrl -SourceUrl $SourceUrl -Default "Competition"
    $pattern = '<a href="(?<href>[^"]+)" class="film-name">(?<title>.*?)</a><br\s*/>\s*(?:\((?<original>.*?)\)\s*)?</div>\s*<div class="col second">\s*Directed by:\s*(?<director>.*?)\s*/\s*(?<meta>.*?)<br\s*/>'
    foreach ($match in [regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $title = ConvertTo-CleanHtmlText $match.Groups["title"].Value
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $originalTitle = ConvertTo-CleanHtmlText $match.Groups["original"].Value
        if ([string]::IsNullOrWhiteSpace($originalTitle)) {
            $originalTitle = $title
        }

        $director = ConvertTo-CleanHtmlText $match.Groups["director"].Value
        $filmYear = $Year
        $meta = ConvertTo-CleanHtmlText $match.Groups["meta"].Value
        if ($meta -match '(?<year>(19|20)\d{2})') {
            $filmYear = [int]$Matches.year
        }

        $filmUrl = Join-Url -BaseUrl $SourceUrl -Href $match.Groups["href"].Value
        $records.Add((New-FilmRecord -Title $title -OriginalTitle $originalTitle -Director $director -Festival $Festival -Region $Region -Section $section -SourceUrl $filmUrl -Year $Year -FilmYear $filmYear))
    }

    return $records
}

function Get-TaipeiFilmFestivalApiToken {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$EndpointFragment
    )

    $escapedEndpoint = [regex]::Escape($EndpointFragment)
    $pattern = "${escapedEndpoint}[^a-zA-Z0-9]{0,8}\s*\{\s*""(?<key>[a-f0-9]{32})""\s*:\s*""(?<value>[a-f0-9]+)"""
    $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "Could not find Taipei Film Festival API token for $EndpointFragment."
    }

    return [pscustomobject]@{
        key = $match.Groups["key"].Value
        value = $match.Groups["value"].Value
    }
}

function Invoke-TaipeiFilmFestivalApi {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][object]$Token,
        [hashtable]$Query = @{}
    )

    $params = @{}
    foreach ($key in $Query.Keys) {
        $params[$key] = $Query[$key]
    }
    $params[$Token.key] = $Token.value

    return Invoke-RestMethod -Uri "https://www.taipeiff.taipei/$Endpoint" -Method Get -Body $params -Headers @{ "User-Agent" = $Script:UserAgent } -ErrorAction Stop
}

function ConvertFrom-TaipeiFilmAwardsData {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year,
        [string[]]$AllowedAwardPatterns = @()
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Data.awardAry)) {
        $title = ConvertTo-CleanHtmlText ([string](Get-ObjectProperty $item "title" ""))
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $awardNames = New-Object System.Collections.Generic.List[string]
        $director = ""
        foreach ($award in @($item.awards_with_winners)) {
            $awardName = ConvertTo-CleanHtmlText ([string](Get-ObjectProperty $award "award_name" ""))
            if (-not [string]::IsNullOrWhiteSpace($awardName)) {
                $awardNames.Add($awardName)
            }
            if ($awardName -match '\u6700\u4f73\u5c0e\u6f14') {
                $director = ConvertTo-CleanHtmlText ([string](Get-ObjectProperty $award "winner" ""))
            }
        }
        if (@($AllowedAwardPatterns).Count -gt 0) {
            $matchesAllowedAward = $false
            foreach ($awardName in @($awardNames)) {
                foreach ($pattern in @($AllowedAwardPatterns)) {
                    if ($awardName -match $pattern) {
                        $matchesAllowedAward = $true
                        break
                    }
                }
                if ($matchesAllowedAward) {
                    break
                }
            }
            if (-not $matchesAllowedAward) {
                continue
            }
        }

        $section = "Taipei Film Awards"
        if ($awardNames.Count -gt 0) {
            $section = "Taipei Film Awards - $($awardNames -join '; ')"
        }

        $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section $section -SourceUrl $SourceUrl -Year $Year))
    }

    return $records
}

function ConvertFrom-TaipeiNewTalentData {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Data.awardAry)) {
        $title = ConvertTo-CleanHtmlText ([string](Get-ObjectProperty $item "col_1" ""))
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $credit = ConvertTo-CleanHtmlText ([string](Get-ObjectProperty $item "col_2" ""))
        $director = $credit
        if ($credit -match '^(?<director>.+?)\s*\|') {
            $director = $Matches.director.Trim()
        }

        $records.Add((New-FilmRecord -Title $title -Director $director -Festival $Festival -Region $Region -Section "International New Talent Competition" -SourceUrl $SourceUrl -Year $Year))
    }

    return $records
}

function ConvertFrom-TaipeiFilmAwardsHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $token = Get-TaipeiFilmFestivalApiToken -Html $Html -EndpointFragment "api/articles/tfa/nominees"
    $data = Invoke-TaipeiFilmFestivalApi -Endpoint "api/articles/tfa/nominees" -Token $token -Query @{ type = "2"; search = "" }
    if ($data.status -ne "success") {
        throw "Taipei Film Awards API returned status '$($data.status)'."
    }

    return ConvertFrom-TaipeiFilmAwardsData -Data $data -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year -AllowedAwardPatterns @("^Best Narrative Feature$", "^\u6700\u4f73\u5287\u60c5\u9577\u7247$")
}

function ConvertFrom-TaipeiNewTalentHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [int]$Year = (Get-Date).Year
    )

    $token = Get-TaipeiFilmFestivalApiToken -Html $Html -EndpointFragment "api/articles/international/nominees"
    $data = Invoke-TaipeiFilmFestivalApi -Endpoint "api/articles/international/nominees" -Token $token -Query @{ pages = "1" }
    if ($data.status -ne "success") {
        throw "Taipei New Talent API returned status '$($data.status)'."
    }

    return ConvertFrom-TaipeiNewTalentData -Data $data -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
}

function ConvertFrom-LineupHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Festival,
        [string]$Region,
        [string]$SourceUrl,
        [string]$Parser = "generic_title_by_director",
        [int]$Year = (Get-Date).Year,
        [string[]]$SectionScope = @()
    )

    $text = ConvertTo-PlainText $Html
    $allowedSections = @()
    if ($Parser -eq "cannes_selection") {
        $allowedSections = @("In Competition - Feature films", "Un Certain Regard")
    }
    elseif (@($SectionScope).Count -gt 0) {
        $allowedSections = @($SectionScope)
    }
    switch ($Parser) {
        "sundance_article" {
            return ConvertFrom-SundanceText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "cannes_selection" {
            return ConvertFrom-TitleByDirectorText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year -AllowedSections $allowedSections
        }
        "venice_selection" {
            return ConvertFrom-VeniceText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "oscars_ceremony" {
            $allowedOscarCategories = if (@($SectionScope).Count -gt 0) { @($SectionScope) } else { @("Best Picture", "International Feature Film", "Animated Feature Film") }
            return ConvertFrom-OscarsText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year -AllowedCategories $allowedOscarCategories
        }
        "wikipedia_oscars_awards" {
            $allowedOscarCategories = if (@($SectionScope).Count -gt 0) { @($SectionScope) } else { @("Best Picture", "International Feature Film", "Animated Feature Film") }
            return ConvertFrom-WikipediaOscarsHtml -Html $Html -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year -AllowedCategories $allowedOscarCategories
        }
        "golden_horse_awards" {
            return ConvertFrom-GoldenHorseAwardsText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "nyff_main_slate" {
            return ConvertFrom-NyffMainSlateText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "tidf_category" {
            return ConvertFrom-TidfCategoryHtml -Html $Html -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "kviff_archive_section" {
            return ConvertFrom-KviffArchiveHtml -Html $Html -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "taipeiff_tfa_nominees" {
            return ConvertFrom-TaipeiFilmAwardsHtml -Html $Html -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "taipeiff_new_talent" {
            return ConvertFrom-TaipeiNewTalentHtml -Html $Html -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year
        }
        "none" {
            return @()
        }
        default {
            return ConvertFrom-TitleByDirectorText -Text $text -Festival $Festival -Region $Region -SourceUrl $SourceUrl -Year $Year -AllowedSections $allowedSections
        }
    }
}

function Invoke-CurlTextRequest {
    param([Parameter(Mandatory = $true)][string]$Url)

    $curl = Get-Command "curl" -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        $curl = Get-Command "curl.exe" -CommandType Application -ErrorAction SilentlyContinue
    }
    if ($null -eq $curl) {
        throw "curl is not available for HTTP fallback."
    }

    $output = & $curl.Source --location --fail --silent --show-error `
        --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 FestivalLegalAvailabilityTracker/1.0" `
        --header "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" `
        --header "Accept-Language: en-US,en;q=0.9" `
        $Url
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output -join "`n"))) {
        throw "curl fallback failed for $Url."
    }

    return ($output -join "`n")
}

function Invoke-TextRequest {
    param([Parameter(Mandatory = $true)][string]$Url)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.UserAgent = $Script:UserAgent
    $request.Accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    $request.Headers.Add("Accept-Language", "en-US,en;q=0.9")

    $response = $null
    $stream = $null
    $memory = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 8192
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
        }
        $bytes = $memory.ToArray()
        $charset = $response.CharacterSet
        if ([string]::IsNullOrWhiteSpace($charset)) {
            $charset = "utf-8"
        }
        try {
            $encoding = [System.Text.Encoding]::GetEncoding($charset)
        }
        catch {
            $encoding = [System.Text.Encoding]::UTF8
        }
        return $encoding.GetString($bytes)
    }
    catch {
        return Invoke-CurlTextRequest -Url $Url
    }
    finally {
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-FestivalLineupRecords {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [switch]$RespectFestivalWindows
    )

    $records = New-Object System.Collections.Generic.List[object]
    $currentMonth = [int](Get-Date).Month
    $currentYear = [int](Get-Date).Year

    foreach ($festival in @($Config.festivals)) {
        if ((Get-ObjectProperty $festival "enabled" $true) -eq $false) {
            continue
        }

        if ($RespectFestivalWindows) {
            $window = Get-ObjectProperty $festival "lineupWindow"
            if ($null -ne $window) {
                $startMonth = [int](Get-ObjectProperty $window "startMonth" 1)
                $endMonth = [int](Get-ObjectProperty $window "endMonth" 12)
                $active = if ($startMonth -le $endMonth) {
                    $currentMonth -ge $startMonth -and $currentMonth -le $endMonth
                }
                else {
                    $currentMonth -ge $startMonth -or $currentMonth -le $endMonth
                }

                if (-not $active) {
                    continue
                }
            }
        }

        foreach ($source in @($festival.sources)) {
            if ((Get-ObjectProperty $source "enabled" $true) -eq $false) {
                continue
            }
            $url = Get-ObjectProperty $source "url"
            if ([string]::IsNullOrWhiteSpace($url)) {
                continue
            }

            try {
                Write-Host "Fetching lineup: $($festival.name) <$url>"
                $html = Invoke-TextRequest -Url $url
                $parser = Get-ObjectProperty $source "parser" "generic_title_by_director"
                $year = [int](Get-ObjectProperty $source "year" $currentYear)
                $sectionScope = @((Get-ObjectProperty $source "sectionScope" @()) | ForEach-Object { [string]$_ })
                $parsed = ConvertFrom-LineupHtml -Html $html -Festival $festival.name -Region $festival.region -SourceUrl $url -Parser $parser -Year $year -SectionScope $sectionScope
                foreach ($record in @($parsed)) {
                    $records.Add($record)
                }
            }
            catch {
                Write-Warning "Failed to fetch lineup source ${url}: $($_.Exception.Message)"
            }
        }
    }

    return $records
}

function Merge-FilmRecords {
    param(
        [object[]]$Existing,
        [object[]]$Incoming
    )

    $byId = @{}
    foreach ($film in @($Existing)) {
        if ($null -ne $film -and -not [string]::IsNullOrWhiteSpace($film.id)) {
            $byId[$film.id] = $film
        }
    }

    foreach ($film in @($Incoming)) {
        if ($null -eq $film -or [string]::IsNullOrWhiteSpace($film.id)) {
            continue
        }

        if ($byId.ContainsKey($film.id)) {
            $existingFilm = $byId[$film.id]
            foreach ($name in @("title", "original_title", "director", "festival", "region", "section", "source_url", "year", "film_year")) {
                $incomingValue = Get-ObjectProperty $film $name
                if ($null -ne $incomingValue -and -not [string]::IsNullOrWhiteSpace([string]$incomingValue)) {
                    if ($name -eq "section") {
                        $existingSections = @(([string](Get-ObjectProperty $existingFilm "section" "") -split '; ') | Where-Object { $_ })
                        $incomingSections = @(([string]$incomingValue -split '; ') | Where-Object { $_ })
                        $sections = @($existingSections + $incomingSections | Select-Object -Unique)
                        Set-RecordProperty -Record $existingFilm -Name "section" -Value ($sections -join '; ')
                    }
                    else {
                        Set-RecordProperty -Record $existingFilm -Name $name -Value $incomingValue
                    }
                }
            }
            Set-RecordProperty -Record $existingFilm -Name "updated_at" -Value (Get-Date).ToString("o")
        }
        else {
            $byId[$film.id] = $film
        }
    }

    return @($byId.Values | Sort-Object festival, title, director)
}

function Invoke-TmdbGet {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Query = @{}
    )

    $bearer = Get-EnvValue "TMDB_BEARER_TOKEN"
    $apiKey = Get-EnvValue "TMDB_API_KEY"
    if ([string]::IsNullOrWhiteSpace($bearer) -and [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Set TMDB_BEARER_TOKEN or TMDB_API_KEY before querying TMDb."
    }

    $headers = @{ "accept" = "application/json"; "User-Agent" = $Script:UserAgent }
    if (-not [string]::IsNullOrWhiteSpace($bearer)) {
        $headers["Authorization"] = "Bearer $bearer"
    }
    elseif (-not $Query.ContainsKey("api_key")) {
        $Query["api_key"] = $apiKey
    }

    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Query.Keys) {
        if ($null -ne $Query[$key] -and -not [string]::IsNullOrWhiteSpace([string]$Query[$key])) {
            $pairs.Add(("{0}={1}" -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$Query[$key])))
        }
    }

    $uri = "https://api.themoviedb.org/3$Path"
    if ($pairs.Count -gt 0) {
        $uri = "${uri}?$($pairs -join '&')"
    }

    return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
}

function Get-TmdbMovieCreditsDirector {
    param([Parameter(Mandatory = $true)][int]$MovieId)

    try {
        $credits = Invoke-TmdbGet -Path "/movie/$MovieId/credits"
        $directors = @($credits.crew | Where-Object { $_.job -eq "Director" } | ForEach-Object { $_.name })
        return ($directors -join ", ")
    }
    catch {
        return ""
    }
}

function Get-TmdbMovieMatch {
    param([Parameter(Mandatory = $true)][object]$Film)

    $query = @{
        "query" = $Film.title
        "include_adult" = "false"
        "language" = "en-US"
        "page" = "1"
    }
    $festivalName = [string](Get-ObjectProperty $Film "festival" "")
    $festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "festival_year" (Get-ObjectProperty $Film "year" $null))
    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year" $null)
    if ($festivalName -eq "Academy Awards" -and $null -ne $festivalYear -and $festivalYear -gt 1) {
        $filmYear = $festivalYear - 1
    }
    elseif ($null -eq $filmYear) {
        $filmYear = ConvertTo-OptionalInt $Film.year
    }
    if ($null -ne $filmYear -and $filmYear -gt 0) {
        $query["year"] = [string]$filmYear
    }

    $search = Invoke-TmdbGet -Path "/search/movie" -Query $query
    $best = $null
    $bestScore = 0.0
    $targetTitle = ConvertTo-NormalizedTitle $Film.title
    $targetDirector = ConvertTo-NormalizedTitle $Film.director
    $targetYear = if ($null -ne $filmYear) { $filmYear } else { 0 }

    foreach ($candidate in @($search.results | Select-Object -First 5)) {
        $score = 0.0
        $candidateTitle = ConvertTo-NormalizedTitle $candidate.title
        $candidateOriginalTitle = ConvertTo-NormalizedTitle $candidate.original_title

        if ($candidateTitle -eq $targetTitle -or $candidateOriginalTitle -eq $targetTitle) {
            $score += 0.55
        }
        elseif ($candidateTitle.Contains($targetTitle) -or $targetTitle.Contains($candidateTitle)) {
            $score += 0.35
        }

        $candidateYear = 0
        if ($candidate.release_date -match '^(\d{4})') {
            $candidateYear = [int]$Matches[1]
            if ($targetYear -gt 0 -and $candidateYear -eq $targetYear) {
                $score += 0.15
            }
            elseif ($targetYear -gt 0 -and [Math]::Abs($candidateYear - $targetYear) -le 1) {
                $score += 0.08
            }
        }

        $candidateDirector = ""
        if (-not [string]::IsNullOrWhiteSpace($targetDirector)) {
            $candidateDirector = Get-TmdbMovieCreditsDirector -MovieId ([int]$candidate.id)
            $normalizedCandidateDirector = ConvertTo-NormalizedTitle $candidateDirector
            if ($normalizedCandidateDirector.Contains($targetDirector) -or $targetDirector.Contains($normalizedCandidateDirector)) {
                $score += 0.30
            }
        }

        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = [pscustomobject]@{
                tmdb_id = [int]$candidate.id
                imdb_id = $null
                title = $candidate.title
                original_title = $candidate.original_title
                release_year = $candidateYear
                director = $candidateDirector
                confidence = [Math]::Min(1.0, [Math]::Round($score, 2))
                poster_url = $null
                overview = $null
                tmdb_rating = $null
            }
        }
    }

    if ($null -ne $best -and $best.confidence -ge 0.65) {
        try {
            $details = Invoke-TmdbGet -Path "/movie/$($best.tmdb_id)" -Query @{ "append_to_response" = "external_ids" }
            if ($null -ne $details.external_ids.imdb_id) {
                $best.imdb_id = $details.external_ids.imdb_id
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$details.poster_path)) {
                $best.poster_url = "https://image.tmdb.org/t/p/w500$($details.poster_path)"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$details.overview)) {
                $best.overview = [string]$details.overview
            }
            if ($null -ne $details.vote_average) {
                $best.tmdb_rating = [Math]::Round([double]$details.vote_average, 1)
            }
            if ([string]::IsNullOrWhiteSpace([string]$best.director)) {
                $best.director = Get-TmdbMovieCreditsDirector -MovieId ([int]$best.tmdb_id)
            }
        }
        catch {
            # External ids are useful but not required for tracking.
        }
        return $best
    }

    return $null
}

function Update-FilmMetadataFromTmdb {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][int]$TmdbId
    )

    $details = Invoke-TmdbGet -Path "/movie/$TmdbId" -Query @{ "append_to_response" = "external_ids" }
    if ($null -ne $details.external_ids.imdb_id -and [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "imdb_id" ""))) {
        Set-RecordProperty -Record $Film -Name "imdb_id" -Value ([string]$details.external_ids.imdb_id)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$details.poster_path)) {
        Set-RecordProperty -Record $Film -Name "poster_url" -Value ("https://image.tmdb.org/t/p/w500$($details.poster_path)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$details.overview)) {
        Set-RecordProperty -Record $Film -Name "overview" -Value ([string]$details.overview)
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "director" ""))) {
        $director = Get-TmdbMovieCreditsDirector -MovieId $TmdbId
        if (-not [string]::IsNullOrWhiteSpace($director)) {
            Set-RecordProperty -Record $Film -Name "director" -Value $director
        }
    }
    if ($null -ne $details.vote_average) {
        Set-RecordProperty -Record $Film -Name "tmdb_rating" -Value ([Math]::Round([double]$details.vote_average, 1))
    }
    if ([string]$details.release_date -match '^(?<year>(19|20)\d{2})') {
        Set-RecordProperty -Record $Film -Name "film_year" -Value ([int]$Matches.year)
    }
    Set-RecordProperty -Record $Film -Name "updated_at" -Value (Get-Date).ToString("o")

    return $Film
}

function Update-FilmMatches {
    param([object[]]$Films)

    foreach ($film in @($Films)) {
        $existingTmdbId = ConvertTo-OptionalInt $film.tmdb_id
        $existingConfidence = ConvertTo-OptionalDouble (Get-ObjectProperty $film "match_confidence" $null)
        $existingImdbId = [string](Get-ObjectProperty $film "imdb_id" "")
        if ($null -ne $existingTmdbId -and $existingTmdbId -gt 0) {
            $shouldRematch = (
                ($null -ne $existingConfidence -and $existingConfidence -lt 0.8) -and
                [string]::IsNullOrWhiteSpace($existingImdbId)
            )
            if (-not $shouldRematch) {
                try {
                    Update-FilmMetadataFromTmdb -Film $film -TmdbId $existingTmdbId | Out-Null
                }
                catch {
                    Write-Warning "TMDb metadata update failed for '$($film.title)': $($_.Exception.Message)"
                }
                continue
            }
        }
        if ((Get-ObjectProperty $film "tracking_status" "pending") -eq "available_found") {
            continue
        }

        try {
            $match = Get-TmdbMovieMatch -Film $film
            if ($null -ne $match) {
                Set-RecordProperty -Record $film -Name "tmdb_id" -Value $match.tmdb_id
                Set-RecordProperty -Record $film -Name "imdb_id" -Value $match.imdb_id
                if (-not [string]::IsNullOrWhiteSpace([string]$match.director)) {
                    Set-RecordProperty -Record $film -Name "director" -Value $match.director
                }
                Set-RecordProperty -Record $film -Name "match_confidence" -Value $match.confidence
                Set-RecordProperty -Record $film -Name "poster_url" -Value $match.poster_url
                Set-RecordProperty -Record $film -Name "overview" -Value (Repair-MojibakeText $match.overview)
                Set-RecordProperty -Record $film -Name "tmdb_rating" -Value $match.tmdb_rating
                if ($match.release_year -gt 0) {
                    Set-RecordProperty -Record $film -Name "film_year" -Value $match.release_year
                }
                Set-RecordProperty -Record $film -Name "needs_review" -Value ($match.confidence -lt 0.8)
            }
            else {
                Set-RecordProperty -Record $film -Name "needs_review" -Value $true
            }
            Set-RecordProperty -Record $film -Name "updated_at" -Value (Get-Date).ToString("o")
        }
        catch {
            Write-Warning "TMDb match failed for '$($film.title)': $($_.Exception.Message)"
        }
    }

    return $Films
}

function ConvertFrom-TmdbProviderResult {
    param([Parameter(Mandatory = $true)][object]$ProviderResult)

    $offers = New-Object System.Collections.Generic.List[object]
    $mapping = @{
        "flatrate" = "streaming_subscription"
        "free" = "streaming_free"
        "ads" = "streaming_free"
        "rent" = "digital_rent"
        "buy" = "digital_buy"
    }

    $results = Get-ObjectProperty $ProviderResult "results"
    if ($null -eq $results) {
        return @()
    }

    foreach ($regionProperty in $results.PSObject.Properties) {
        $country = $regionProperty.Name
        $entry = $regionProperty.Value
        $link = Get-ObjectProperty $entry "link"

        foreach ($category in $mapping.Keys) {
            $providers = Get-ObjectProperty $entry $category
            if ($null -eq $providers) {
                continue
            }

            foreach ($provider in @($providers)) {
                $providerName = Get-ObjectProperty $provider "provider_name" "Unknown"
                $offers.Add([pscustomobject]@{
                    type = $mapping[$category]
                    provider = $providerName
                    country = $country
                    source_url = $link
                    source_class = "tmdb"
                    raw_category = $category
                })
            }
        }
    }

    return $offers
}

function Get-TmdbWatchProviderOffers {
    param([Parameter(Mandatory = $true)][int]$TmdbId)

    $result = Invoke-TmdbGet -Path "/movie/$TmdbId/watch/providers"
    return ConvertFrom-TmdbProviderResult -ProviderResult $result
}

function Get-WatchmodeOffers {
    param([Parameter(Mandatory = $true)][object]$Film)

    $apiKey = Get-EnvValue "WATCHMODE_API_KEY"
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return @()
    }

    $filmTmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    if ($null -eq $filmTmdbId -or $filmTmdbId -le 0) {
        return @()
    }

    try {
        $searchUrl = "https://api.watchmode.com/v1/search/?apiKey=$([Uri]::EscapeDataString($apiKey))&search_field=tmdb_movie_id&search_value=$([Uri]::EscapeDataString([string]$filmTmdbId))"
        $search = Invoke-RestMethod -Uri $searchUrl -Method Get -ErrorAction Stop
        $watchmodeId = $null
        if ($null -ne $search.title_results -and @($search.title_results).Count -gt 0) {
            $watchmodeId = $search.title_results[0].id
        }
        if ($null -eq $watchmodeId) {
            return @()
        }

        $sourcesUrl = "https://api.watchmode.com/v1/title/$watchmodeId/sources/?apiKey=$([Uri]::EscapeDataString($apiKey))"
        $sources = Invoke-RestMethod -Uri $sourcesUrl -Method Get -ErrorAction Stop
        $offers = New-Object System.Collections.Generic.List[object]
        foreach ($source in @($sources)) {
            $sourceType = (Get-ObjectProperty $source "type" "").ToLowerInvariant()
            $mappedType = switch ($sourceType) {
                "sub" { "streaming_subscription" }
                "free" { "streaming_free" }
                "rent" { "digital_rent" }
                "buy" { "digital_buy" }
                default { $null }
            }
            if ($null -eq $mappedType) {
                continue
            }

            $offers.Add([pscustomobject]@{
                type = $mappedType
                provider = (Get-ObjectProperty $source "name" "Unknown")
                country = (Get-ObjectProperty $source "region" "")
                source_url = (Get-ObjectProperty $source "web_url" "")
                source_class = "watchmode"
                raw_category = $sourceType
            })
        }
        return $offers
    }
    catch {
        Write-Warning "Watchmode lookup failed for '$($Film.title)': $($_.Exception.Message)"
        return @()
    }
}

function Test-AllowedAuthorizedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][object]$AuthorizedConfig
    )

    try {
        $uri = [Uri]$Url
    }
    catch {
        return $false
    }

    $host = $uri.Host.ToLowerInvariant()
    foreach ($domain in @($AuthorizedConfig.allowedDomains)) {
        $domainValue = ([string]$domain).ToLowerInvariant()
        if ($host -eq $domainValue -or $host.EndsWith(".$domainValue")) {
            return $true
        }
    }

    return $false
}

function Test-AuthorizedArchiveLicense {
    param(
        [Parameter(Mandatory = $true)][object]$Metadata,
        [Parameter(Mandatory = $true)][object]$AuthorizedConfig
    )

    $licenseUrl = [string](Get-ObjectProperty $Metadata.metadata "licenseurl" "")
    $rights = [string](Get-ObjectProperty $Metadata.metadata "rights" "")
    $combined = "$licenseUrl $rights".ToLowerInvariant()

    foreach ($fragment in @($AuthorizedConfig.allowedLicenseFragments)) {
        if ($combined.Contains(([string]$fragment).ToLowerInvariant())) {
            return $true
        }
    }

    return $false
}

function Get-ArchiveIdentifierFromUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $uri = [Uri]$Url
        if ($uri.Host.ToLowerInvariant() -notin @("archive.org", "www.archive.org")) {
            return $null
        }
        $segments = @($uri.AbsolutePath.Trim("/") -split "/")
        $detailsIndex = [Array]::IndexOf($segments, "details")
        if ($detailsIndex -ge 0 -and $segments.Count -gt ($detailsIndex + 1)) {
            return $segments[$detailsIndex + 1]
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AuthorizedSourceOffers {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][object]$AuthorizedConfig
    )

    $offers = New-Object System.Collections.Generic.List[object]
    $urls = @()
    $rawUrls = Get-ObjectProperty $Film "authorized_source_urls" @()
    if ($rawUrls -is [string]) {
        $urls = @($rawUrls -split '[,\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        $urls = @($rawUrls | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    foreach ($url in $urls) {
        if (-not (Test-AllowedAuthorizedUrl -Url $url -AuthorizedConfig $AuthorizedConfig)) {
            Write-Warning "Skipping non-whitelisted authorized source URL for '$($Film.title)': $url"
            continue
        }

        $archiveIdentifier = Get-ArchiveIdentifierFromUrl -Url $url
        if (-not [string]::IsNullOrWhiteSpace($archiveIdentifier)) {
            try {
                $metadata = Invoke-RestMethod -Uri "https://archive.org/metadata/$([Uri]::EscapeDataString($archiveIdentifier))" -Method Get -ErrorAction Stop
                if (-not (Test-AuthorizedArchiveLicense -Metadata $metadata -AuthorizedConfig $AuthorizedConfig)) {
                    Write-Warning "Archive.org item lacks accepted license metadata: $url"
                    continue
                }

                foreach ($file in @($metadata.files)) {
                    $fileName = [string](Get-ObjectProperty $file "name" "")
                    if ([string]::IsNullOrWhiteSpace($fileName)) {
                        continue
                    }

                    $lowerName = $fileName.ToLowerInvariant()
                    foreach ($extension in @($AuthorizedConfig.torrentExtensions)) {
                        if ($lowerName.EndsWith(([string]$extension).ToLowerInvariant())) {
                            $offers.Add([pscustomobject]@{
                                type = "authorized_torrent"
                                provider = "Internet Archive"
                                country = ""
                                source_url = $url
                                source_class = "official_or_whitelist"
                                raw_category = "torrent"
                            })
                        }
                    }
                    foreach ($extension in @($AuthorizedConfig.downloadExtensions)) {
                        if ($lowerName.EndsWith(([string]$extension).ToLowerInvariant())) {
                            $offers.Add([pscustomobject]@{
                                type = "authorized_download"
                                provider = "Internet Archive"
                                country = ""
                                source_url = $url
                                source_class = "official_or_whitelist"
                                raw_category = "download"
                            })
                        }
                    }
                }
            }
            catch {
                Write-Warning "Failed to inspect Archive.org source ${url}: $($_.Exception.Message)"
            }
            continue
        }

        try {
            $html = Invoke-TextRequest -Url $url
            $lowerHtml = $html.ToLowerInvariant()
            foreach ($extension in @($AuthorizedConfig.torrentExtensions)) {
                if ($lowerHtml.Contains(([string]$extension).ToLowerInvariant())) {
                    $offers.Add([pscustomobject]@{
                        type = "authorized_torrent"
                        provider = ([Uri]$url).Host
                        country = ""
                        source_url = $url
                        source_class = "official_or_whitelist"
                        raw_category = "torrent"
                    })
                }
            }
            foreach ($extension in @($AuthorizedConfig.downloadExtensions)) {
                if ($lowerHtml.Contains(([string]$extension).ToLowerInvariant()) -or $lowerHtml.Contains("download")) {
                    $offers.Add([pscustomobject]@{
                        type = "authorized_download"
                        provider = ([Uri]$url).Host
                        country = ""
                        source_url = $url
                        source_class = "official_or_whitelist"
                        raw_category = "download"
                    })
                    break
                }
            }
        }
        catch {
            Write-Warning "Failed to inspect authorized source ${url}: $($_.Exception.Message)"
        }
    }

    return $offers
}

function Select-UniqueOffers {
    param([object[]]$Offers)

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($offer in @($Offers)) {
        $key = "{0}|{1}|{2}|{3}" -f $offer.type, $offer.provider, $offer.country, $offer.source_url
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($offer)
        }
    }
    return $unique
}

function Get-LegalAvailabilityOffers {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][object]$AuthorizedConfig
    )

    $offers = New-Object System.Collections.Generic.List[object]
    $filmTmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    if ($null -ne $filmTmdbId -and $filmTmdbId -gt 0) {
        try {
            foreach ($offer in @(Get-TmdbWatchProviderOffers -TmdbId $filmTmdbId)) {
                $offers.Add($offer)
            }
        }
        catch {
            Write-Warning "TMDb watch provider lookup failed for '$($Film.title)': $($_.Exception.Message)"
        }

        foreach ($offer in @(Get-WatchmodeOffers -Film $Film)) {
            $offers.Add($offer)
        }
    }

    foreach ($offer in @(Get-AuthorizedSourceOffers -Film $Film -AuthorizedConfig $AuthorizedConfig)) {
        $offers.Add($offer)
    }

    return Select-UniqueOffers -Offers $offers
}

function New-FirstAvailabilityEvent {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][object[]]$Offers
    )

    if (@($Offers).Count -eq 0) {
        return $null
    }

    $date = (Get-Date).ToString("yyyy-MM-dd")
    $types = @($Offers | ForEach-Object { $_.type } | Where-Object { $_ } | Sort-Object -Unique)
    $providers = @($Offers | ForEach-Object { $_.provider } | Where-Object { $_ } | Sort-Object -Unique)
    $countries = @($Offers | ForEach-Object { $_.country } | Where-Object { $_ } | Sort-Object -Unique)
    $urls = @($Offers | ForEach-Object { $_.source_url } | Where-Object { $_ } | Sort-Object -Unique)
    $canonicalKey = Get-CanonicalFilmKey -Film $Film
    $eventId = New-StableId ("first-availability|{0}" -f $canonicalKey)

    [pscustomobject]@{
        id = $eventId
        film_id = $Film.id
        canonical_key = $canonicalKey
        film_title = $Film.title
        director = $Film.director
        festival = $Film.festival
        event_date = $date
        availability_types = $types
        providers = $providers
        countries = $countries
        source_urls = $urls
        offers = $Offers
        needs_review = [bool]$Film.needs_review
        notion_page_id = $null
        created_at = (Get-Date).ToString("o")
    }
}

function Get-FilmCanonicalKey {
    param([Parameter(Mandatory = $true)][object]$Film)

    $filmTmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    if ($null -ne $filmTmdbId -and $filmTmdbId -gt 0) {
        return "tmdb:$filmTmdbId"
    }
    if (-not [string]::IsNullOrWhiteSpace($Film.imdb_id)) {
        return "imdb:$($Film.imdb_id)"
    }

    $year = if ($null -ne $Film.year) { [string]$Film.year } else { "" }
    return "title:${year}:$(ConvertTo-NormalizedTitle $Film.title)"
}

function ConvertFrom-NotionEventPage {
    param([Parameter(Mandatory = $true)][object]$Page)

    $typesText = Get-NotionTextProperty -Page $Page -Name "Availability Types"
    $typeProperty = Get-ObjectProperty $Page.properties "Availability Types"
    $types = @()
    if ($null -ne $typeProperty -and $null -ne $typeProperty.multi_select) {
        $types = @($typeProperty.multi_select | ForEach-Object { $_.name } | Where-Object { $_ })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($typesText)) {
        $types = @($typesText -split '[,\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $filmRelationIds = @(Get-NotionRelationIds -Page $Page -Name "Film")
    [pscustomobject]@{
        id = Get-NotionTextProperty -Page $Page -Name "Tracker ID"
        film_id = Get-NotionTextProperty -Page $Page -Name "Film Tracker ID"
        film_relation_ids = $filmRelationIds
        film_title = Get-NotionTextProperty -Page $Page -Name "Film Title"
        director = Get-NotionTextProperty -Page $Page -Name "Director"
        festival = Get-NotionTextProperty -Page $Page -Name "Festival"
        event_date = Get-NotionTextProperty -Page $Page -Name "Event Date"
        availability_types = $types
        providers = @((Get-NotionTextProperty -Page $Page -Name "Providers") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        countries = @((Get-NotionTextProperty -Page $Page -Name "Countries") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        source_urls = @((Get-NotionTextProperty -Page $Page -Name "Source URLs") -split '[,\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        notion_page_id = $Page.id
        created_at = $Page.created_time
    }
}

function Import-NotionEvents {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($page in @(Get-NotionDatabasePages -DatabaseId $DatabaseId)) {
        $event = ConvertTo-MutableRecord (ConvertFrom-NotionEventPage -Page $page)
        if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $event "id" ""))) {
            $events.Add($event)
        }
    }
    return $events
}

function Get-CanonicalFilmKey {
    param([Parameter(Mandatory = $true)][object]$Film)

    $filmTmdbId = ConvertTo-OptionalInt (Get-ObjectProperty $Film "tmdb_id" $null)
    if ($null -ne $filmTmdbId -and $filmTmdbId -gt 0) {
        return "tmdb:$filmTmdbId"
    }

    $imdbId = [string](Get-ObjectProperty $Film "imdb_id" "")
    if (-not [string]::IsNullOrWhiteSpace($imdbId)) {
        return "imdb:$($imdbId.Trim().ToLowerInvariant())"
    }

    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year" $null)
    $yearPart = if ($null -ne $filmYear -and $filmYear -gt 0) { [string]$filmYear } else { "" }
    $director = [string](Get-ObjectProperty $Film "director" "")
    return "title:${yearPart}:$(ConvertTo-NormalizedTitle $Film.title):$(ConvertTo-NormalizedTitle $director)"
}

function New-CanonicalFilmFromSelection {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $canonicalKey = Get-CanonicalFilmKey -Film $Selection
    [pscustomobject]@{
        id = New-StableId "film|$canonicalKey"
        canonical_key = $canonicalKey
        title = [string](Get-ObjectProperty $Selection "title" "")
        original_title = [string](Get-ObjectProperty $Selection "original_title" (Get-ObjectProperty $Selection "title" ""))
        director = [string](Get-ObjectProperty $Selection "director" "")
        film_year = ConvertTo-OptionalInt (Get-ObjectProperty $Selection "film_year" $null)
        tmdb_id = ConvertTo-OptionalInt (Get-ObjectProperty $Selection "tmdb_id" $null)
        imdb_id = [string](Get-ObjectProperty $Selection "imdb_id" "")
        match_confidence = ConvertTo-OptionalDouble (Get-ObjectProperty $Selection "match_confidence" $null)
        poster_url = [string](Get-ObjectProperty $Selection "poster_url" "")
        overview = [string](Get-ObjectProperty $Selection "overview" "")
        tmdb_rating = ConvertTo-OptionalDouble (Get-ObjectProperty $Selection "tmdb_rating" $null)
        imdb_rating = ConvertTo-OptionalDouble (Get-ObjectProperty $Selection "imdb_rating" $null)
        imdb_votes = ConvertTo-OptionalInt (Get-ObjectProperty $Selection "imdb_votes" $null)
        imdb_rating_checked_at = [string](Get-ObjectProperty $Selection "imdb_rating_checked_at" "")
        rating_source = [string](Get-ObjectProperty $Selection "rating_source" "")
        tracking_status = [string](Get-ObjectProperty $Selection "tracking_status" "pending")
        first_available_date = [string](Get-ObjectProperty $Selection "first_available_date" "")
        last_checked = [string](Get-ObjectProperty $Selection "last_checked" "")
        needs_review = [bool](Get-ObjectProperty $Selection "needs_review" $false)
        authorized_source_urls = @((Get-ObjectProperty $Selection "authorized_source_urls" @()) | Where-Object { $_ })
        notion_page_id = $null
        created_at = (Get-Date).ToString("o")
        updated_at = (Get-Date).ToString("o")
    }
}

function Merge-CanonicalFilmRecords {
    param([object[]]$Selections)

    $byKey = [ordered]@{}
    foreach ($selection in @($Selections)) {
        $film = New-CanonicalFilmFromSelection -Selection $selection
        $key = $film.canonical_key
        if (-not $byKey.Contains($key)) {
            $byKey[$key] = $film
            continue
        }

        $existing = $byKey[$key]
        foreach ($name in @("title", "original_title", "director", "imdb_id", "poster_url", "overview", "rating_source", "imdb_rating_checked_at", "first_available_date", "last_checked")) {
            $existingValue = [string](Get-ObjectProperty $existing $name "")
            $incomingValue = [string](Get-ObjectProperty $film $name "")
            if ([string]::IsNullOrWhiteSpace($existingValue) -and -not [string]::IsNullOrWhiteSpace($incomingValue)) {
                Set-RecordProperty -Record $existing -Name $name -Value $incomingValue
            }
        }

        foreach ($name in @("film_year", "tmdb_id", "match_confidence", "tmdb_rating", "imdb_rating", "imdb_votes")) {
            $existingValue = ConvertTo-OptionalDouble (Get-ObjectProperty $existing $name $null)
            $incomingValue = ConvertTo-OptionalDouble (Get-ObjectProperty $film $name $null)
            if (($null -eq $existingValue -or $existingValue -le 0) -and $null -ne $incomingValue -and $incomingValue -gt 0) {
                Set-RecordProperty -Record $existing -Name $name -Value (Get-ObjectProperty $film $name $null)
            }
        }

        if ((Get-ObjectProperty $existing "tracking_status" "pending") -ne "available_found" -and (Get-ObjectProperty $film "tracking_status" "pending") -eq "available_found") {
            Set-RecordProperty -Record $existing -Name "tracking_status" -Value "available_found"
        }
        Set-RecordProperty -Record $existing -Name "needs_review" -Value ([bool](Get-ObjectProperty $existing "needs_review" $false) -or [bool](Get-ObjectProperty $film "needs_review" $false))
    }

    return @($byKey.Values)
}

function Add-FirstAvailabilityEvents {
    param(
        [object]$Films = @(),
        [object]$ExistingEvents = @(),
        [Parameter(Mandatory = $true)][object]$AuthorizedConfig
    )

    $filmItems = @($Films)
    $existingEventItems = @($ExistingEvents)
    $eventsByFilmId = @{}
    $eventsByCanonicalKey = @{}
    foreach ($event in $existingEventItems) {
        if ($null -ne $event.film_id) {
            $eventsByFilmId[$event.film_id] = $event
        }
        if (-not [string]::IsNullOrWhiteSpace($event.canonical_key)) {
            $eventsByCanonicalKey[$event.canonical_key] = $event
        }
        elseif (-not [string]::IsNullOrWhiteSpace($event.id)) {
            $eventsByCanonicalKey[$event.id] = $event
        }
    }

    $newEvents = New-Object System.Collections.Generic.List[object]
    foreach ($film in $filmItems) {
        if ((Get-ObjectProperty $film "tracking_status" "pending") -ne "pending") {
            continue
        }
        $canonicalKey = Get-FilmCanonicalKey -Film $film
        $canonicalEventId = New-StableId ("first-availability|{0}" -f $canonicalKey)
        if ($eventsByFilmId.ContainsKey($film.id) -or $eventsByCanonicalKey.ContainsKey($canonicalKey) -or $eventsByCanonicalKey.ContainsKey($canonicalEventId)) {
            Set-RecordProperty -Record $film -Name "tracking_status" -Value "available_found"
            continue
        }

        $offers = @(Get-LegalAvailabilityOffers -Film $film -AuthorizedConfig $AuthorizedConfig)
        Set-RecordProperty -Record $film -Name "last_checked" -Value (Get-Date).ToString("yyyy-MM-dd")
        if ($offers.Count -gt 0) {
            $event = New-FirstAvailabilityEvent -Film $film -Offers $offers
            $newEvents.Add($event)
            $eventsByFilmId[$film.id] = $event
            $eventsByCanonicalKey[$canonicalKey] = $event
            Set-RecordProperty -Record $film -Name "tracking_status" -Value "available_found"
            Set-RecordProperty -Record $film -Name "first_available_date" -Value $event.event_date
            Set-RecordProperty -Record $film -Name "updated_at" -Value (Get-Date).ToString("o")
        }
    }

    return [pscustomobject]@{
        films = $filmItems
        new_events = @($newEvents.ToArray())
        all_events = @($existingEventItems + @($newEvents.ToArray()))
    }
}

function Invoke-NotionRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PATCH")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )

    $token = Get-EnvValue "NOTION_TOKEN"
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Set NOTION_TOKEN before using Notion sync."
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Notion-Version" = $Script:NotionVersion
        "Content-Type" = "application/json; charset=utf-8"
        "User-Agent" = $Script:UserAgent
    }

    $parameters = @{
        Uri = "https://api.notion.com$Path"
        Method = $Method
        Headers = $headers
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 30
        $parameters["Body"] = [System.Text.Encoding]::UTF8.GetBytes($json)
    }

    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @parameters
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                throw
            }

            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $isTransientStatus = $statusCode -in @(408, 409, 425, 429, 500, 502, 503, 504)
            $isConnectionFailure = $_.Exception -is [System.Net.WebException]
            if (-not $isTransientStatus -and -not $isConnectionFailure) {
                throw
            }

            $delaySeconds = [Math]::Min(20, [Math]::Pow(2, $attempt))
            Write-Warning "Notion request failed; retrying in $delaySeconds second(s). Attempt $attempt of $maxAttempts."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-NotionTextProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = Get-ObjectProperty $Page.properties $Name
    if ($null -eq $property) {
        return ""
    }

    $type = Get-ObjectProperty $property "type"
    switch ($type) {
        "title" { return (@($property.title) | ForEach-Object { $_.plain_text }) -join "" }
        "rich_text" { return (@($property.rich_text) | ForEach-Object { $_.plain_text }) -join "" }
        "url" { return [string]$property.url }
        "select" { return [string](Get-ObjectProperty $property.select "name" "") }
        "number" { return [string]$property.number }
        "date" { return [string](Get-ObjectProperty $property.date "start" "") }
        default { return "" }
    }
}

function ConvertFrom-NotionFilmPage {
    param([Parameter(Mandatory = $true)][object]$Page)

    $authorizedUrls = Get-NotionTextProperty -Page $Page -Name "Authorized Source URLs"
    $yearText = Get-NotionTextProperty -Page $Page -Name "Festival Year"
    if ([string]::IsNullOrWhiteSpace($yearText)) {
        $yearText = Get-NotionTextProperty -Page $Page -Name "Year"
    }
    $yearValue = $null
    if ($yearText -match '\d{4}') {
        $yearValue = [int]$Matches[0]
    }
    $filmYearText = Get-NotionTextProperty -Page $Page -Name "Film Year"
    $filmYearValue = $null
    if ($filmYearText -match '\d{4}') {
        $filmYearValue = [int]$Matches[0]
    }
    $tmdbText = Get-NotionTextProperty -Page $Page -Name "TMDb ID"
    $tmdbValue = $null
    if ($tmdbText -match '\d+') {
        $tmdbValue = [int]$Matches[0]
    }
    $confidenceText = Get-NotionTextProperty -Page $Page -Name "Match Confidence"
    $confidenceValue = 0
    if ($confidenceText -match '^\d+(\.\d+)?$') {
        $confidenceValue = [double]$confidenceText
    }

    $record = [pscustomobject]@{
        id = Get-NotionTextProperty -Page $Page -Name "Tracker ID"
        title = Get-NotionTextProperty -Page $Page -Name "Film Title"
        original_title = Get-NotionTextProperty -Page $Page -Name "Original Title"
        director = Get-NotionTextProperty -Page $Page -Name "Director"
        year = $yearValue
        festival_year = $yearValue
        film_year = $filmYearValue
        festival = Get-NotionTextProperty -Page $Page -Name "Festival"
        region = Get-NotionTextProperty -Page $Page -Name "Region"
        section = Get-NotionTextProperty -Page $Page -Name "Section"
        source_url = Get-NotionTextProperty -Page $Page -Name "Source URL"
        tmdb_id = $tmdbValue
        imdb_id = Get-NotionTextProperty -Page $Page -Name "IMDb ID"
        match_confidence = $confidenceValue
        poster_url = Get-NotionTextProperty -Page $Page -Name "Poster URL"
        overview = Get-NotionTextProperty -Page $Page -Name "Overview"
        tmdb_rating = ConvertTo-OptionalDouble (Get-NotionTextProperty -Page $Page -Name "TMDb Rating")
        imdb_rating = ConvertTo-OptionalDouble (Get-NotionTextProperty -Page $Page -Name "IMDb Rating")
        imdb_votes = ConvertTo-OptionalInt (Get-NotionTextProperty -Page $Page -Name "IMDb Votes")
        imdb_rating_checked_at = Get-NotionTextProperty -Page $Page -Name "IMDb Rating Checked At"
        rating_source = Get-NotionTextProperty -Page $Page -Name "Rating Source"
        tracking_status = Get-NotionTextProperty -Page $Page -Name "Tracking Status"
        first_available_date = Get-NotionTextProperty -Page $Page -Name "First Available Date"
        last_checked = Get-NotionTextProperty -Page $Page -Name "Last Checked"
        needs_review = [bool](Get-ObjectProperty (Get-ObjectProperty $Page.properties "Needs Review") "checkbox" $false)
        authorized_source_urls = @($authorizedUrls -split '[,\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        notion_page_id = $Page.id
        created_at = $Page.created_time
        updated_at = $Page.last_edited_time
    }

    return Repair-RecordTextFields -Record $record
}

function Get-NotionDatabasePages {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    $pages = New-Object System.Collections.Generic.List[object]
    $cursor = $null
    do {
        $body = @{ page_size = 100 }
        if (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $body["start_cursor"] = $cursor
        }
        $response = Invoke-NotionRequest -Method "POST" -Path "/v1/databases/$DatabaseId/query" -Body $body
        foreach ($page in @($response.results)) {
            $pages.Add($page)
        }
        $cursor = $response.next_cursor
    } while ($response.has_more -eq $true)

    return $pages
}

function Import-NotionFilms {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    $films = New-Object System.Collections.Generic.List[object]
    foreach ($page in @(Get-NotionDatabasePages -DatabaseId $DatabaseId)) {
            $film = ConvertTo-MutableRecord (ConvertFrom-NotionFilmPage -Page $page)
        if (-not [string]::IsNullOrWhiteSpace($film.id)) {
            if ([string]::IsNullOrWhiteSpace((Get-ObjectProperty $film "tracking_status" ""))) {
                Set-RecordProperty -Record $film -Name "tracking_status" -Value "pending"
            }
            $films.Add($film)
        }
    }

    return $films
}

function ConvertFrom-NotionCanonicalFilmPage {
    param([Parameter(Mandatory = $true)][object]$Page)

    $tmdbText = Get-NotionTextProperty -Page $Page -Name "TMDb ID"
    $tmdbValue = $null
    if ($tmdbText -match '\d+') { $tmdbValue = [int]$Matches[0] }

    $filmYearText = Get-NotionTextProperty -Page $Page -Name "Film Year"
    $filmYearValue = $null
    if ($filmYearText -match '\d{4}') { $filmYearValue = [int]$Matches[0] }

    $record = [pscustomobject]@{
        id = Get-NotionTextProperty -Page $Page -Name "Film ID"
        canonical_key = Get-NotionTextProperty -Page $Page -Name "Canonical Key"
        title = Get-NotionTextProperty -Page $Page -Name "Film Title"
        original_title = Get-NotionTextProperty -Page $Page -Name "Original Title"
        director = Get-NotionTextProperty -Page $Page -Name "Director"
        film_year = $filmYearValue
        tmdb_id = $tmdbValue
        imdb_id = Get-NotionTextProperty -Page $Page -Name "IMDb ID"
        match_confidence = ConvertTo-OptionalDouble (Get-NotionTextProperty -Page $Page -Name "Match Confidence")
        poster_url = Get-NotionTextProperty -Page $Page -Name "Poster URL"
        overview = Get-NotionTextProperty -Page $Page -Name "Overview"
        tmdb_rating = ConvertTo-OptionalDouble (Get-NotionTextProperty -Page $Page -Name "TMDb Rating")
        imdb_rating = ConvertTo-OptionalDouble (Get-NotionTextProperty -Page $Page -Name "IMDb Rating")
        imdb_votes = ConvertTo-OptionalInt (Get-NotionTextProperty -Page $Page -Name "IMDb Votes")
        imdb_rating_checked_at = Get-NotionTextProperty -Page $Page -Name "IMDb Rating Checked At"
        rating_source = Get-NotionTextProperty -Page $Page -Name "Rating Source"
        tracking_status = Get-NotionTextProperty -Page $Page -Name "Tracking Status"
        first_available_date = Get-NotionTextProperty -Page $Page -Name "First Available Date"
        last_checked = Get-NotionTextProperty -Page $Page -Name "Last Checked"
        needs_review = [bool](Get-ObjectProperty (Get-ObjectProperty $Page.properties "Needs Review") "checkbox" $false)
        notion_page_id = $Page.id
        created_at = $Page.created_time
        updated_at = $Page.last_edited_time
    }
    if ([string]::IsNullOrWhiteSpace($record.id)) {
        $record.id = New-StableId ("film|$($record.canonical_key)")
    }
    if ([string]::IsNullOrWhiteSpace($record.tracking_status)) {
        $record.tracking_status = "pending"
    }
    return Repair-RecordTextFields -Record $record
}

function Import-NotionCanonicalFilms {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    $films = New-Object System.Collections.Generic.List[object]
    foreach ($page in @(Get-NotionDatabasePages -DatabaseId $DatabaseId)) {
        $film = ConvertTo-MutableRecord (ConvertFrom-NotionCanonicalFilmPage -Page $page)
        if (-not [string]::IsNullOrWhiteSpace($film.canonical_key)) {
            $films.Add($film)
        }
    }
    return $films
}

function Get-NotionRelationIds {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = Get-ObjectProperty $Page.properties $Name
    if ($null -eq $property) { return @() }
    return @($property.relation | ForEach-Object { $_.id } | Where-Object { $_ })
}

function Import-NotionSelections {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    $selections = New-Object System.Collections.Generic.List[object]
    foreach ($page in @(Get-NotionDatabasePages -DatabaseId $DatabaseId)) {
        $selection = ConvertTo-MutableRecord (ConvertFrom-NotionFilmPage -Page $page)
        Set-RecordProperty -Record $selection -Name "film_relation_ids" -Value @(Get-NotionRelationIds -Page $page -Name "Film")
        if (-not [string]::IsNullOrWhiteSpace($selection.id)) {
            $selections.Add($selection)
        }
    }
    return $selections
}

function New-RichTextProperty {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ rich_text = @() }
    }
    if ($Text.Length -gt 1900) {
        $Text = $Text.Substring(0, 1900) + "`n[truncated]"
    }
    return @{ rich_text = @(@{ text = @{ content = $Text } }) }
}

function New-TitleProperty {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Text = "Untitled"
    }
    return @{ title = @(@{ text = @{ content = $Text } }) }
}

function New-UrlProperty {
    param([AllowNull()][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return @{ url = $null }
    }
    return @{ url = $Url }
}

function ConvertTo-NotionFilmProperties {
    param([Parameter(Mandatory = $true)][object]$Film)

    Repair-RecordTextFields -Record $Film | Out-Null

    $filmTitle = [string](ConvertTo-Scalar $Film.title)
    $originalTitle = [string](ConvertTo-Scalar $Film.original_title)
    $director = [string](ConvertTo-Scalar $Film.director)
    $festival = [string](ConvertTo-Scalar $Film.festival)
    $region = [string](ConvertTo-Scalar $Film.region)
    $section = [string](ConvertTo-Scalar $Film.section)
    $sourceUrl = [string](ConvertTo-Scalar $Film.source_url)
    $imdbId = [string](ConvertTo-Scalar $Film.imdb_id)
    $posterUrl = [string](ConvertTo-Scalar $Film.poster_url)
    $overview = [string](ConvertTo-Scalar $Film.overview)
    $trackingStatus = [string](ConvertTo-Scalar $Film.tracking_status)
    if ([string]::IsNullOrWhiteSpace($trackingStatus)) {
        $trackingStatus = "pending"
    }
    $firstAvailableDate = [string](ConvertTo-Scalar $Film.first_available_date)
    $lastChecked = [string](ConvertTo-Scalar $Film.last_checked)
    $imdbRatingCheckedAt = [string](ConvertTo-Scalar (Get-ObjectProperty $Film "imdb_rating_checked_at" ""))
    $ratingSource = [string](ConvertTo-Scalar (Get-ObjectProperty $Film "rating_source" ""))

    $properties = @{
        "Film Title" = New-TitleProperty $filmTitle
        "Tracker ID" = New-RichTextProperty ([string](ConvertTo-Scalar $Film.id))
        "Original Title" = New-RichTextProperty $originalTitle
        "Director" = New-RichTextProperty $director
        "Festival" = New-RichTextProperty $festival
        "Region" = New-RichTextProperty $region
        "Section" = New-RichTextProperty $section
        "Source URL" = New-UrlProperty $sourceUrl
        "IMDb ID" = New-RichTextProperty $imdbId
        "Poster URL" = New-UrlProperty $posterUrl
        "Overview" = New-RichTextProperty $overview
        "Rating Source" = New-RichTextProperty $ratingSource
        "Tracking Status" = @{ select = @{ name = $trackingStatus } }
        "Authorized Source URLs" = New-RichTextProperty ((@($Film.authorized_source_urls) | Where-Object { $_ }) -join "`n")
    }

    $festivalYear = ConvertTo-OptionalInt $Film.year
    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year" $null)
    $filmTmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    $filmConfidence = ConvertTo-OptionalDouble $Film.match_confidence
    $filmTmdbRating = ConvertTo-OptionalDouble $Film.tmdb_rating
    $filmImdbRating = ConvertTo-OptionalDouble (Get-ObjectProperty $Film "imdb_rating" $null)
    $filmImdbVotes = ConvertTo-OptionalInt (Get-ObjectProperty $Film "imdb_votes" $null)
    if ($null -ne $festivalYear -and $festivalYear -gt 0) {
        $properties["Festival Year"] = @{ number = $festivalYear }
    }
    if ($null -ne $filmYear -and $filmYear -gt 0) {
        $properties["Film Year"] = @{ number = $filmYear }
    }
    if ($null -ne $filmTmdbId -and $filmTmdbId -gt 0) {
        $properties["TMDb ID"] = @{ number = $filmTmdbId }
    }
    if ($null -ne $filmConfidence) {
        $properties["Match Confidence"] = @{ number = $filmConfidence }
    }
    if ($null -ne $filmTmdbRating) {
        $properties["TMDb Rating"] = @{ number = $filmTmdbRating }
    }
    if ($null -ne $filmImdbRating) {
        $properties["IMDb Rating"] = @{ number = $filmImdbRating }
    }
    if ($null -ne $filmImdbVotes) {
        $properties["IMDb Votes"] = @{ number = $filmImdbVotes }
    }
    if (-not [string]::IsNullOrWhiteSpace($imdbRatingCheckedAt)) {
        $properties["IMDb Rating Checked At"] = @{ date = @{ start = $imdbRatingCheckedAt } }
    }
    if (-not [string]::IsNullOrWhiteSpace($firstAvailableDate)) {
        $properties["First Available Date"] = @{ date = @{ start = $firstAvailableDate } }
    }
    if (-not [string]::IsNullOrWhiteSpace($lastChecked)) {
        $properties["Last Checked"] = @{ date = @{ start = $lastChecked } }
    }

    return $properties
}

function ConvertTo-NotionCanonicalFilmProperties {
    param([Parameter(Mandatory = $true)][object]$Film)

    Repair-RecordTextFields -Record $Film | Out-Null
    $trackingStatus = [string](Get-ObjectProperty $Film "tracking_status" "pending")
    if ([string]::IsNullOrWhiteSpace($trackingStatus)) { $trackingStatus = "pending" }

    $properties = @{
        "Film Title" = New-TitleProperty ([string](Get-ObjectProperty $Film "title" ""))
        "Film ID" = New-RichTextProperty ([string](Get-ObjectProperty $Film "id" ""))
        "Canonical Key" = New-RichTextProperty ([string](Get-ObjectProperty $Film "canonical_key" ""))
        "Original Title" = New-RichTextProperty ([string](Get-ObjectProperty $Film "original_title" ""))
        "Director" = New-RichTextProperty ([string](Get-ObjectProperty $Film "director" ""))
        "IMDb ID" = New-RichTextProperty ([string](Get-ObjectProperty $Film "imdb_id" ""))
        "Poster URL" = New-UrlProperty ([string](Get-ObjectProperty $Film "poster_url" ""))
        "Overview" = New-RichTextProperty ([string](Get-ObjectProperty $Film "overview" ""))
        "Rating Source" = New-RichTextProperty ([string](Get-ObjectProperty $Film "rating_source" ""))
        "Tracking Status" = @{ select = @{ name = $trackingStatus } }
        "Needs Review" = @{ checkbox = [bool](Get-ObjectProperty $Film "needs_review" $false) }
    }

    foreach ($pair in @(
        @{ name = "Film Year"; value = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year" $null) },
        @{ name = "TMDb ID"; value = ConvertTo-OptionalInt (Get-ObjectProperty $Film "tmdb_id" $null) },
        @{ name = "Match Confidence"; value = ConvertTo-OptionalDouble (Get-ObjectProperty $Film "match_confidence" $null) },
        @{ name = "TMDb Rating"; value = ConvertTo-OptionalDouble (Get-ObjectProperty $Film "tmdb_rating" $null) },
        @{ name = "IMDb Rating"; value = ConvertTo-OptionalDouble (Get-ObjectProperty $Film "imdb_rating" $null) },
        @{ name = "IMDb Votes"; value = ConvertTo-OptionalInt (Get-ObjectProperty $Film "imdb_votes" $null) }
    )) {
        if ($null -ne $pair.value) {
            $properties[$pair.name] = @{ number = $pair.value }
        }
    }

    foreach ($pair in @(
        @{ name = "IMDb Rating Checked At"; value = [string](Get-ObjectProperty $Film "imdb_rating_checked_at" "") },
        @{ name = "First Available Date"; value = [string](Get-ObjectProperty $Film "first_available_date" "") },
        @{ name = "Last Checked"; value = [string](Get-ObjectProperty $Film "last_checked" "") }
    )) {
        if (-not [string]::IsNullOrWhiteSpace($pair.value)) {
            $properties[$pair.name] = @{ date = @{ start = $pair.value } }
        }
    }

    return $properties
}

function Get-NotionPageCover {
    param([Parameter(Mandatory = $true)][object]$Film)

    $posterUrl = [string](ConvertTo-Scalar $Film.poster_url)
    if ([string]::IsNullOrWhiteSpace($posterUrl)) {
        return $null
    }

    return @{ type = "external"; external = @{ url = $posterUrl } }
}

function Find-NotionPageByTrackerId {
    param(
        [Parameter(Mandatory = $true)][string]$DatabaseId,
        [Parameter(Mandatory = $true)][string]$TrackerId
    )

    $body = @{
        page_size = 1
        filter = @{
            property = "Tracker ID"
            rich_text = @{ equals = $TrackerId }
        }
    }
    $response = Invoke-NotionRequest -Method "POST" -Path "/v1/databases/$DatabaseId/query" -Body $body
    if (@($response.results).Count -gt 0) {
        return $response.results[0]
    }
    return $null
}

function Find-NotionCanonicalFilmPage {
    param(
        [Parameter(Mandatory = $true)][string]$DatabaseId,
        [Parameter(Mandatory = $true)][string]$CanonicalKey
    )

    $body = @{
        page_size = 1
        filter = @{
            property = "Canonical Key"
            rich_text = @{ equals = $CanonicalKey }
        }
    }
    $response = Invoke-NotionRequest -Method "POST" -Path "/v1/databases/$DatabaseId/query" -Body $body
    if (@($response.results).Count -gt 0) { return $response.results[0] }
    return $null
}

function Sync-NotionCanonicalFilm {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][string]$DatabaseId
    )

    $properties = ConvertTo-NotionCanonicalFilmProperties -Film $Film
    $page = $null
    if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "notion_page_id" ""))) {
        $page = [pscustomobject]@{ id = $Film.notion_page_id }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "canonical_key" ""))) {
        $page = Find-NotionCanonicalFilmPage -DatabaseId $DatabaseId -CanonicalKey $Film.canonical_key
    }

    $cover = Get-NotionPageCover -Film $Film
    if ($null -eq $page) {
        $body = @{ parent = @{ database_id = $DatabaseId }; properties = $properties }
        if ($null -ne $cover) { $body["cover"] = $cover }
        $created = Invoke-NotionRequest -Method "POST" -Path "/v1/pages" -Body $body
        Set-RecordProperty -Record $Film -Name "notion_page_id" -Value $created.id
    }
    else {
        $body = @{ properties = $properties }
        if ($null -ne $cover) { $body["cover"] = $cover }
        $updated = Invoke-NotionRequest -Method "PATCH" -Path "/v1/pages/$($page.id)" -Body $body
        Set-RecordProperty -Record $Film -Name "notion_page_id" -Value $updated.id
    }

    return $Film
}

function Set-NotionPageFilmRelation {
    param(
        [Parameter(Mandatory = $true)][string]$PageId,
        [Parameter(Mandatory = $true)][string]$FilmPageId
    )

    Invoke-NotionRequest -Method "PATCH" -Path "/v1/pages/$PageId" -Body @{
        properties = @{
            "Film" = @{ relation = @(@{ id = $FilmPageId }) }
        }
    } | Out-Null
}

function Sync-NotionFilm {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][string]$DatabaseId
    )

    $properties = ConvertTo-NotionFilmProperties -Film $Film
    $page = $null
    if (-not [string]::IsNullOrWhiteSpace($Film.notion_page_id)) {
        $page = [pscustomobject]@{ id = $Film.notion_page_id }
    }
    else {
        $page = Find-NotionPageByTrackerId -DatabaseId $DatabaseId -TrackerId $Film.id
    }

    if ($null -eq $page) {
        $body = @{
            parent = @{ database_id = $DatabaseId }
            properties = $properties
        }
        $cover = Get-NotionPageCover -Film $Film
        if ($null -ne $cover) {
            $body["cover"] = $cover
        }
        $created = Invoke-NotionRequest -Method "POST" -Path "/v1/pages" -Body $body
        $Film.notion_page_id = $created.id
    }
    else {
        $body = @{ properties = $properties }
        $cover = Get-NotionPageCover -Film $Film
        if ($null -ne $cover) {
            $body["cover"] = $cover
        }
        $updated = Invoke-NotionRequest -Method "PATCH" -Path "/v1/pages/$($page.id)" -Body $body
        $Film.notion_page_id = $updated.id
    }

    return $Film
}

function ConvertTo-NotionEventProperties {
    param([Parameter(Mandatory = $true)][object]$Event)

    $title = "{0} - {1}" -f $Event.film_title, $Event.event_date
    $multiSelect = @($Event.availability_types | ForEach-Object { @{ name = [string]$_ } })
    $properties = @{
        "Event Title" = New-TitleProperty $title
        "Tracker ID" = New-RichTextProperty $Event.id
        "Film Tracker ID" = New-RichTextProperty $Event.film_id
        "Film Title" = New-RichTextProperty $Event.film_title
        "Director" = New-RichTextProperty $Event.director
        "Festival" = New-RichTextProperty $Event.festival
        "Event Date" = @{ date = @{ start = $Event.event_date } }
        "Availability Types" = @{ multi_select = $multiSelect }
        "Providers" = New-RichTextProperty ((@($Event.providers) | Where-Object { $_ }) -join ", ")
        "Countries" = New-RichTextProperty ((@($Event.countries) | Where-Object { $_ }) -join ", ")
        "Source URLs" = New-RichTextProperty ((@($Event.source_urls) | Where-Object { $_ }) -join "`n")
    }

    $filmNotionPageId = [string](Get-ObjectProperty $Event "film_notion_page_id" "")
    if (-not [string]::IsNullOrWhiteSpace($filmNotionPageId)) {
        $properties["Film"] = @{ relation = @(@{ id = $filmNotionPageId }) }
    }

    return $properties
}

function Sync-NotionEvent {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][string]$DatabaseId,
        [hashtable]$FilmPageIdByTrackerId = @{}
    )

    $filmTrackerId = [string](Get-ObjectProperty $Event "film_id" "")
    if (-not [string]::IsNullOrWhiteSpace($filmTrackerId) -and $FilmPageIdByTrackerId.ContainsKey($filmTrackerId)) {
        Set-RecordProperty -Record $Event -Name "film_notion_page_id" -Value $FilmPageIdByTrackerId[$filmTrackerId]
    }

    $properties = ConvertTo-NotionEventProperties -Event $Event
    $page = Find-NotionPageByTrackerId -DatabaseId $DatabaseId -TrackerId $Event.id
    if ($null -eq $page) {
        $body = @{
            parent = @{ database_id = $DatabaseId }
            properties = $properties
        }
        $created = Invoke-NotionRequest -Method "POST" -Path "/v1/pages" -Body $body
        $Event.notion_page_id = $created.id
    }
    else {
        $body = @{ properties = $properties }
        $updated = Invoke-NotionRequest -Method "PATCH" -Path "/v1/pages/$($page.id)" -Body $body
        $Event.notion_page_id = $updated.id
    }

    return $Event
}

function Ensure-NotionFilmMetadataProperties {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    $body = @{
        properties = @{
            "Poster URL" = @{ url = @{} }
            "Overview" = @{ rich_text = @{} }
            "TMDb Rating" = @{ number = @{ format = "number" } }
            "IMDb Rating" = @{ number = @{ format = "number" } }
            "IMDb Votes" = @{ number = @{ format = "number" } }
            "IMDb Rating Checked At" = @{ date = @{} }
            "Rating Source" = @{ rich_text = @{} }
            "Film Year" = @{ number = @{ format = "number" } }
            "Festival Year" = @{ number = @{ format = "number" } }
        }
    }
    Invoke-NotionRequest -Method "PATCH" -Path "/v1/databases/$DatabaseId" -Body $body | Out-Null
}

function Ensure-NotionEventRelationProperty {
    param(
        [Parameter(Mandatory = $true)][string]$EventsDatabaseId,
        [Parameter(Mandatory = $true)][string]$FilmsDatabaseId
    )

    $body = @{
        properties = @{
            "Film" = @{
                relation = @{
                    database_id = $FilmsDatabaseId
                    type = "single_property"
                    single_property = @{}
                }
            }
        }
    }
    Invoke-NotionRequest -Method "PATCH" -Path "/v1/databases/$EventsDatabaseId" -Body $body | Out-Null
}

function Ensure-NotionThreeTableSchema {
    param(
        [Parameter(Mandatory = $true)][string]$FilmsDatabaseId,
        [Parameter(Mandatory = $true)][string]$SelectionsDatabaseId,
        [Parameter(Mandatory = $true)][string]$EventsDatabaseId
    )

    $filmProperties = @{
        "Film ID" = @{ rich_text = @{} }
        "Canonical Key" = @{ rich_text = @{} }
        "Original Title" = @{ rich_text = @{} }
        "Director" = @{ rich_text = @{} }
        "Film Year" = @{ number = @{ format = "number" } }
        "TMDb ID" = @{ number = @{ format = "number" } }
        "IMDb ID" = @{ rich_text = @{} }
        "Match Confidence" = @{ number = @{ format = "number" } }
        "Poster URL" = @{ url = @{} }
        "Overview" = @{ rich_text = @{} }
        "TMDb Rating" = @{ number = @{ format = "number" } }
        "IMDb Rating" = @{ number = @{ format = "number" } }
        "IMDb Votes" = @{ number = @{ format = "number" } }
        "IMDb Rating Checked At" = @{ date = @{} }
        "Rating Source" = @{ rich_text = @{} }
        "Tracking Status" = @{ select = @{ options = @(
            @{ name = "pending"; color = "yellow" },
            @{ name = "available_found"; color = "green" },
            @{ name = "needs_review"; color = "red" }
        ) } }
        "First Available Date" = @{ date = @{} }
        "Last Checked" = @{ date = @{} }
        "Needs Review" = @{ checkbox = @{} }
    }
    Invoke-NotionRequest -Method "PATCH" -Path "/v1/databases/$FilmsDatabaseId" -Body @{ properties = $filmProperties } | Out-Null

    Invoke-NotionRequest -Method "PATCH" -Path "/v1/databases/$SelectionsDatabaseId" -Body @{
        properties = @{
            "Film" = @{
                relation = @{
                    database_id = $FilmsDatabaseId
                    type = "single_property"
                    single_property = @{}
                }
            }
        }
    } | Out-Null

    Invoke-NotionRequest -Method "PATCH" -Path "/v1/databases/$EventsDatabaseId" -Body @{
        properties = @{
            "Film" = @{
                relation = @{
                    database_id = $FilmsDatabaseId
                    type = "single_property"
                    single_property = @{}
                }
            }
        }
    } | Out-Null
}

function New-NotionCanonicalFilmsDatabase {
    param(
        [Parameter(Mandatory = $true)][string]$SelectionsDatabaseId,
        [string]$Title = "Films"
    )

    $selectionDb = Invoke-NotionRequest -Method "GET" -Path "/v1/databases/$SelectionsDatabaseId"
    $parent = $selectionDb.parent
    if ($null -eq $parent) {
        throw "Could not determine parent for selections database $SelectionsDatabaseId."
    }

    $body = @{
        parent = $parent
        title = @(@{ type = "text"; text = @{ content = $Title } })
        properties = @{
            "Film Title" = @{ title = @{} }
            "Film ID" = @{ rich_text = @{} }
            "Canonical Key" = @{ rich_text = @{} }
        }
    }
    $created = Invoke-NotionRequest -Method "POST" -Path "/v1/databases" -Body $body
    return $created
}

function Sync-NotionState {
    param(
        [object[]]$Films = @(),
        [object[]]$NewEvents = @()
    )

    $canonicalFilmsDb = Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"
    $selectionsDb = Get-EnvValue "NOTION_SELECTIONS_DATABASE_ID"
    $filmsDb = Get-EnvValue "NOTION_FILMS_DATABASE_ID"
    $eventsDb = Get-EnvValue "NOTION_EVENTS_DATABASE_ID"
    if ([string]::IsNullOrWhiteSpace($selectionsDb)) {
        $selectionsDb = $filmsDb
    }
    if ([string]::IsNullOrWhiteSpace($eventsDb)) {
        throw "Set NOTION_EVENTS_DATABASE_ID before syncing Notion."
    }

    if (-not [string]::IsNullOrWhiteSpace($canonicalFilmsDb)) {
        if ([string]::IsNullOrWhiteSpace($selectionsDb)) {
            throw "Set NOTION_SELECTIONS_DATABASE_ID or NOTION_FILMS_DATABASE_ID before syncing three-table Notion state."
        }

        Ensure-NotionThreeTableSchema -FilmsDatabaseId $canonicalFilmsDb -SelectionsDatabaseId $selectionsDb -EventsDatabaseId $eventsDb

        $filmItems = @($Films)
        $selectionItems = @($filmItems | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $_ "festival" "")) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $_ "section" "")) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $_ "source_url" ""))
        })

        if (@($selectionItems).Count -gt 0) {
            $canonicalFilms = @(Merge-CanonicalFilmRecords -Selections $selectionItems)
        }
        else {
            $canonicalFilms = $filmItems
        }

        $syncedCanonicalFilms = New-Object System.Collections.Generic.List[object]
        $filmPageIdByCanonicalKey = @{}
        $filmPageIdByTrackerId = @{}
        foreach ($film in @($canonicalFilms)) {
            if ([string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $film "canonical_key" ""))) {
                Set-RecordProperty -Record $film -Name "canonical_key" -Value (Get-CanonicalFilmKey -Film $film)
            }
            $synced = Sync-NotionCanonicalFilm -Film $film -DatabaseId $canonicalFilmsDb
            $syncedCanonicalFilms.Add($synced)
            $key = [string](Get-ObjectProperty $synced "canonical_key" "")
            $pageId = [string](Get-ObjectProperty $synced "notion_page_id" "")
            $trackerId = [string](Get-ObjectProperty $synced "id" "")
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($pageId)) {
                $filmPageIdByCanonicalKey[$key] = $pageId
            }
            if (-not [string]::IsNullOrWhiteSpace($trackerId) -and -not [string]::IsNullOrWhiteSpace($pageId)) {
                $filmPageIdByTrackerId[$trackerId] = $pageId
            }
        }

        $syncedSelections = New-Object System.Collections.Generic.List[object]
        foreach ($selection in @($selectionItems)) {
            $syncedSelection = Sync-NotionFilm -Film $selection -DatabaseId $selectionsDb
            $syncedSelections.Add($syncedSelection)
            $key = Get-CanonicalFilmKey -Film $selection
            if ($filmPageIdByCanonicalKey.ContainsKey($key)) {
                Set-NotionPageFilmRelation -PageId $syncedSelection.notion_page_id -FilmPageId $filmPageIdByCanonicalKey[$key]
            }
        }

        foreach ($selection in @($selectionItems)) {
            $key = Get-CanonicalFilmKey -Film $selection
            $trackerId = [string](Get-ObjectProperty $selection "id" "")
            if (-not [string]::IsNullOrWhiteSpace($trackerId) -and $filmPageIdByCanonicalKey.ContainsKey($key)) {
                $filmPageIdByTrackerId[$trackerId] = $filmPageIdByCanonicalKey[$key]
            }
        }

        $syncedEvents = New-Object System.Collections.Generic.List[object]
        foreach ($event in @($NewEvents)) {
            $canonicalKey = [string](Get-ObjectProperty $event "canonical_key" "")
            if (-not [string]::IsNullOrWhiteSpace($canonicalKey) -and $filmPageIdByCanonicalKey.ContainsKey($canonicalKey)) {
                Set-RecordProperty -Record $event -Name "film_notion_page_id" -Value $filmPageIdByCanonicalKey[$canonicalKey]
            }
            $syncedEvents.Add((Sync-NotionEvent -Event $event -DatabaseId $eventsDb -FilmPageIdByTrackerId $filmPageIdByTrackerId))
        }

        return [pscustomobject]@{
            films = @($syncedCanonicalFilms.ToArray())
            selections = @($syncedSelections.ToArray())
            events = @($syncedEvents.ToArray())
        }
    }

    if ([string]::IsNullOrWhiteSpace($filmsDb)) {
        throw "Set NOTION_FILMS_DATABASE_ID before syncing legacy Notion state."
    }

    Ensure-NotionFilmMetadataProperties -DatabaseId $filmsDb
    Ensure-NotionEventRelationProperty -EventsDatabaseId $eventsDb -FilmsDatabaseId $filmsDb

    $syncedFilms = New-Object System.Collections.Generic.List[object]
    foreach ($film in @($Films)) {
        $syncedFilms.Add((Sync-NotionFilm -Film $film -DatabaseId $filmsDb))
    }

    $filmPageIdByTrackerId = @{}
    foreach ($film in @($syncedFilms.ToArray())) {
        $trackerId = [string](Get-ObjectProperty $film "id" "")
        $pageId = [string](Get-ObjectProperty $film "notion_page_id" "")
        if (-not [string]::IsNullOrWhiteSpace($trackerId) -and -not [string]::IsNullOrWhiteSpace($pageId)) {
            $filmPageIdByTrackerId[$trackerId] = $pageId
        }
    }

    $syncedEvents = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($NewEvents)) {
        $syncedEvents.Add((Sync-NotionEvent -Event $event -DatabaseId $eventsDb -FilmPageIdByTrackerId $filmPageIdByTrackerId))
    }

    return [pscustomobject]@{
        films = @($syncedFilms.ToArray())
        events = @($syncedEvents.ToArray())
    }
}

function Invoke-NotionThreeTableMigration {
    param(
        [string]$FilmsDatabaseId = (Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"),
        [string]$SelectionsDatabaseId = (Get-EnvValue "NOTION_SELECTIONS_DATABASE_ID"),
        [string]$EventsDatabaseId = (Get-EnvValue "NOTION_EVENTS_DATABASE_ID"),
        [switch]$Apply
    )

    if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId)) {
        $SelectionsDatabaseId = Get-EnvValue "NOTION_FILMS_DATABASE_ID"
    }
    if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId) -or [string]::IsNullOrWhiteSpace($EventsDatabaseId)) {
        throw "Set NOTION_SELECTIONS_DATABASE_ID (or NOTION_FILMS_DATABASE_ID) and NOTION_EVENTS_DATABASE_ID before migration."
    }

    if ([string]::IsNullOrWhiteSpace($FilmsDatabaseId) -and $Apply) {
        $created = New-NotionCanonicalFilmsDatabase -SelectionsDatabaseId $SelectionsDatabaseId
        $FilmsDatabaseId = $created.id
    }
    if ([string]::IsNullOrWhiteSpace($FilmsDatabaseId)) {
        $FilmsDatabaseId = "DRY_RUN_WOULD_CREATE_FILMS_DATABASE"
    }

    $selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
    $canonicalFilms = @(Merge-CanonicalFilmRecords -Selections $selections)
    $conflicts = @(
        $selections |
            Group-Object { Get-CanonicalFilmKey -Film $_ } |
            Where-Object { @($_.Group | Select-Object -ExpandProperty title -Unique).Count -gt 1 -or @($_.Group | Select-Object -ExpandProperty director -Unique).Count -gt 1 } |
            ForEach-Object {
                [pscustomobject]@{
                    canonical_key = $_.Name
                    count = $_.Count
                    titles = @($_.Group | Select-Object -ExpandProperty title -Unique)
                    directors = @($_.Group | Select-Object -ExpandProperty director -Unique)
                }
            }
    )

    if (-not $Apply) {
        return [pscustomobject]@{
            mode = "dry_run"
            films_database_id = $FilmsDatabaseId
            selections_database_id = $SelectionsDatabaseId
            events_database_id = $EventsDatabaseId
            selections = $selections.Count
            films = $canonicalFilms.Count
            relations_to_write = @($selections | Where-Object { @($_.film_relation_ids).Count -eq 0 }).Count
            conflicts = $conflicts
        }
    }

    Ensure-NotionThreeTableSchema -FilmsDatabaseId $FilmsDatabaseId -SelectionsDatabaseId $SelectionsDatabaseId -EventsDatabaseId $EventsDatabaseId

    $filmPageIdByCanonicalKey = @{}
    foreach ($film in $canonicalFilms) {
        $synced = Sync-NotionCanonicalFilm -Film $film -DatabaseId $FilmsDatabaseId
        $filmPageIdByCanonicalKey[$synced.canonical_key] = $synced.notion_page_id
    }

    $selectionRelations = 0
    $selectionIdToFilmPageId = @{}
    foreach ($selection in $selections) {
        $key = Get-CanonicalFilmKey -Film $selection
        if (-not $filmPageIdByCanonicalKey.ContainsKey($key)) { continue }
        $filmPageId = $filmPageIdByCanonicalKey[$key]
        $selectionIdToFilmPageId[$selection.id] = $filmPageId
        if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $selection "notion_page_id" ""))) {
            Set-NotionPageFilmRelation -PageId $selection.notion_page_id -FilmPageId $filmPageId
            $selectionRelations++
        }
    }

    $eventRelations = 0
    foreach ($eventPage in @(Get-NotionDatabasePages -DatabaseId $EventsDatabaseId)) {
        $filmTrackerId = Get-NotionTextProperty -Page $eventPage -Name "Film Tracker ID"
        if (-not [string]::IsNullOrWhiteSpace($filmTrackerId) -and $selectionIdToFilmPageId.ContainsKey($filmTrackerId)) {
            Set-NotionPageFilmRelation -PageId $eventPage.id -FilmPageId $selectionIdToFilmPageId[$filmTrackerId]
            $eventRelations++
        }
    }

    return [pscustomobject]@{
        mode = "apply"
        films_database_id = $FilmsDatabaseId
        selections_database_id = $SelectionsDatabaseId
        events_database_id = $EventsDatabaseId
        selections = $selections.Count
        films = $canonicalFilms.Count
        selection_relations_written = $selectionRelations
        event_relations_written = $eventRelations
        conflicts = $conflicts
    }
}

function New-NotionTrackerDatabases {
    param([Parameter(Mandatory = $true)][string]$ParentPageId)

    $filmDbBody = @{
        parent = @{ type = "page_id"; page_id = $ParentPageId }
        title = @(@{ type = "text"; text = @{ content = "Festival Films" } })
        properties = @{
            "Film Title" = @{ title = @{} }
            "Tracker ID" = @{ rich_text = @{} }
            "Original Title" = @{ rich_text = @{} }
            "Director" = @{ rich_text = @{} }
            "Festival Year" = @{ number = @{ format = "number" } }
            "Film Year" = @{ number = @{ format = "number" } }
            "Festival" = @{ rich_text = @{} }
            "Region" = @{ rich_text = @{} }
            "Section" = @{ rich_text = @{} }
            "Source URL" = @{ url = @{} }
            "TMDb ID" = @{ number = @{ format = "number" } }
            "IMDb ID" = @{ rich_text = @{} }
            "Match Confidence" = @{ number = @{ format = "percent" } }
            "Poster URL" = @{ url = @{} }
            "Overview" = @{ rich_text = @{} }
            "TMDb Rating" = @{ number = @{ format = "number" } }
            "IMDb Rating" = @{ number = @{ format = "number" } }
            "IMDb Votes" = @{ number = @{ format = "number" } }
            "IMDb Rating Checked At" = @{ date = @{} }
            "Rating Source" = @{ rich_text = @{} }
            "Tracking Status" = @{ select = @{ options = @(
                @{ name = "pending"; color = "yellow" },
                @{ name = "available_found"; color = "green" },
                @{ name = "needs_review"; color = "red" }
            ) } }
            "First Available Date" = @{ date = @{} }
            "Last Checked" = @{ date = @{} }
            "Authorized Source URLs" = @{ rich_text = @{} }
        }
    }

    $filmsDb = Invoke-NotionRequest -Method "POST" -Path "/v1/databases" -Body $filmDbBody

    $eventDbBody = @{
        parent = @{ type = "page_id"; page_id = $ParentPageId }
        title = @(@{ type = "text"; text = @{ content = "First Legal Availability Events" } })
        properties = @{
            "Event Title" = @{ title = @{} }
            "Film" = @{
                relation = @{
                    database_id = $filmsDb.id
                    type = "single_property"
                    single_property = @{}
                }
            }
            "Tracker ID" = @{ rich_text = @{} }
            "Film Tracker ID" = @{ rich_text = @{} }
            "Film Title" = @{ rich_text = @{} }
            "Director" = @{ rich_text = @{} }
            "Festival" = @{ rich_text = @{} }
            "Event Date" = @{ date = @{} }
            "Availability Types" = @{ multi_select = @{ options = @(
                @{ name = "streaming_subscription"; color = "blue" },
                @{ name = "streaming_free"; color = "green" },
                @{ name = "digital_rent"; color = "orange" },
                @{ name = "digital_buy"; color = "yellow" },
                @{ name = "authorized_download"; color = "purple" },
                @{ name = "authorized_torrent"; color = "pink" }
            ) } }
            "Providers" = @{ rich_text = @{} }
            "Countries" = @{ rich_text = @{} }
            "Source URLs" = @{ rich_text = @{} }
        }
    }

    $eventsDb = Invoke-NotionRequest -Method "POST" -Path "/v1/databases" -Body $eventDbBody

    return [pscustomobject]@{
        films_database_id = $filmsDb.id
        events_database_id = $eventsDb.id
        films_database_url = $filmsDb.url
        events_database_url = $eventsDb.url
    }
}

function Invoke-FestivalTracker {
    param(
        [ValidateSet("Lineups", "Availability", "All")][string]$Mode = "All",
        [string]$ConfigPath = (Join-Path (Get-Location) "config/festivals.json"),
        [string]$AuthorizedSourcesPath = (Join-Path (Get-Location) "config/authorized_sources.json"),
        [string]$StateDir = (Join-Path (Get-Location) ".tracker"),
        [int]$OmdbMaxUpdates = 20,
        [switch]$UseNotion,
        [switch]$RespectFestivalWindows,
        [switch]$DryRun
    )

    $filmsPath = Join-Path $StateDir "films.json"
    $eventsPath = Join-Path $StateDir "events.json"
    $config = Read-JsonFile -Path $ConfigPath
    $authorizedConfig = Read-JsonFile -Path $AuthorizedSourcesPath
    if ($null -eq $config) {
        throw "Missing tracker config: $ConfigPath"
    }
    if ($null -eq $authorizedConfig) {
        throw "Missing authorized sources config: $AuthorizedSourcesPath"
    }

    $films = @()
    $importedFilmsFromNotion = $false
    $useThreeTableNotion = $UseNotion -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"))
    if ($UseNotion) {
        if ($useThreeTableNotion -and ($Mode -eq "Availability")) {
            $canonicalFilmsDb = Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"
            try {
                $films = @(Import-NotionCanonicalFilms -DatabaseId $canonicalFilmsDb)
                $importedFilmsFromNotion = $true
                Write-Host "Imported $($films.Count) canonical film records from Notion."
            }
            catch {
                Write-Warning "Could not import canonical films from Notion: $($_.Exception.Message)"
            }
        }
        else {
            $filmsDb = if ($useThreeTableNotion) { Get-EnvValue "NOTION_SELECTIONS_DATABASE_ID" } else { Get-EnvValue "NOTION_FILMS_DATABASE_ID" }
            if ([string]::IsNullOrWhiteSpace($filmsDb)) {
                $filmsDb = Get-EnvValue "NOTION_FILMS_DATABASE_ID"
            }
            if (-not [string]::IsNullOrWhiteSpace($filmsDb)) {
                try {
                    $films = if ($useThreeTableNotion) { @(Import-NotionSelections -DatabaseId $filmsDb) } else { @(Import-NotionFilms -DatabaseId $filmsDb) }
                    $importedFilmsFromNotion = $true
                    Write-Host "Imported $($films.Count) film records from Notion."
                }
                catch {
                    Write-Warning "Could not import films from Notion: $($_.Exception.Message)"
                }
            }
        }
    }

    if (-not $importedFilmsFromNotion) {
        $localFilms = @(Read-JsonFile -Path $filmsPath -Default @())
        $films = @(Merge-FilmRecords -Existing $films -Incoming $localFilms)
    }

    if ($Mode -eq "Lineups" -or $Mode -eq "All") {
        $incoming = @(Get-FestivalLineupRecords -Config $config -RespectFestivalWindows:$RespectFestivalWindows)
        $films = @(Merge-FilmRecords -Existing $films -Incoming $incoming)
        Write-Host "Lineup sync found $($incoming.Count) records; merged total is $($films.Count)."
    }

    $newEvents = @()
    $events = @()
    if ($UseNotion) {
        $eventsDb = Get-EnvValue "NOTION_EVENTS_DATABASE_ID"
        if (-not [string]::IsNullOrWhiteSpace($eventsDb)) {
            try {
                $events = @(Import-NotionEvents -DatabaseId $eventsDb)
                Write-Host "Imported $($events.Count) availability events from Notion."
            }
            catch {
                Write-Warning "Could not import availability events from Notion: $($_.Exception.Message)"
            }
        }
    }
    else {
        $events = @(Read-JsonFile -Path $eventsPath -Default @())
    }

    if ($Mode -eq "Availability" -or $Mode -eq "All") {
        if (@($films).Count -gt 0) {
            $films = @(Update-FilmMatches -Films $films)
            $films = @(Update-FilmImdbDatasetRatings -Films $films -StateDir $StateDir)
            $films = @(Update-FilmOmdbRatings -Films $films -MaxUpdates $OmdbMaxUpdates)
            $availabilityResult = Add-FirstAvailabilityEvents -Films $films -ExistingEvents $events -AuthorizedConfig $authorizedConfig
            $films = @($availabilityResult.films)
            $newEvents = @($availabilityResult.new_events)
            $events = @($availabilityResult.all_events)
            Write-Host "Availability sync created $($newEvents.Count) first-availability events."
        }
        else {
            Write-Host "Availability sync skipped; no films are available to check."
        }
    }

    if (-not $DryRun) {
        Write-JsonFile -Path $filmsPath -Value $films
        Write-JsonFile -Path $eventsPath -Value $events
        if ($UseNotion) {
            Sync-NotionState -Films $films -NewEvents $newEvents | Out-Null
        }
    }
    else {
        Write-Host "DryRun enabled; no local state or Notion changes were written."
    }

    return [pscustomobject]@{
        films_count = $films.Count
        events_count = $events.Count
        new_events_count = $newEvents.Count
        state_dir = $StateDir
    }
}

Export-ModuleMember -Function *-*
