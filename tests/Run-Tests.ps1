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

$desiredSchemaProperties = @{
    "Year Source" = @{ rich_text = @{} }
    "Premiere Year" = @{ number = @{ format = "number" } }
}
$existingSchemaProperties = [pscustomobject]@{
    "Year Source" = [pscustomobject]@{
        type = "rich_text"
        rich_text = [pscustomobject]@{}
    }
}
$missingSchemaProperties = Get-NotionMissingSchemaProperties -ExistingProperties $existingSchemaProperties -DesiredProperties $desiredSchemaProperties
Assert-Equal 1 $missingSchemaProperties.Count "schema diff includes missing properties only"
Assert-True $missingSchemaProperties.Contains("Premiere Year") "schema diff includes missing premiere year"
Assert-True (-not $missingSchemaProperties.Contains("Year Source")) "schema diff skips existing compatible properties"

$incompatibleSchemaProperties = [pscustomobject]@{
    "Year Source" = [pscustomobject]@{
        type = "number"
        number = [pscustomobject]@{ format = "number" }
    }
}
$incompatibleSchemaError = ""
try {
    Get-NotionMissingSchemaProperties -ExistingProperties $incompatibleSchemaProperties -DesiredProperties $desiredSchemaProperties | Out-Null
}
catch {
    $incompatibleSchemaError = $_.Exception.Message
}
Assert-True $incompatibleSchemaError.Contains("Year Source exists but is not rich_text") "schema diff fails incompatible property types"

$desiredRelationProperties = @{
    "Film" = @{
        relation = @{
            database_id = "11111111-1111-1111-1111-111111111111"
            type = "single_property"
            single_property = @{}
        }
    }
}
$missingRelationProperties = Get-NotionMissingSchemaProperties -ExistingProperties ([pscustomobject]@{}) -DesiredProperties $desiredRelationProperties
Assert-Equal 1 $missingRelationProperties.Count "schema diff creates missing relation properties"
$existingRelationProperties = [pscustomobject]@{
    "Film" = [pscustomobject]@{
        type = "relation"
        relation = [pscustomobject]@{
            database_id = "11111111111111111111111111111111"
            type = "single_property"
            single_property = [pscustomobject]@{}
        }
    }
}
$unchangedRelationProperties = Get-NotionMissingSchemaProperties -ExistingProperties $existingRelationProperties -DesiredProperties $desiredRelationProperties
Assert-Equal 0 $unchangedRelationProperties.Count "schema diff skips existing compatible relation properties"

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

$cannesNoFeatureSubheadingHtml = @"
<html>
<body>
<h2>In Competition</h2>
<p>Opening Film</p>
<p>PARTIR UN JOUR by Amelie BONNIN | 1st film - Out of Competition</p>
<p>THE PHOENICIAN SCHEME by Wes ANDERSON</p>
<p>EDDINGTON by Ari ASTER</p>
<h2>Un Certain Regard</h2>
<p>UCR SAMPLE by UCR DIRECTOR</p>
</body>
</html>
"@
$cannesNoFeatureSubheading = @(ConvertFrom-LineupHtml -Html $cannesNoFeatureSubheadingHtml -Festival "Cannes" -Region "France" -SourceUrl "https://example.test/cannes" -Parser "cannes_selection" -Year 2025)
Assert-Equal 3 $cannesNoFeatureSubheading.Count "parses Cannes Competition without feature subheading"
Assert-True (@($cannesNoFeatureSubheading | Where-Object { $_.title -eq "PARTIR UN JOUR" }).Count -eq 0) "excludes Cannes opening film marked out of competition"
Assert-Equal "In Competition - Feature films" $cannesNoFeatureSubheading[0].section "normalizes Cannes Competition feature section"

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

$sundanceNextDoubleDashHtml = @"
<html>
<body>
<h2>NEXT</h2>
<p>Pure, bold works distinguish this program.</p>
<p>BLKNWS: Terms & Conditions / U.S.A. (Director, Screenwriter, and Producer: Kahlil Joseph, Producers: Producer) -- A story.</p>
<p>By Design / U.S.A. (Director and Screenwriter: Amanda Kramer, Producers: Producer) -- A story.</p>
</body>
</html>
"@
$sundanceNextDoubleDash = @(ConvertFrom-LineupHtml -Html $sundanceNextDoubleDashHtml -Festival "Sundance" -Region "United States" -SourceUrl "https://example.test/sundance" -Parser "sundance_article" -Year 2025)
Assert-Equal 2 $sundanceNextDoubleDash.Count "parses Sundance NEXT double-dash entries"
Assert-Equal "BLKNWS: Terms & Conditions" $sundanceNextDoubleDash[0].title "keeps Sundance NEXT first title"

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
Assert-Equal 2025 $sentimentalValue[0].premiere_year "sets Oscar premiere year from previous eligibility year"

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
Assert-Equal "oscars_eligibility" $bugoniaCombined[0].year_source "marks Oscar year source"

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

