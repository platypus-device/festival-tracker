$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

$Script:Failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        $Script:Failures += 1
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        $Script:Failures += 1
        Write-Host "FAIL: $Message. Expected '$Expected', got '$Actual'." -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

$mojibakeName = Repair-MojibakeText ("Caitlin {0}Sonny{1} SHIEH" -f (New-StringFromCodePoints @(0x00E2, 0x20AC, 0x0153)), (New-StringFromCodePoints @(0x00E2, 0x20AC, 0x009D)))
$expectedSmartQuoteName = "Caitlin {0}Sonny{1} SHIEH" -f [char]0x201C, [char]0x201D
Assert-Equal $expectedSmartQuoteName $mojibakeName "repairs mojibake smart quotes"

$mojibakeCredit = Repair-MojibakeText ("Scriptwriter{0}Editor{1}LI Luo" -f (New-StringFromCodePoints @(0x00EF, 0x00BC, 0x008F)), (New-StringFromCodePoints @(0x00EF, 0x00BD, 0x009C)))
Assert-Equal "Scriptwriter/Editor|LI Luo" $mojibakeCredit "repairs mojibake full-width separators"

$cannesHtml = @"
<html>
<body>
<h2>In Competition</h2>
<p>Feature films</p>
<p>THE PHOENICIAN SCHEME by Wes ANDERSON</p>
<p>SOUND OF FALLING by Mascha SCHILINSKI</p>
</body>
</html>
"@

$cannes = @(ConvertFrom-LineupHtml -Html $cannesHtml -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Parser "cannes_selection" -Year 2025)
Assert-Equal 2 $cannes.Count "parses Cannes title-by-director records"
Assert-Equal "THE PHOENICIAN SCHEME" $cannes[0].title "keeps Cannes title"
Assert-Equal "Wes ANDERSON" $cannes[0].director "keeps Cannes director"
Assert-Equal "In Competition - Feature films" $cannes[0].section "captures section heading"

$byInTitleHtml = @"
<html>
<body>
<h2>In Competition</h2>
<p>Feature films</p>
<p>ALGUMAS COISAS QUE ACONTECEM AO LADO DE UM RIO (A FEW THINGS HAPPENING BY A RIVER) by Daniel SOARES</p>
</body>
</html>
"@
$byInTitle = @(ConvertFrom-LineupHtml -Html $byInTitleHtml -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Parser "cannes_selection" -Year 2026)
Assert-Equal 1 $byInTitle.Count "parses title containing BY without splitting early"
Assert-Equal "ALGUMAS COISAS QUE ACONTECEM AO LADO DE UM RIO (A FEW THINGS HAPPENING BY A RIVER)" $byInTitle[0].title "keeps full title with BY"
Assert-Equal "Daniel SOARES" $byInTitle[0].director "extracts director after final by"

$sundanceHtml = @"
<html>
<body>
<h2>U.S. DRAMATIC COMPETITION</h2>
<p>Plainclothes / U.S.A. (Director: Carmen Emmi, Producers: Arthur Landon) - A story.</p>
<p>Rebuilding / U.S.A. (Director: Max Walker-Silverman, Screenwriter: Max Walker-Silverman) - A story.</p>
</body>
</html>
"@

$sundance = @(ConvertFrom-LineupHtml -Html $sundanceHtml -Festival "Sundance" -Region "United States" -SourceUrl "https://example.test/sundance" -Parser "sundance_article" -Year 2025)
Assert-Equal 2 $sundance.Count "parses Sundance article records"
Assert-Equal "Plainclothes" $sundance[0].title "keeps Sundance title"
Assert-Equal "Carmen Emmi" $sundance[0].director "extracts Sundance director"

