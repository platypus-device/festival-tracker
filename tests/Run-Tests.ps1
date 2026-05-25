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

$sameNotionPage = [pscustomobject]@{
    properties = [pscustomobject]@{
        "Film Title" = [pscustomobject]@{ type = "title"; title = @([pscustomobject]@{ plain_text = "Sample Film" }) }
        "Director" = [pscustomobject]@{ type = "rich_text"; rich_text = @([pscustomobject]@{ plain_text = "Sample Director" }) }
        "Poster URL" = [pscustomobject]@{ type = "url"; url = "https://example.test/poster.jpg" }
        "TMDb Rating" = [pscustomobject]@{ type = "number"; number = 7.8 }
        "Needs Review" = [pscustomobject]@{ type = "checkbox"; checkbox = $false }
    }
}
$sameProperties = @{
    "Film Title" = New-TitleProperty "Sample Film"
    "Director" = New-RichTextProperty "Sample Director"
    "Poster URL" = New-UrlProperty "https://example.test/poster.jpg"
    "TMDb Rating" = @{ number = 7.8 }
    "Needs Review" = @{ checkbox = $false }
}
$samePatch = Get-NotionChangedProperties -DesiredProperties $sameProperties -Page $sameNotionPage
Assert-Equal 0 $samePatch.Count "does not patch unchanged Notion properties"

$emptyIncomingProperties = @{
    "Director" = New-RichTextProperty ""
    "Poster URL" = New-UrlProperty ""
}
$emptyPatch = Get-NotionChangedProperties -DesiredProperties $emptyIncomingProperties -Page $sameNotionPage
Assert-Equal 0 $emptyPatch.Count "does not clear existing Notion values with empty incoming values"

$changedPatch = Get-NotionChangedProperties -DesiredProperties @{ "TMDb Rating" = @{ number = 8.1 } } -Page $sameNotionPage
Assert-Equal 1 $changedPatch.Count "patches changed Notion property only"
Assert-True $changedPatch.ContainsKey("TMDb Rating") "includes changed rating property"

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

$cannesScopedHtml = @"
<html>
<body>
<h2>In Competition</h2>
<p>Feature films</p>
<p>COMPETITION SAMPLE by Competition DIRECTOR</p>
<h2>Un Certain Regard</h2>
<p>UCR SAMPLE by UCR DIRECTOR</p>
<h2>Directors' Fortnight</h2>
<p>FORTNIGHT SAMPLE by Fortnight DIRECTOR</p>
</body>
</html>
"@
$cannesScoped = @(ConvertFrom-LineupHtml -Html $cannesScopedHtml -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Parser "cannes_selection" -Year 2026)
Assert-Equal 2 $cannesScoped.Count "keeps Cannes core sections only"
Assert-True (@($cannesScoped | Where-Object { $_.title -eq "FORTNIGHT SAMPLE" }).Count -eq 0) "excludes Cannes non-core sections after UCR"

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
<p>Timoth茅e Chalamet</p>
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

$wikipediaOscarsHtml = @"
<html>
<body>
<h3><span class="mw-headline" id="Best_Picture">Best Picture</span></h3>
<table class="wikitable">
<tr><th>Film</th><th>Producers</th></tr>
<tr><td><i><a href="/wiki/Bugonia">Bugonia</a></i></td><td>Producer One</td></tr>
<tr><td><b><i>Sentimental Value</i></b></td><td>Producer Two</td></tr>
</table>
<h3><span class="mw-headline" id="Best_Documentary_Feature_Film">Best Documentary Feature Film</span></h3>
<table class="wikitable">
<tr><td><i>Documentary Sample</i></td></tr>
</table>
<h3><span class="mw-headline" id="Best_International_Feature_Film">Best International Feature Film</span></h3>
<table class="wikitable">
<tr><td>Norway</td><td><i>Sentimental Value</i></td><td>Director</td></tr>
<tr><td>Brazil</td><td><i>The Secret Agent</i></td><td>Director</td></tr>
</table>
<h3><span class="mw-headline" id="Best_Animated_Feature_Film">Best Animated Feature Film</span></h3>
<table class="wikitable">
<tr><td><i>Animated Sample</i></td></tr>
</table>
<h3><span class="mw-headline" id="Best_Actor">Best Actor</span></h3>
<table class="wikitable">
<tr><td>Actor Name</td><td><i>Acting Only Sample</i></td></tr>
</table>
</body>
</html>
"@
$wikipediaOscars = @(ConvertFrom-LineupHtml -Html $wikipediaOscarsHtml -Festival "Academy Awards" -Region "United States" -SourceUrl "https://example.test/wiki-oscars" -Parser "wikipedia_oscars_awards" -Year 2026)
Assert-Equal 4 $wikipediaOscars.Count "parses Wikipedia Oscars target categories"
Assert-True (@($wikipediaOscars | Where-Object { $_.title -eq "Documentary Sample" }).Count -eq 0) "excludes Wikipedia Oscar documentary category"
Assert-True (@($wikipediaOscars | Where-Object { $_.title -eq "Acting Only Sample" }).Count -eq 0) "excludes Wikipedia Oscar acting category"
$sentimentalValue = @($wikipediaOscars | Where-Object { $_.title -eq "Sentimental Value" })
Assert-Equal 1 $sentimentalValue.Count "deduplicates Wikipedia Oscar cross-category films"
Assert-Equal "Best Picture; International Feature Film" $sentimentalValue[0].section "merges Wikipedia Oscar sections for cross-category films"
Assert-Equal 2025 $sentimentalValue[0].film_year "sets Oscar film year from previous eligibility year"