$berlinaleDetailHtml = @"
<html>
<body>
<h1 class="ft__title">O ultimo azul</h1>
<span class="ft__other-title">The Blue Trail</span>
<span class="section-tag section-tag--small"><span class="color-tag"></span>Competition 2025</span>
<span class="film-meta staff">by Gabriel Mascaro (Director, Screenplay), Tiberio Azul (Screenplay)<br />with Cast</span>
<span class="film-meta country">Brazil / Mexico / Chile / Netherlands 2025</span>
</body>
</html>
"@
$berlinaleDetail = @(ConvertFrom-BerlinaleDetailHtml -Html $berlinaleDetailHtml -Festival "Berlinale" -Region "Germany" -SourceUrl "https://www.berlinale.de/en/2025/programme/202510635.html" -Year 2025 -AllowedSections @("Competition"))
Assert-Equal 1 $berlinaleDetail.Count "parses Berlinale detail page"
Assert-Equal "The Blue Trail" $berlinaleDetail[0].title "uses Berlinale English title when present"
Assert-Equal "O ultimo azul" $berlinaleDetail[0].original_title "keeps Berlinale original title"
Assert-Equal "Gabriel Mascaro" $berlinaleDetail[0].director "extracts Berlinale director"
Assert-Equal "Competition" $berlinaleDetail[0].section "extracts Berlinale section"

$busanSelectionHtml = @"
<html>
<body>
<div class="list_sec">
  <h3><strong class="">Competition</strong><small>Competition description</small></h3>
  <div class="program20"><table><tbody>
    <tr class="href_view">
      <th class="title" data-label="Title"><b onclick="location.href = '/eng/html/program/prog_view.asp?idx=82333&amp;c_idx=427&amp;sp_idx=&amp;QueryStep=2' ">Another Birth</b><button><span>Trailer</span></button></th>
      <td class="director" data-label="Director"> Isabelle KALANDAR</td>
      <td class="country" data-label="Country">Tajikistan / United States / Qatar</td>
    </tr>
    <tr class="href_view">
      <th class="title" data-label="Title"><b onclick="location.href = '/eng/html/program/prog_view.asp?idx=82334&amp;c_idx=427&amp;sp_idx=&amp;QueryStep=2' ">Girl</b></th>
      <td class="director" data-label="Director"> Shu Qi</td>
      <td class="country" data-label="Country">Taiwan</td>
    </tr>
  </tbody></table></div>
</div>
<div class="list_sec">
  <h3><strong class="">Icons</strong></h3>
  <div class="program20"><table><tbody>
    <tr class="href_view"><th class="title" data-label="Title"><b>Icon Sample</b></th><td class="director" data-label="Director"> Icon Director</td></tr>
  </tbody></table></div>
</div>
</body>
</html>
"@
$busanSelection = @(ConvertFrom-LineupHtml -Html $busanSelectionHtml -Festival "Busan" -Region "South Korea" -SourceUrl "https://www.biff.kr/eng/html/program/prog_all_list.asp?allYear=2025" -Parser "busan_selection_list" -Year 2025 -SectionScope @("Competition"))
Assert-Equal 2 $busanSelection.Count "parses Busan selection list competition"
Assert-Equal "Another Birth" $busanSelection[0].title "keeps Busan title"
Assert-Equal "Isabelle KALANDAR" $busanSelection[0].director "extracts Busan director"
Assert-Equal "Competition" $busanSelection[0].section "keeps Busan section"

$goldenHorseHtml = @"
<html>
<body>
<table class="table special award"><tbody>
  <tr><th colspan="2">Best Narrative Feature</th></tr>
  <tr class="mark"><td><a href="#"><div>A Foggy Tale</div></a></td><td>Taiwan Creative Content Agency</td></tr>
  <tr><td><a href="#"><div>Left-Handed Girl</div></a></td><td>Left-Handed Girl Film Production Co., Ltd.</td></tr>
</tbody></table>
<table class="table special award"><tbody>
  <tr><th colspan="2">Best Documentary Feature</th></tr>
  <tr class="mark"><td><a href="#"><div>Documentary Sample</div></a></td><td>Documentary Director</td></tr>