$sundanceFilteredHtml = @"
<html>
<body>
<h2>U.S. DOCUMENTARY COMPETITION</h2>
<p>Doc Sample / U.S.A. (Director: Doc Maker, Producers: Producer) - A story.</p>
<h2>NEXT</h2>
<p>Next Sample / U.S.A. (Director: Next Maker, Producers: Producer) - A story.</p>
</body>
</html>
"@
$sundanceFiltered = @(ConvertFrom-LineupHtml -Html $sundanceFilteredHtml -Festival "Sundance" -Region "United States" -SourceUrl "https://example.test/sundance" -Parser "sundance_article" -Year 2026)
Assert-Equal 1 $sundanceFiltered.Count "filters Sundance to selected fiction/NEXT sections"
Assert-Equal "Next Sample" $sundanceFiltered[0].title "keeps Sundance NEXT title"

$veniceTextHtml = @"
<html>
<body>
<p>Read more Le mage du Kremlin (The Wizard of the Kremlin) Director Olivier Assayas Main Cast Paul Dano / France / 2025 / 156'</p>
<p>Read more Jay Kelly Director Noah Baumbach Main Cast George Clooney / USA / 132'</p>
</body>
</html>
"@
$venice = @(ConvertFrom-LineupHtml -Html $veniceTextHtml -Festival "Venice" -Region "Italy" -SourceUrl "https://www.labiennale.org/en/cinema/2025/venezia-82-competition" -Parser "venice_selection" -Year 2025)
Assert-Equal 2 $venice.Count "parses Venice feature lineup records"
Assert-Equal "Le mage du Kremlin (The Wizard of the Kremlin)" $venice[0].title "keeps Venice title"
Assert-Equal "Olivier Assayas" $venice[0].director "extracts Venice director"

$veniceOrizzontiHtml = @"
<html>
<body>
<p>Orizzonti Competition Read more Feature Sample Director Feature Maker Main Cast Cast / Italy / 2025 / 90'</p>
<p>Orizzonti Short Films Competition Read more Short Sample Director Short Maker Main Cast Cast / Italy / 2025 / 12'</p>
</body>
</html>
"@
$veniceOrizzonti = @(ConvertFrom-LineupHtml -Html $veniceOrizzontiHtml -Festival "Venice" -Region "Italy" -SourceUrl "https://www.labiennale.org/en/cinema/2025/orizzonti" -Parser "venice_selection" -Year 2025)
Assert-Equal 1 $veniceOrizzonti.Count "filters Venice Orizzonti short films"
Assert-Equal "Feature Sample" $veniceOrizzonti[0].title "keeps Venice Orizzonti feature"

$oscarsHtml = @"
<html>
<body>
<h2>Actor in a Leading Role</h2>
<p>Winner</p>
<p>Michael B. Jordan</p>
<p>Sinners</p>
<p>Nominees</p>
<p>Timothée Chalamet</p>
<p>Marty Supreme</p>
<h2>Animated Feature Film</h2>
<p>Nominees</p>
<p>Animated Sample</p>
<h2>International Feature Film</h2>
<p>Nominees</p>
<p>International Sample</p>
<h2>Documentary Feature Film</h2>
<p>Nominees</p>
<p>Documentary Sample</p>
<h2>Best Picture</h2>
<p>Winner</p>
<p>One Battle after Another</p>
<p>Adam Somner, Sara Murphy and Paul Thomas Anderson, Producers</p>
<p>Nominees</p>
<p>Sinners</p>
<p>Zinzi Coogler, Sev Ohanian and Ryan Coogler, Producers</p>
<h2>Music (Original Song)</h2>
<p>Nominees</p>
<p>I Lied To You</p>
<p>from Sinners; Music and Lyric by Raphael Saadiq and Ludwig Goransson</p>
</body>
</html>
"@
$oscars = @(ConvertFrom-LineupHtml -Html $oscarsHtml -Festival "Academy Awards" -Region "United States" -SourceUrl "https://example.test/oscars" -Parser "oscars_ceremony" -Year 2025)
Assert-Equal 4 $oscars.Count "filters Oscars to selected feature categories"
Assert-True (@($oscars | Where-Object { $_.title -eq "Sinners" }).Count -eq 1) "keeps repeated Oscar film once from Best Picture"
Assert-True (@($oscars | Where-Object { $_.title -eq "Marty Supreme" }).Count -eq 0) "excludes acting-only Oscar titles"
Assert-True (@($oscars | Where-Object { $_.title -eq "Documentary Sample" }).Count -eq 0) "excludes Oscar documentary feature by default"
Assert-True (@($oscars | Where-Object { $_.title -eq "One Battle after Another" }).Count -eq 1) "extracts best picture title"
Assert-True (@($oscars | Where-Object { $_.title -eq "Animated Sample" }).Count -eq 1) "keeps animated feature title"
Assert-True (@($oscars | Where-Object { $_.title -eq "International Sample" }).Count -eq 1) "keeps international feature title"

