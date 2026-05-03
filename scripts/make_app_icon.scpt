use framework "Foundation"
use framework "AppKit"
use scripting additions

-- Vykreslí ikonu SPZ.app: tmavě modrý zaoblený čtverec, bílý "license plate" pruh
-- s textem SPZ, a stylizovaná kamera nad ním.
on run argv
    set outPath to item 1 of argv as text

    set W to 1024
    set img to current application's NSImage's alloc()'s initWithSize:{W, W}
    img's lockFocus()

    -- Background — modrý gradient (tmavá modř → svěží modř)
    set bgRect to current application's NSMakeRect(0, 0, W, W)
    set bg to current application's NSBezierPath's bezierPathWithRoundedRect:bgRect xRadius:220 yRadius:220
    set startColor to current application's NSColor's colorWithSRGBRed:0.06 green:0.31 blue:0.66 alpha:1.0
    set endColor to current application's NSColor's colorWithSRGBRed:0.16 green:0.50 blue:0.95 alpha:1.0
    set grad to current application's NSGradient's alloc()'s initWithStartingColor:startColor endingColor:endColor
    grad's drawInBezierPath:bg angle:135.0

    -- License-plate pruh — bílý zaoblený obdélník v dolní třetině
    set plateRect to current application's NSMakeRect(140, 200, W - 280, 240)
    set plate to current application's NSBezierPath's bezierPathWithRoundedRect:plateRect xRadius:32 yRadius:32
    (current application's NSColor's whiteColor())'s setFill()
    plate's fill()

    -- Modrý okraj plate (EU style)
    set plateBorder to current application's NSBezierPath's bezierPathWithRoundedRect:plateRect xRadius:32 yRadius:32
    set borderColor to current application's NSColor's colorWithSRGBRed:0.06 green:0.20 blue:0.50 alpha:1.0
    borderColor's setStroke()
    plateBorder's setLineWidth:8
    plateBorder's stroke()

    -- Modrý čtverec vlevo s "EU" placeholderem
    set euRect to current application's NSMakeRect(160, 220, 90, 200)
    set euBox to current application's NSBezierPath's bezierPathWithRoundedRect:euRect xRadius:16 yRadius:16
    set euBlue to current application's NSColor's colorWithSRGBRed:0.06 green:0.20 blue:0.66 alpha:1.0
    euBlue's setFill()
    euBox's fill()

    -- Text "SPZ" do plate
    set spzColor to current application's NSColor's colorWithSRGBRed:0.07 green:0.18 blue:0.45 alpha:1.0
    set fontSize to 200
    set spzFont to current application's NSFont's fontWithName:"Helvetica-Bold" |size|:fontSize
    if spzFont is missing value then
        set spzFont to current application's NSFont's boldSystemFontOfSize:fontSize
    end if
    set txtAttrs to current application's NSDictionary's dictionaryWithObjects:{spzFont, spzColor} forKeys:{current application's NSFontAttributeName, current application's NSForegroundColorAttributeName}
    set spzString to current application's NSAttributedString's alloc()'s initWithString:"SPZ" attributes:txtAttrs
    set strSize to spzString's |size|()
    set tx to 290 + ((W - 280 - 130 - (width of strSize)) / 2)
    set ty to 220 + ((240 - (height of strSize)) / 2)
    spzString's drawAtPoint:{tx, ty}

    -- Kamera nad plate — bílá silueta
    -- Tělo kamery (zaoblený obdélník)
    set camBodyRect to current application's NSMakeRect(280, 540, 360, 280)
    set camBody to current application's NSBezierPath's bezierPathWithRoundedRect:camBodyRect xRadius:48 yRadius:48
    (current application's NSColor's whiteColor())'s setFill()
    camBody's fill()

    -- Objektiv (kruh uprostřed těla)
    set lensRect to current application's NSMakeRect(380, 590, 180, 180)
    set lensOuter to current application's NSBezierPath's bezierPathWithOvalInRect:lensRect
    set lensColor to current application's NSColor's colorWithSRGBRed:0.06 green:0.31 blue:0.66 alpha:1.0
    lensColor's setFill()
    lensOuter's fill()

    -- Vnitřní kruh objektivu (lesk)
    set lensInnerRect to current application's NSMakeRect(420, 630, 100, 100)
    set lensInner to current application's NSBezierPath's bezierPathWithOvalInRect:lensInnerRect
    set lensInnerColor to current application's NSColor's colorWithSRGBRed:0.16 green:0.50 blue:0.95 alpha:1.0
    lensInnerColor's setFill()
    lensInner's fill()

    -- Highlight na objektivu
    set highlightRect to current application's NSMakeRect(440, 700, 30, 30)
    set highlight to current application's NSBezierPath's bezierPathWithOvalInRect:highlightRect
    (current application's NSColor's whiteColor())'s setFill()
    highlight's fill()

    -- Top "viewfinder" obdélníček
    set vfRect to current application's NSMakeRect(420, 820, 100, 50)
    set vfPath to current application's NSBezierPath's bezierPathWithRoundedRect:vfRect xRadius:10 yRadius:10
    (current application's NSColor's whiteColor())'s setFill()
    vfPath's fill()

    -- Záznamová červená tečka v rohu těla
    set recRect to current application's NSMakeRect(580, 770, 30, 30)
    set rec to current application's NSBezierPath's bezierPathWithOvalInRect:recRect
    set redColor to current application's NSColor's colorWithSRGBRed:0.94 green:0.27 blue:0.27 alpha:1.0
    redColor's setFill()
    rec's fill()

    img's unlockFocus()

    -- Export PNG
    set tiff to img's TIFFRepresentation()
    set rep to current application's NSBitmapImageRep's imageRepWithData:tiff
    set png to rep's representationUsingType:4 |properties|:(current application's NSDictionary's dictionary())
    png's writeToFile:outPath atomically:true

    return outPath
end run