</tbody></table>
</body>
</html>
"@
$goldenHorse = @(ConvertFrom-LineupHtml -Html $goldenHorseHtml -Festival "Taipei Golden Horse Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/goldenhorse" -Parser "golden_horse_awards" -Year 2025)
Assert-Equal 2 $goldenHorse.Count "parses Golden Horse best narrative feature nominees"
Assert-True (@($goldenHorse | Where-Object { $_.title -eq "Documentary Sample" }).Count -eq 0) "excludes Golden Horse documentary nominees"
$goldenHorseWinners = @(ConvertFrom-LineupHtml -Html $goldenHorseHtml -Festival "Taipei Golden Horse Film Festival" -Region "Taiwan" -SourceUrl "https://example.test/goldenhorse" -Parser "golden_horse_awards" -Year 2025 -WinnerOnly)
Assert-Equal 1 $goldenHorseWinners.Count "keeps only Golden Horse winners when configured"
Assert-Equal "A Foggy Tale" $goldenHorseWinners[0].title "keeps the Golden Horse Best Narrative Feature winner"
Assert-Equal "Best Narrative Feature - Winner" $goldenHorseWinners[0].section "labels Golden Horse winners"
$festivalConfig = Get-Content (Join-Path $PSScriptRoot "..\config\festivals.json") -Raw | ConvertFrom-Json
$taipeiFestival = @($festivalConfig.festivals | Where-Object { $_.name -eq "Taipei Film Festival" })[0]
$goldenHorseFestival = @($festivalConfig.festivals | Where-Object { $_.name -eq "Taipei Golden Horse Film Festival" })[0]
Assert-Equal $false $taipeiFestival.enabled "disables Taipei Film Festival sync"
Assert-Equal $false $goldenHorseFestival.enabled "disables Taipei Golden Horse Film Festival sync"

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
Assert-Equal 2025 $tidf[0].premiere_year "uses official TIDF film year as premiere year"

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

$kviffCatalogueHtml = @"
<html>
<body>
<div class="col2 table no-border-top list-movies">
  <div class="col first film-49509">
    <div class="title-wrapper">
      <div class="film-title">
        <a href="/en/programme/film/84/49509-a-happy-family" class="film-name">A Happy Family</a>
      </div>
      <br />
      (Stastna rodina / A Happy Family)
    </div>
    <br />
    Directed by: Jan-Eric Mack / Switzerland, 2026, 121&nbsp;min<br />
  </div>
  <div class="col first film-49516">
    <div class="title-wrapper">
      <div class="film-title">
        <a href="/en/programme/film/84/49516-pipes" class="film-name">Pipes</a>
      </div>
    </div>
    <br />
    Directed by: Karim Kassem / Lebanon, Qatar, Saudi Arabia, 2025, 114&nbsp;min<br />
  </div>
</div>
</body>
</html>
"@
$kviffCatalogue = @(ConvertFrom-LineupHtml -Html $kviffCatalogueHtml -Festival "Karlovy Vary" -Region "Czech Republic" -SourceUrl "https://www.kviff.com/en/programme/catalogue-of-films/sekce/999-crystal-globe-competition" -Parser "kviff_archive_section" -Year 2026)
Assert-Equal 2 $kviffCatalogue.Count "parses KVIFF catalogue film cards"
Assert-Equal "A Happy Family" $kviffCatalogue[0].title "keeps KVIFF catalogue title"
Assert-Equal "Jan-Eric Mack" $kviffCatalogue[0].director "extracts KVIFF catalogue director"
Assert-Equal "Crystal Globe Competition" $kviffCatalogue[0].section "maps KVIFF catalogue source URL to section"
Assert-Equal 2026 $kviffCatalogue[0].film_year "extracts KVIFF catalogue film year"
Assert-Equal 2025 $kviffCatalogue[1].film_year "extracts KVIFF catalogue prior film year"

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