$sectionScopedHtml = @"
<html>
<body>
<h2>Competition</h2>
<p>Competition Sample by Competition Director</p>
<h2>Panorama</h2>
<p>Panorama Sample by Panorama Director</p>
<h2>Encounters</h2>
<p>Encounters Sample by Encounters Director</p>
</body>
</html>
"@
$sectionScoped = @(ConvertFrom-LineupHtml -Html $sectionScopedHtml -Festival "Berlinale" -Region "Germany" -SourceUrl "https://example.test/berlinale" -Parser "generic_title_by_director" -Year 2026 -SectionScope @("Competition", "Encounters"))
Assert-Equal 2 $sectionScoped.Count "filters generic parser to configured section scope"
Assert-True (@($sectionScoped | Where-Object { $_.title -eq "Panorama Sample" }).Count -eq 0) "excludes sections outside configured scope"

$goldenHorseHtml = @"
<html>
<body>
<h2>Best Narrative Feature</h2>
<p>A Foggy Tale</p>
<p>Taiwan Creative Content Agency, MandarinVision Co., Ltd.</p>
<p>Left-Handed Girl</p>
<p>Left-Handed Girl Film Production Co., Ltd.</p>
<h2>Best Documentary Feature</h2>
<p>Documentary Sample</p>
<p>Documentary Director</p>
</body>
</html>
"@
$goldenHorse = @(ConvertFrom-LineupHtml -Html $goldenHorseHtml -Festival "Taipei Golden Horse Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/goldenhorse" -Parser "golden_horse_awards" -Year 2025)
Assert-Equal 2 $goldenHorse.Count "parses Golden Horse best narrative feature nominees"
Assert-True (@($goldenHorse | Where-Object { $_.title -eq "Documentary Sample" }).Count -eq 0) "excludes Golden Horse documentary nominees"

$nyffHtml = @"
<html>
<body>
<h2>Main Slate</h2>
<p>The Secret Agent</p>
<p>Kleber Mendonca Filho, 2025, Brazil, 160m</p>
<p>The Secret Agent. Courtesy of Neon.</p>
<p>What Does That Nature Say to You / geu jayeoni nege mworago hani</p>
<p>Hong Sangsoo, 2025, South Korea, 108m</p>
<p>Secure your tickets with Festival Passes</p>
</body>
</html>
"@
$nyff = @(ConvertFrom-LineupHtml -Html $nyffHtml -Festival "NYFF" -Region "United States" -SourceUrl "https://example.test/nyff" -Parser "nyff_main_slate" -Year 2025)
Assert-Equal 2 $nyff.Count "parses NYFF main slate title and director pairs"
Assert-Equal "Main Slate" $nyff[0].section "sets NYFF Main Slate section"