$wikipediaOscarsCombinedTableHtml = @"
<html>
<body>
<table class="wikitable">
<tr>
<td><div><b><a href="/wiki/Academy_Award_for_Best_Picture">Best Picture</a></b></div>
<ul><li><b><i>One Battle After Another</i></b><ul><li><i>Bugonia</i></li></ul></li></ul></td>
<td><div><b><a href="/wiki/Academy_Award_for_Best_Director">Best Directing</a></b></div>
<ul><li><b>Director - <i>Director Only Sample</i></b></li></ul></td>
</tr>
<tr>
<td><div><b><a href="/wiki/Academy_Award_for_Best_Animated_Feature">Best Animated Feature Film</a></b></div>
<ul><li><b><i>Animated Combined Sample</i></b></li></ul></td>
<td><div><b><a href="/wiki/Academy_Award_for_Best_International_Feature_Film">Best International Feature Film</a></b></div>
<ul><li><b><i>Bugonia</i></b></li><li><i>International Combined Sample</i></li></ul></td>
</tr>
</table>
</body>
</html>
"@
$wikipediaOscarsCombined = @(ConvertFrom-LineupHtml -Html $wikipediaOscarsCombinedTableHtml -Festival "Academy Awards" -Region "United States" -SourceUrl "https://example.test/wiki-oscars-combined" -Parser "wikipedia_oscars_awards" -Year 2026)
Assert-Equal 4 $wikipediaOscarsCombined.Count "parses Wikipedia Oscars combined awards table"
Assert-True (@($wikipediaOscarsCombined | Where-Object { $_.title -eq "Director Only Sample" }).Count -eq 0) "excludes non-target cells in combined Oscars table"
$bugoniaCombined = @($wikipediaOscarsCombined | Where-Object { $_.title -eq "Bugonia" })
Assert-Equal 1 $bugoniaCombined.Count "deduplicates combined table cross-category films"
Assert-Equal "Best Picture; International Feature Film" $bugoniaCombined[0].section "merges combined table Oscar sections"
Assert-Equal 2025 $bugoniaCombined[0].film_year "sets combined table Oscar film year"

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
Assert-Equal 2026 $tidf[0].year "keeps TIDF festival year"
Assert-Equal 2025 $tidf[0].film_year "keeps TIDF film year separately"

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