$linkRepairFilm = [pscustomobject]@{
    id = "current-canonical-film"
    canonical_key = "title:2026:legacy event:repair director"
    title = "Legacy Event"
    original_title = "Legacy Event"
    director = "Repair Director"
    film_year = 2026
    premiere_year = 2026
    notion_page_id = "current-film-page"
}
$linkRepairSelection = [pscustomobject]@{
    id = "current-selection-id"
    title = "Legacy Event"
    original_title = "Legacy Event"
    director = "Repair Director"
    film_year = 2026
    festival_year = 2026
}
$legacyEvent = [pscustomobject]@{
    id = "legacy-event"
    film_id = "old-selection-id"
    canonical_key = ""
    film_relation_ids = @("old-film-page")
    film_title = "Legacy Event"
    director = "Repair Director"
}
$titleDirectorLink = Resolve-AvailabilityEventFilmLink -Event $legacyEvent -Films @($linkRepairFilm) -Selections @($linkRepairSelection)
Assert-Equal "title_director" $titleDirectorLink.reason "resolves legacy event by unique title and director"
Assert-Equal "current-film-page" $titleDirectorLink.notion_page_id "resolves legacy event to current film page"
$linkRepair = Get-AvailabilityEventLinkRepair -Event $legacyEvent -Link $titleDirectorLink
Assert-Equal "title:2026:legacy event:repair director" $linkRepair.canonical_key "repairs missing event canonical key"
Assert-Equal "current-film-page" $linkRepair.film_notion_page_id "repairs stale event film relation"
Assert-True $linkRepair.needs_relation "detects stale event relation"

$selectionLinkedEvent = [pscustomobject]@{
    id = "selection-linked-event"
    film_id = "current-selection-id"
    canonical_key = ""
    film_relation_ids = @()
    film_title = "Legacy Event"
    director = "Repair Director"
}
$selectionLink = Resolve-AvailabilityEventFilmLink -Event $selectionLinkedEvent -Films @($linkRepairFilm) -Selections @($linkRepairSelection)
Assert-Equal "selection_id" $selectionLink.reason "resolves event through current selection id"

$activeCanonicalFilms = @(
    [pscustomobject]@{ id = "active-film"; notion_page_id = "active-page"; canonical_key = "active-key"; title = "Active Film" },
    [pscustomobject]@{ id = "orphan-film"; notion_page_id = "orphan-page"; canonical_key = "orphan-key"; title = "Orphan Film" }
)
$activeSelectionRecords = @(
    [pscustomobject]@{ id = "active-selection"; title = "Active Film"; film_relation_ids = @("active-page") }
)
$availabilityFilms = @(Select-CanonicalFilmsWithActiveSelections -Films $activeCanonicalFilms -Selections $activeSelectionRecords)
Assert-Equal 1 $availabilityFilms.Count "filters Availability to canonical films with active selections"
Assert-Equal "active-film" $availabilityFilms[0].id "keeps the canonical film referenced by an active selection"

$orphanCleanupEvent = [pscustomobject]@{
    film_id = "orphan-film"
    canonical_key = "orphan-key"
    film_relation_ids = @("orphan-page")
    film_title = "Orphan Film"
}
$orphanCleanupPlan = Get-PolicyOrphanCleanupPlan -Films $activeCanonicalFilms -Selections $activeSelectionRecords -Events @($orphanCleanupEvent) -FilmTrackerIds @("orphan-film")
Assert-Equal 1 @($orphanCleanupPlan.films).Count "plans cleanup for an explicitly targeted orphan canonical film"
Assert-Equal 1 @($orphanCleanupPlan.events).Count "plans cleanup for events linked to a targeted orphan canonical film"

$protectedCleanupError = ""
try {
    Get-PolicyOrphanCleanupPlan -Films $activeCanonicalFilms -Selections $activeSelectionRecords -Events @() -FilmTrackerIds @("active-film") | Out-Null
}
catch {
    $protectedCleanupError = $_.Exception.Message
}
Assert-True $protectedCleanupError.Contains("still have active selections") "refuses policy cleanup when a target film still has an active selection"

$alreadyLinkedEvent = [pscustomobject]@{
    id = "already-linked-event"
    film_id = "current-selection-id"
    canonical_key = "title:2026:legacy event:repair director"
    film_relation_ids = @("current-film-page")
    film_title = "Legacy Event"
    director = "Repair Director"
}
Assert-True ($null -eq (Get-AvailabilityEventLinkRepair -Event $alreadyLinkedEvent -Link $selectionLink)) "skips already repaired event links"