$tidfHtml = @"
<html>
<body>
<h3 class="views-field views-field-title entity-title"><a href="/en/films/157519">Air Base</a></h3>
<div class="views-field views-field-field-year-start entity-start-date">2025</div>
<h3 class="views-field views-field-title entity-title"><a href="/en/films/157520">Cherry Ferry</a></h3>
<div class="views-field views-field-field-year-start entity-start-date">2024</div>
</body>
</html>
"@
$tidf = @(ConvertFrom-LineupHtml -Html $tidfHtml -Festival "Taiwan International Documentary Festival" -Region "Taiwan" -SourceUrl "https://www.tidf.org.tw/en/category/shows2026/6055" -Parser "tidf_category" -Year 2026)
Assert-Equal 2 $tidf.Count "parses TIDF category film cards"
Assert-Equal "Air Base" $tidf[0].title "keeps TIDF title"
Assert-Equal "Asian Vision Competition" $tidf[0].section "maps TIDF source URL to section"
Assert-Equal 2025 $tidf[0].year "keeps TIDF film year"

$kviffHtml = @"
<html>
<body>
<div class="col first">
  <a href="/en/programme/film/75/47178-better-go-mad-in-the-wild" class="film-name">Better Go Mad in the Wild</a><br />
  (Radeji zesilet v divocine)
</div>
<div class="col second">
  Directed by: Miro Remo / Czech Republic, Slovak Republic, 2025, 84&nbsp;min<br />
</div>
</body>
</html>
"@
$kviff = @(ConvertFrom-LineupHtml -Html $kviffHtml -Festival "Karlovy Vary" -Region "Czech Republic" -SourceUrl "https://www.kviff.com/en/programme/archive-of-films/2025/section/948-crystal-globe-competition" -Parser "kviff_archive_section" -Year 2025)
Assert-Equal 1 $kviff.Count "parses KVIFF archive film cards"
Assert-Equal "Better Go Mad in the Wild" $kviff[0].title "keeps KVIFF title"
Assert-Equal "Miro Remo" $kviff[0].director "extracts KVIFF director"
Assert-Equal "Crystal Globe Competition" $kviff[0].section "maps KVIFF source URL to section"

$taipeiAwardsData = [pscustomobject]@{
    awardAry = @(
        [pscustomobject]@{
            title = "Sample Feature"
            awards_with_winners = @(
                [pscustomobject]@{ award_name = "Best Feature"; winner = "Producer" },
                [pscustomobject]@{ award_name = "Best Director"; winner = "Sample Director" }
            )
        },
        [pscustomobject]@{
            title = "Sample Short"
            awards_with_winners = @(
                [pscustomobject]@{ award_name = "Best Short"; winner = "Short Producer" }
            )
        }
    )
}
$taipeiAwards = @(ConvertFrom-TaipeiFilmAwardsData -Data $taipeiAwardsData -Festival "Taipei Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/tfa" -Year 2026 -AllowedAwardPatterns @("Best Feature", "Grand Prize", "\u5287\u60c5\u9577\u7247", "\u6700\u4f73\u5287\u60c5\u9577\u7247", "\u9577\u7247"))
Assert-Equal 1 $taipeiAwards.Count "filters Taipei Film Awards to feature-related awards"
Assert-Equal "Sample Feature" $taipeiAwards[0].title "keeps Taipei Film Awards title"

$taipeiNewTalentData = [pscustomobject]@{
    awardAry = @(
        [pscustomobject]@{ col_1 = "Sample New Talent"; col_2 = "Sample Director | Taiwan" }
    )
}
$taipeiNewTalent = @(ConvertFrom-TaipeiNewTalentData -Data $taipeiNewTalentData -Festival "Taipei Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/intc" -Year 2026)
Assert-Equal 1 $taipeiNewTalent.Count "converts Taipei New Talent API data"
Assert-Equal "Sample Director" $taipeiNewTalent[0].director "extracts Taipei New Talent director"