$taipeiBestNarrativeFeature = New-StringFromCodePoints @(0x6700, 0x4f73, 0x5287, 0x60c5, 0x9577, 0x7247)
$taipeiBestDocumentary = New-StringFromCodePoints @(0x6700, 0x4f73, 0x7d00, 0x9304, 0x7247)
$taipeiBestAnimation = New-StringFromCodePoints @(0x6700, 0x4f73, 0x52d5, 0x756b, 0x7247)
$taipeiAwardsData = [pscustomobject]@{
    awardAry = @(
        [pscustomobject]@{
            title = "Sample Narrative Feature"
            filename = [pscustomobject]@{ url = "https://www.taipeiff.taipei/files/sample-narrative.jpg" }
            awards_with_winners = @(
                [pscustomobject]@{ award_name = $taipeiBestNarrativeFeature; winner = "Producer" },
                [pscustomobject]@{ award_name = "Best Director"; winner = "Sample Director" }
            )
        },
        [pscustomobject]@{
            title = "Sample Documentary Feature"
            awards_with_winners = @(
                [pscustomobject]@{ award_name = $taipeiBestDocumentary; winner = "Doc Producer" }
            )
        },
        [pscustomobject]@{
            title = "Sample Animated Feature"
            awards_with_winners = @(
                [pscustomobject]@{ award_name = $taipeiBestAnimation; winner = "Animation Producer" }
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
$taipeiAwards = @(ConvertFrom-TaipeiFilmAwardsData -Data $taipeiAwardsData -Festival "Taipei Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/tfa" -Year 2026 -AllowedAwardPatterns @("^Best Narrative Feature$", "^\u6700\u4f73\u5287\u60c5\u9577\u7247$"))
Assert-Equal 1 $taipeiAwards.Count "filters Taipei Film Awards to narrative feature only"
Assert-Equal "Sample Narrative Feature" $taipeiAwards[0].title "keeps Taipei narrative feature title"
Assert-Equal "https://www.taipeiff.taipei/files/sample-narrative.jpg" $taipeiAwards[0].poster_url "keeps Taipei official poster fallback"
Assert-Equal "official:taipeiff" $taipeiAwards[0].metadata_source "marks Taipei official metadata source"

$taipeiNewTalentData = [pscustomobject]@{
    awardAry = @(
        [pscustomobject]@{
            col_1 = "Sample New Talent"
            col_2 = "Sample Director | Taiwan"
            filename = [pscustomobject]@{ url = "https://www.taipeiff.taipei/files/sample-new-talent.jpg" }
        }
    )
}
$taipeiNewTalent = @(ConvertFrom-TaipeiNewTalentData -Data $taipeiNewTalentData -Festival "Taipei Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/intc" -Year 2026)
Assert-Equal 1 $taipeiNewTalent.Count "converts Taipei New Talent API data"
Assert-Equal "Sample Director" $taipeiNewTalent[0].director "extracts Taipei New Talent director"
Assert-Equal "https://www.taipeiff.taipei/files/sample-new-talent.jpg" $taipeiNewTalent[0].poster_url "keeps Taipei New Talent official poster fallback"

Assert-Equal "2025/api/articles/tfa/nominees" (Get-TaipeiFilmFestivalApiEndpoint -Endpoint "api/articles/tfa/nominees" -SourceUrl "https://www.taipeiff.taipei/2025/tw/tfa?tab=shortlist") "uses Taipei archive year in API endpoint"
Assert-Equal "api/articles/tfa/nominees" (Get-TaipeiFilmFestivalApiEndpoint -Endpoint "api/articles/tfa/nominees" -SourceUrl "https://www.taipeiff.taipei/tw/tfa?tab=shortlist") "keeps active Taipei API endpoint"

$sampleWebFilms = @(
    [pscustomobject]@{ year = 2025 },
    [pscustomobject]@{ year = 2026 },
    [pscustomobject]@{ year = 2025 },
    [pscustomobject]@{ year = 2024 },
    [pscustomobject]@{ year = $null }
)
$sampleYears = @(
    $sampleWebFilms |
        ForEach-Object { ConvertTo-OptionalInt $_.year } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending -Unique
)
Assert-Equal "2026,2025,2024" ($sampleYears -join ",") "exports web years descending and unique"

$exportStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("festival-export-test-" + [guid]::NewGuid().ToString("N"))
$exportOutput = Join-Path $exportStateDir "tracker-data.json"
New-Item -ItemType Directory -Path $exportStateDir | Out-Null
$duplicateFestivalFilms = @(
    [pscustomobject]@{
        id = "selection-cannes"
        title = "Duplicate Export"
        original_title = "Duplicate Export"
        director = "Sample Director"
        year = 2025
        festival_year = 2025
        film_year = 2024
        festival = "Cannes"
        region = "France"
        section = "Un Certain Regard"
        source_url = "https://example.test/cannes"
        tmdb_id = 1001
        imdb_id = "tt1001"
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 7.2
        imdb_rating = 7.8
        imdb_votes = 12345
        imdb_rating_checked_at = "2026-05-20"
        rating_source = "IMDb"
        tracking_status = "available_found"
        first_available_date = "2026-05-19"
        last_checked = "2026-05-19"
        needs_review = $true
        authorized_source_urls = @()
    },
    [pscustomobject]@{
        id = "selection-nyff"
        title = "Duplicate Export"
        original_title = "Duplicate Export"
        director = "Sample Director"
        year = 2025
        festival_year = 2025
        film_year = 2024
        festival = "NYFF"
        region = "United States"
        section = "Main Slate"
        source_url = "https://example.test/nyff"
        tmdb_id = 1001
        imdb_id = "tt1001"
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 7.2
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    }
)
$duplicateEvents = @(
    [pscustomobject]@{
        id = "event-cannes"
        film_id = "selection-cannes"
        film_title = "Duplicate Export"
        director = "Sample Director"
        festival = "Cannes"
        event_date = "2026-05-19"
        availability_types = @("streaming_subscription")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/watch")
        needs_review = $false
    }
)
ConvertTo-Json -InputObject $duplicateFestivalFilms -Depth 10 | Set-Content -Path (Join-Path $exportStateDir "films.json") -Encoding UTF8
ConvertTo-Json -InputObject $duplicateEvents -Depth 10 | Set-Content -Path (Join-Path $exportStateDir "events.json") -Encoding UTF8
& (Join-Path $PSScriptRoot "..\scripts\Export-TrackerData.ps1") -OutputPath $exportOutput -StateDir $exportStateDir | Out-Null
$exportedWebData = Get-Content $exportOutput -Raw | ConvertFrom-Json
$exportedSelectionCount = @($exportedWebData.films | ForEach-Object { @($_.selections) }).Count
Assert-Equal 1 $exportedWebData.totals.films "exports one web card for duplicate TMDb selections"
Assert-Equal 2 $exportedWebData.totals.selections "keeps both festival selections in export totals"
Assert-Equal $exportedSelectionCount $exportedWebData.totals.selections "keeps totals selections aligned with exported selection records"
Assert-Equal $exportedSelectionCount $exportedWebData.selectionCount "keeps legacy selectionCount aligned with exported selection records"
Assert-True ($null -eq $exportedWebData.totals.needsReview) "does not expose legacy review count in main totals"
Assert-Equal 1 $exportedWebData.diagnostics.lowConfidence "exports low confidence as diagnostics"
Assert-Equal 2 $exportedWebData.films[0].selections.Count "keeps duplicate selections on merged web card"
Assert-Equal 2024 $exportedWebData.films[0].filmYear "keeps film year separate from festival year"
Assert-Equal 7.8 $exportedWebData.films[0].imdbRating "exports IMDb rating"
Assert-Equal 12345 $exportedWebData.films[0].imdbVotes "exports IMDb vote count"
Assert-Equal 0 $exportedWebData.diagnostics.duplicateCanonical "exports duplicate canonical diagnostics"
Assert-Equal 1 $exportedWebData.diagnostics.missingPoster "exports missing poster diagnostics after merge"
Assert-Equal 0 $exportedWebData.diagnostics.missingTmdb "exports missing TMDb diagnostics"
Assert-Equal 0 $exportedWebData.diagnostics.missingDirector "exports missing director diagnostics"
Assert-Equal 1 $exportedWebData.diagnostics.missingPosterFilms.Count "exports missing poster film list"
Assert-Equal "Duplicate Export" $exportedWebData.diagnostics.missingPosterFilms[0].title "exports diagnostic film title"
Assert-Equal "Duplicate Export" $exportedWebData.diagnostics.lowConfidenceFilms[0].title "exports low confidence film list"
Assert-Equal "2025" (($exportedWebData.festivalYears | ForEach-Object { [string]$_ }) -join ",") "exports festival years from selections"
Assert-Equal "Cannes,NYFF" (($exportedWebData.festivals | ForEach-Object { [string]$_ }) -join ",") "exports festival filter options from individual selections"
Remove-Item -LiteralPath $exportStateDir -Recurse -Force

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
Assert-Equal "https://example.test/download" $eventProperties["Primary Source URL"].url "stores primary source URL on event"
Assert-Equal 1 $eventProperties["Source URL Count"].number "stores source URL count on event"
Assert-Equal 1 $eventProperties["Provider Count"].number "stores provider count on event"
Assert-Equal 0 $eventProperties["Country Count"].number "stores country count on event"
Assert-True (-not $eventProperties.ContainsKey("Source URLs")) "does not write legacy event source URL text field"

$film.authorized_source_urls = @("https://example.org/download.mp4")
$canonicalFilmProperties = ConvertTo-NotionCanonicalFilmProperties -Film $film
Assert-Equal "https://example.org/download.mp4" $canonicalFilmProperties["Authorized Source URLs"].rich_text[0].text.content "stores authorized URLs on canonical film"

$selectionProperties = ConvertTo-NotionSelectionProperties -Film $film
Assert-True (-not $selectionProperties.ContainsKey("TMDb ID")) "selection properties omit canonical metadata"
Assert-True (-not $selectionProperties.ContainsKey("Authorized Source URLs")) "selection properties omit authorized source URLs"

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

$checkedTodayFilm = New-FilmRecord -Title "Checked Today" -Director "Daily Director" -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Year 2026
$checkedTodayFilm.last_checked = (Get-Date).ToString("yyyy-MM-dd")
$checkedTodayFilm.authorized_source_urls = @("https://example.org/download.mp4")
$sameDayAvailability = Add-FirstAvailabilityEvents -Films @($checkedTodayFilm) -ExistingEvents @() -AuthorizedConfig $authorizedConfig
Assert-Equal 0 @($sameDayAvailability.new_events).Count "skips same-day pending availability checks"
Assert-Equal "pending" $sameDayAvailability.films[0].tracking_status "keeps same-day skipped film pending"

$completeMetadataFilm = New-FilmRecord -Title "Complete Metadata" -Director "Metadata Director" -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Year 2026
$completeMetadataFilm.imdb_id = "tt1234567"
$completeMetadataFilm.poster_url = "https://image.tmdb.org/t/p/w500/poster.jpg"
$completeMetadataFilm.overview = "Overview"
$completeMetadataFilm.film_year = 2026
$completeMetadataFilm.tmdb_rating = 7.1
Assert-True (-not (Test-FilmNeedsTmdbMetadataRefresh -Film $completeMetadataFilm)) "skips TMDb metadata refresh when tracked fields are complete"
$completeMetadataFilm.poster_url = ""
Assert-True (Test-FilmNeedsTmdbMetadataRefresh -Film $completeMetadataFilm) "refreshes TMDb metadata when tracked fields are missing"

$imdbStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("festival-imdb-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $imdbStateDir "imdb") | Out-Null
$imdbDatasetPath = Join-Path $imdbStateDir "imdb\title.ratings.tsv.gz"
$imdbDatasetText = "tconst`taverageRating`numVotes`n" +
    "tt7654321`t7.2`t1000`n" +
    "tt7654322`t8.1`t2000`n"
$fileStream = [System.IO.File]::Create($imdbDatasetPath)
try {
    $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Compress)
    try {
        $writer = [System.IO.StreamWriter]::new($gzipStream)
        try {
            $writer.Write($imdbDatasetText)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $gzipStream.Dispose()
    }
}
finally {
    $fileStream.Dispose()
}
(Get-Item $imdbDatasetPath).LastWriteTime = Get-Date

$unchangedRatingFilm = New-FilmRecord -Title "Unchanged Rating" -Director "Rating Director" -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Year 2026
$unchangedRatingFilm.imdb_id = "tt7654321"
$unchangedRatingFilm.imdb_rating = 7.2
$unchangedRatingFilm.imdb_votes = 1000
$unchangedRatingFilm.rating_source = "IMDb Dataset"
$unchangedRatingFilm.imdb_rating_checked_at = "2026-01-01"
$changedRatingFilm = New-FilmRecord -Title "Changed Rating" -Director "Rating Director" -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Year 2026
$changedRatingFilm.imdb_id = "tt7654322"
$changedRatingFilm.imdb_rating = 8.0
$changedRatingFilm.imdb_votes = 1999
$changedRatingFilm.rating_source = "IMDb Dataset"
$changedRatingFilm.imdb_rating_checked_at = "2026-01-01"
$ratedFilms = @(Update-FilmImdbDatasetRatings -Films @($unchangedRatingFilm, $changedRatingFilm) -StateDir $imdbStateDir)
Assert-Equal "2026-01-01" $ratedFilms[0].imdb_rating_checked_at "keeps IMDb checked date when dataset values are unchanged"
Assert-Equal 8.1 $ratedFilms[1].imdb_rating "updates changed IMDb dataset rating"
Assert-Equal 2000 $ratedFilms[1].imdb_votes "updates changed IMDb dataset votes"
Assert-Equal (Get-Date).ToString("yyyy-MM-dd") $ratedFilms[1].imdb_rating_checked_at "updates IMDb checked date when dataset values change"
Remove-Item -LiteralPath $imdbStateDir -Recurse -Force

if ($Script:Failures -gt 0) {
    throw "$Script:Failures test(s) failed."
}

Write-Host "All tests passed." -ForegroundColor Green