$ambiguousLink = Resolve-AvailabilityEventFilmLink -Event $legacyEvent -Films @(
    $linkRepairFilm,
    [pscustomobject]@{
        id = "duplicate-canonical-film"
        canonical_key = "title:2026:legacy event:repair director:duplicate"
        title = "Legacy Event"
        original_title = "Legacy Event"
        director = "Repair Director"
        film_year = 2026
        premiere_year = 2026
        notion_page_id = "duplicate-film-page"
    }
) -Selections @()
Assert-True ($null -eq $ambiguousLink) "does not resolve ambiguous title-director event links"

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
    },
    [pscustomobject]@{
        id = "selection-pending"
        title = "Pending With Event"
        original_title = "Pending With Event"
        director = "Event Director"
        year = 2025
        festival_year = 2025
        film_year = 2026
        festival = "Berlin"
        region = "Germany"
        section = "Competition"
        source_url = "https://example.test/berlin"
        tmdb_id = 1002
        imdb_id = "tt1002"
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 6.8
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    },
    [pscustomobject]@{
        id = "selection-explicit-late-premiere"
        title = "Explicit Late Premiere"
        original_title = "Explicit Late Premiere"
        director = "Year Director"
        year = 2025
        festival_year = 2025
        film_year = 2026
        premiere_year = 2026
        festival = "Berlin"
        region = "Germany"
        section = "Competition"
        source_url = "https://example.test/berlin-late"
        tmdb_id = 1006
        imdb_id = ""
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 6.2
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    },
    [pscustomobject]@{
        id = "current-canonical-selection"
        title = "Canonical Event Match"
        original_title = "Canonical Event Match"
        director = "Stable Director"
        year = 2025
        festival_year = 2025
        film_year = 2025
        festival = "NYFF"
        region = "United States"
        section = "Main Slate"
        source_url = "https://example.test/nyff"
        tmdb_id = 1003
        imdb_id = ""
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 5.8
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    },
    [pscustomobject]@{
        id = "current-title-selection"
        title = "Title Event Match"
        original_title = "Original Title Event Match"
        director = "Legacy Director"
        year = 2025
        festival_year = 2025
        film_year = 2025
        festival = "Venice"
        region = "Italy"
        section = "Competition"
        source_url = "https://example.test/venice"
        tmdb_id = 1004
        imdb_id = ""
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 6.1
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    },
    [pscustomobject]@{
        id = "current-title-only-selection"
        title = "Title Only Event Match"
        original_title = "Title Only Event Match"
        director = ""
        year = 2025
        festival_year = 2025
        film_year = 2025
        festival = "Locarno"
        region = "Switzerland"
        section = "Competition"
        source_url = "https://example.test/locarno"
        tmdb_id = 1005
        imdb_id = ""
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 6.5
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
    },
    [pscustomobject]@{
        id = "event-pending"
        film_id = "selection-pending"
        film_title = "Pending With Event"
        director = "Event Director"
        festival = "Berlin"
        event_date = "2026-05-20"
        availability_types = @("digital_rent")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/rent")
        needs_review = $false
    },
    [pscustomobject]@{
        id = "event-canonical"
        film_id = "old-selection-id"
        canonical_key = "tmdb:1003"
        film_title = "Canonical Event Match"
        director = "Stable Director"
        festival = "NYFF"
        event_date = "2026-05-21"
        availability_types = @("streaming_subscription")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/canonical")
        needs_review = $false
    },
    [pscustomobject]@{
        id = "event-title-director"
        film_id = "older-selection-id"
        film_title = "Title Event Match"
        director = "Legacy Director"
        festival = "Venice"
        event_date = "2026-05-22"
        availability_types = @("streaming_free")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/title-director")
        needs_review = $false
    },
    [pscustomobject]@{
        id = "event-title-only"
        film_id = "old-title-only-selection"
        film_title = "Title Only Event Match"
        director = "Documented Director"
        festival = "Locarno"
        event_date = "2026-05-23"
        availability_types = @("digital_buy")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/title-only")
        needs_review = $false
    }
)
ConvertTo-Json -InputObject $duplicateFestivalFilms -Depth 10 | Set-Content -Path (Join-Path $exportStateDir "films.json") -Encoding UTF8
ConvertTo-Json -InputObject $duplicateEvents -Depth 10 | Set-Content -Path (Join-Path $exportStateDir "events.json") -Encoding UTF8
& (Join-Path $PSScriptRoot "..\scripts\Export-TrackerData.ps1") -OutputPath $exportOutput -StateDir $exportStateDir | Out-Null
$exportedWebData = Get-Content $exportOutput -Raw | ConvertFrom-Json
$exportedSelectionCount = @($exportedWebData.films | ForEach-Object { @($_.selections) }).Count
Assert-Equal 6 $exportedWebData.totals.films "exports unique web cards for duplicate TMDb selections"
Assert-Equal 7 $exportedWebData.totals.selections "keeps all festival selections in export totals"
Assert-Equal $exportedSelectionCount $exportedWebData.totals.selections "keeps totals selections aligned with exported selection records"
Assert-Equal $exportedSelectionCount $exportedWebData.selectionCount "keeps legacy selectionCount aligned with exported selection records"
Assert-True ($null -eq $exportedWebData.totals.needsReview) "does not expose legacy review count in main totals"
Assert-Equal 5 $exportedWebData.totals.available "counts available by unique web film"
Assert-Equal 5 $exportedWebData.totals.events "keeps finds aligned with raw availability events"
$pendingEventFilm = @($exportedWebData.films | Where-Object { $_.title -eq "Pending With Event" })[0]
Assert-Equal "available_found" $pendingEventFilm.trackingStatus "normalizes pending films with availability events"
Assert-Equal "2026-05-20" $pendingEventFilm.firstAvailableDate "fills first available date from availability event"
Assert-Equal 4 $exportedWebData.diagnostics.pendingWithAvailability "diagnoses source pending films with availability"
$canonicalEventFilm = @($exportedWebData.films | Where-Object { $_.title -eq "Canonical Event Match" })[0]
Assert-Equal "available_found" $canonicalEventFilm.trackingStatus "matches availability events by canonical key when legacy film id changed"
Assert-Equal "2026-05-21" $canonicalEventFilm.firstAvailableDate "fills first available date from canonical-key event"
Assert-Equal "event-canonical" $canonicalEventFilm.availability[0].id "attaches canonical-key event to exported film"
$titleEventFilm = @($exportedWebData.films | Where-Object { $_.title -eq "Title Event Match" })[0]
Assert-Equal "available_found" $titleEventFilm.trackingStatus "matches legacy availability events by title and director"
Assert-Equal "event-title-director" $titleEventFilm.availability[0].id "attaches title-director matched event to exported film"
$titleOnlyEventFilm = @($exportedWebData.films | Where-Object { $_.title -eq "Title Only Event Match" })[0]
Assert-Equal "available_found" $titleOnlyEventFilm.trackingStatus "attaches unique title-only orphan event after web merge"
Assert-Equal "event-title-only" $titleOnlyEventFilm.availability[0].id "attaches unique title-only event to exported film"
Assert-Equal 1 $exportedWebData.diagnostics.lowConfidence "exports low confidence as diagnostics"
$duplicateExportFilm = @($exportedWebData.films | Where-Object { $_.title -eq "Duplicate Export" })[0]
Assert-Equal 2 $duplicateExportFilm.selections.Count "keeps duplicate selections on merged web card"
Assert-Equal 2024 $duplicateExportFilm.filmYear "keeps film year separate from festival year"
Assert-Equal 2024 $duplicateExportFilm.premiereYear "exports premiere year from legacy film year when it predates festival year"
Assert-Equal 7.8 $duplicateExportFilm.imdbRating "exports IMDb rating"
Assert-Equal 12345 $duplicateExportFilm.imdbVotes "exports IMDb vote count"
Assert-Equal 0 $exportedWebData.diagnostics.duplicateCanonical "exports duplicate canonical diagnostics"
Assert-Equal 6 $exportedWebData.diagnostics.missingPoster "exports missing poster diagnostics after merge"
Assert-Equal 0 $exportedWebData.diagnostics.missingTmdb "exports missing TMDb diagnostics"
Assert-Equal 1 $exportedWebData.diagnostics.missingDirector "exports missing director diagnostics"
Assert-Equal 6 $exportedWebData.diagnostics.missingPosterFilms.Count "exports missing poster film list"
Assert-True (@($exportedWebData.diagnostics.missingPosterFilms | Where-Object { $_.title -eq "Duplicate Export" }).Count -eq 1) "exports diagnostic film title"
Assert-Equal "Duplicate Export" $exportedWebData.diagnostics.lowConfidenceFilms[0].title "exports low confidence film list"
Assert-Equal 2025 $pendingEventFilm.premiereYear "falls back to festival year when legacy TMDb film year is later"
Assert-Equal 2025 $pendingEventFilm.filmYear "keeps legacy web filmYear aligned with premiere year"
Assert-Equal 2026 $pendingEventFilm.releaseYear "moves later legacy TMDb film year into release year"
$explicitLatePremiereFilm = @($exportedWebData.films | Where-Object { $_.title -eq "Explicit Late Premiere" })[0]
Assert-Equal 2025 $explicitLatePremiereFilm.premiereYear "repairs explicit premiere year later than earliest festival year"
Assert-Equal 2025 $explicitLatePremiereFilm.filmYear "keeps explicit late premiere web filmYear aligned with repaired premiere year"
Assert-Equal 2026 $explicitLatePremiereFilm.releaseYear "preserves explicit late premiere year as release year"
Assert-Equal "festival_year_fallback" $explicitLatePremiereFilm.yearSource "marks explicit late premiere repair as festival year fallback"
Assert-Equal "2025,2024" (($exportedWebData.years | ForEach-Object { [string]$_ }) -join ",") "exports browse years from premiere years"
Assert-Equal "2025,2024" (($exportedWebData.premiereYears | ForEach-Object { [string]$_ }) -join ",") "exports premiere year filter options"
Assert-Equal "2025,2024" (($exportedWebData.filmYears | ForEach-Object { [string]$_ }) -join ",") "keeps legacy filmYears aligned with premiere years"
Assert-Equal "2025" (($exportedWebData.festivalYears | ForEach-Object { [string]$_ }) -join ",") "exports festival years from selections"
Assert-Equal "Berlin,Cannes,Locarno,NYFF,Venice" (($exportedWebData.festivals | ForEach-Object { [string]$_ }) -join ",") "exports festival filter options from individual selections"
Remove-Item -LiteralPath $exportStateDir -Recurse -Force

$qualityStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("festival-quality-test-" + [guid]::NewGuid().ToString("N"))
$qualityOutput = Join-Path $qualityStateDir "tracker-data.json"
New-Item -ItemType Directory -Path $qualityStateDir -Force | Out-Null
ConvertTo-Json -InputObject @($duplicateFestivalFilms[0]) -Depth 10 | Set-Content -Path (Join-Path $qualityStateDir "films.json") -Encoding UTF8
ConvertTo-Json -InputObject @(
    [pscustomobject]@{
        id = "orphan-event"
        film_id = "missing-selection"
        film_title = "Orphan Event"
        director = "Nobody"
        festival = "Cannes"
        event_date = "2026-05-22"
        availability_types = @("streaming_subscription")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/orphan")
        needs_review = $false
    }
) -Depth 10 | Set-Content -Path (Join-Path $qualityStateDir "events.json") -Encoding UTF8
& (Join-Path $PSScriptRoot "..\scripts\Export-TrackerData.ps1") -OutputPath $qualityOutput -StateDir $qualityStateDir | Out-Null
$qualityScript = Join-Path $PSScriptRoot "..\scripts\Test-TrackerDataQuality.ps1"
$qualityCheckOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $qualityScript -DataPath $qualityOutput 2>&1
$qualityExitCode = $LASTEXITCODE
Assert-True ($qualityExitCode -ne 0) "quality check fails orphaned availability events"
Assert-True (([string]($qualityCheckOutput -join "`n")).Contains("orphaned_availability_event")) "quality check reports orphaned availability event code"
Remove-Item -LiteralPath $qualityStateDir -Recurse -Force