$providerResult = [pscustomobject]@{
    results = [pscustomobject]@{
        US = [pscustomobject]@{
            link = "https://tmdb.test/movie"
            flatrate = @([pscustomobject]@{ provider_name = "Criterion Channel" })
            rent = @([pscustomobject]@{ provider_name = "Apple TV" })
            buy = @([pscustomobject]@{ provider_name = "Amazon Video" })
        }
        GB = [pscustomobject]@{
            link = "https://tmdb.test/movie-gb"
            free = @([pscustomobject]@{ provider_name = "BBC iPlayer" })
        }
    }
}
$offers = @(ConvertFrom-TmdbProviderResult -ProviderResult $providerResult)
Assert-Equal 4 $offers.Count "maps TMDb watch provider offers"
Assert-True (@($offers | Where-Object { $_.type -eq "streaming_subscription" -and $_.provider -eq "Criterion Channel" }).Count -eq 1) "maps flatrate to subscription"
Assert-True (@($offers | Where-Object { $_.type -eq "streaming_free" -and $_.provider -eq "BBC iPlayer" }).Count -eq 1) "maps free to streaming_free"
Assert-True (@($offers | Where-Object { $_.type -eq "digital_rent" -and $_.provider -eq "Apple TV" }).Count -eq 1) "maps rent to digital_rent"
Assert-True (@($offers | Where-Object { $_.type -eq "digital_buy" -and $_.provider -eq "Amazon Video" }).Count -eq 1) "maps buy to digital_buy"

$film = New-FilmRecord -Title "Test Film" -Director "Test Director" -Festival "Test Festival" -Region "Test Region" -SourceUrl "https://example.test" -Year 2025
$event = New-FirstAvailabilityEvent -Film $film -Offers @([pscustomobject]@{
    type = "authorized_download"
    provider = "Official Site"
    country = ""
    source_url = "https://example.test/download"
    source_class = "official_or_whitelist"
    raw_category = "download"
})
Assert-True ($null -ne $event) "creates first availability event"
Assert-Equal $film.id $event.film_id "links event to film id"
Assert-Equal "authorized_download" $event.availability_types[0] "records event availability type"
Set-RecordProperty -Record $event -Name "film_notion_page_id" -Value "00000000-0000-0000-0000-000000000001"
$eventProperties = ConvertTo-NotionEventProperties -Event $event
Assert-Equal "00000000-0000-0000-0000-000000000001" $eventProperties["Film"].relation[0].id "adds Notion film relation to event properties"

$duplicateA = New-FilmRecord -Title "Duplicate Film" -Director "A Director" -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Year 2025
$duplicateA.tmdb_id = 12345
$duplicateB = New-FilmRecord -Title "Duplicate Film" -Director "" -Festival "Academy Awards" -Region "United States" -SourceUrl "https://example.test/oscars" -Year 2025
$duplicateB.tmdb_id = 12345
$firstEvent = New-FirstAvailabilityEvent -Film $duplicateA -Offers @([pscustomobject]@{
    type = "streaming_subscription"
    provider = "Test Streamer"
    country = "US"
    source_url = "https://example.test/watch"
    source_class = "tmdb"
    raw_category = "flatrate"
})
Assert-Equal (Get-FilmCanonicalKey -Film $duplicateA) (Get-FilmCanonicalKey -Film $duplicateB) "uses shared canonical key across sources"
Assert-Equal $firstEvent.id (New-StableId "first-availability|$(Get-FilmCanonicalKey -Film $duplicateB)") "uses canonical key for event id"

$authorizedConfig = [pscustomobject]@{
    allowedDomains = @("archive.org", "example.org")
    allowedLicenseFragments = @("creativecommons.org", "publicdomain")
    downloadExtensions = @(".mp4")
    torrentExtensions = @(".torrent")
}
Assert-True (Test-AllowedAuthorizedUrl -Url "https://archive.org/details/public-domain-film" -AuthorizedConfig $authorizedConfig) "allows configured authorized domain"
Assert-True (-not (Test-AllowedAuthorizedUrl -Url "https://pirate.example/details/movie" -AuthorizedConfig $authorizedConfig)) "rejects non-whitelisted domain"

if ($Script:Failures -gt 0) {
    throw "$Script:Failures test(s) failed."
}

Write-Host "All tests passed." -ForegroundColor Green