$sourcePolicyQualityDir = Join-Path ([System.IO.Path]::GetTempPath()) ("festival-source-policy-test-" + [guid]::NewGuid().ToString("N"))
$sourcePolicyQualityOutput = Join-Path $sourcePolicyQualityDir "tracker-data.json"
New-Item -ItemType Directory -Path $sourcePolicyQualityDir -Force | Out-Null
[pscustomobject]@{
    films = @(
        [pscustomobject]@{
            id = "taipei-disabled"
            title = "Taipei Disabled Film"
            selections = @([pscustomobject]@{
                id = "taipei-disabled-selection"
                festival = "Taipei Film Festival"
                section = "Taipei Film Awards - Best Narrative Feature"
                festivalYear = 2025
                sourceUrl = ""
            })
            availability = @()
        },
        [pscustomobject]@{
            id = "golden-horse-nominee"
            title = "Golden Horse Nominee"
            selections = @([pscustomobject]@{
                id = "golden-horse-nominee-selection"
                festival = "Taipei Golden Horse Film Festival"
                section = "Best Narrative Feature"
                festivalYear = 2025
                sourceUrl = ""
            })
            availability = @()
        }
    )
    events = @()
} | ConvertTo-Json -Depth 10 | Set-Content -Path $sourcePolicyQualityOutput -Encoding UTF8
$sourcePolicyQualityCheckOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $qualityScript -DataPath $sourcePolicyQualityOutput 2>&1
$sourcePolicyQualityExitCode = $LASTEXITCODE
Assert-True ($sourcePolicyQualityExitCode -ne 0) "quality check fails selections from both disabled Taipei festivals"
Assert-True (([string]($sourcePolicyQualityCheckOutput -join "`n")).Contains("disabled_taipei_festival_selection")) "quality check reports disabled Taipei selection code"
Assert-True (([string]($sourcePolicyQualityCheckOutput -join "`n")).Contains("disabled_golden_horse_selection")) "quality check reports disabled Golden Horse code"
Remove-Item -LiteralPath $sourcePolicyQualityDir -Recurse -Force

$ambiguousStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("festival-ambiguous-event-test-" + [guid]::NewGuid().ToString("N"))
$ambiguousOutput = Join-Path $ambiguousStateDir "tracker-data.json"
New-Item -ItemType Directory -Path $ambiguousStateDir -Force | Out-Null
ConvertTo-Json -InputObject @(
    [pscustomobject]@{
        id = "ambiguous-a"
        title = "Ambiguous Event Match"
        original_title = "Ambiguous Event Match"
        director = ""
        year = 2026
        festival_year = 2026
        film_year = 2026
        festival = "Cannes"
        region = "France"
        section = "Competition"
        source_url = "https://example.test/a"
        tmdb_id = 2001
        imdb_id = ""
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 5.1
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    },
    [pscustomobject]@{
        id = "ambiguous-b"
        title = "Ambiguous Event Match"
        original_title = "Ambiguous Event Match"
        director = ""
        year = 2026
        festival_year = 2026
        film_year = 2026
        festival = "Venice"
        region = "Italy"
        section = "Competition"
        source_url = "https://example.test/b"
        tmdb_id = 2002
        imdb_id = ""
        match_confidence = 1
        poster_url = ""
        overview = ""
        tmdb_rating = 5.2
        tracking_status = "pending"
        first_available_date = ""
        last_checked = ""
        needs_review = $false
        authorized_source_urls = @()
    }
) -Depth 10 | Set-Content -Path (Join-Path $ambiguousStateDir "films.json") -Encoding UTF8
ConvertTo-Json -InputObject @(
    [pscustomobject]@{
        id = "ambiguous-event"
        film_id = "old-ambiguous-selection"
        film_title = "Ambiguous Event Match"
        director = "Known Director"
        festival = "Cannes"
        event_date = "2026-05-24"
        availability_types = @("streaming_subscription")
        providers = @("Test")
        countries = @("US")
        source_urls = @("https://example.test/ambiguous")
        needs_review = $false
    }
) -Depth 10 | Set-Content -Path (Join-Path $ambiguousStateDir "events.json") -Encoding UTF8
& (Join-Path $PSScriptRoot "..\scripts\Export-TrackerData.ps1") -OutputPath $ambiguousOutput -StateDir $ambiguousStateDir | Out-Null
$ambiguousWebData = Get-Content $ambiguousOutput -Raw | ConvertFrom-Json
$ambiguousAttachedCount = @($ambiguousWebData.films | ForEach-Object { @($_.availability) }).Count
Assert-Equal 0 $ambiguousAttachedCount "does not attach ambiguous title-only orphan event"
$ambiguousQualityOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $qualityScript -DataPath $ambiguousOutput 2>&1
$ambiguousQualityExitCode = $LASTEXITCODE
Assert-True ($ambiguousQualityExitCode -ne 0) "quality check still fails ambiguous orphaned event"
Remove-Item -LiteralPath $ambiguousStateDir -Recurse -Force

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

$tmdbDetailsWithPremieres = [pscustomobject]@{
    release_dates = [pscustomobject]@{
        results = @(
            [pscustomobject]@{
                iso_3166_1 = "IT"
                release_dates = @(
                    [pscustomobject]@{ type = 1; release_date = "2025-09-01T00:00:00.000Z" },
                    [pscustomobject]@{ type = 3; release_date = "2026-01-10T00:00:00.000Z" }
                )
            },
            [pscustomobject]@{
                iso_3166_1 = "TH"
                release_dates = @([pscustomobject]@{ type = 1; release_date = "2025-08-28T00:00:00.000Z" })
            }
        )
    }
}
Assert-Equal 2025 (Get-TmdbPremiereYearFromDetails -Details $tmdbDetailsWithPremieres) "extracts earliest TMDb premiere release year"

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
Assert-Equal 2025 $canonicalFilmProperties["Premiere Year"].number "stores premiere year on canonical film"
Assert-Equal "festival_year_fallback" $canonicalFilmProperties["Year Source"].rich_text[0].text.content "stores year source on canonical film"

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
$completeMetadataFilm.release_year = 2026
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
