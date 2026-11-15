# What's New

What has arrived since the 0.9.0 beta, by area. Each line says what the feature does and links to where it is described in full. For a guided tour of the most useful ones, try the tutorials: [Culling and Organising](Tutorial-Culling-and-Organising), [Editing](Tutorial-Editing) and [Printing and Sharing](Tutorial-Printing-and-Sharing).

## Wave 4

- **Edit Capture Time…** (Metadata menu) shifts the selection's capture times by days, hours, minutes and seconds, sets the first photo to an exact time and moves the rest with it, or changes time zone. The raw files are never rewritten; the corrected time is kept in the catalog and sidecar, sorting and date filters use it, and it can be undone. See [Capture time and geotagging](Library#capture-time-and-geotagging).
- **Geotag from GPX Track…** (Metadata menu) places the selection on a GPX track you choose, interpolating between track points, with a camera clock offset, a largest gap to bridge, and a count of matches before anything is written. Photos that already have a position keep it unless you tick Replace existing positions. See [Capture time and geotagging](Library#capture-time-and-geotagging).

## Organising

- **Collections, smart collections and collection sets** gather photos without moving them; smart ones fill themselves from rules such as "rated 4 or more with the keyword Brittany". See [Collections](Collections-and-Keywords#collections).
- **Quick Collection and B** put the selection in a scratch collection with one key, as in Lightroom. See [Collections](Collections-and-Keywords#collections).
- **Save Filter as Smart Collection** turns whatever the filter bar is showing into a smart collection. See [Smart collections](Collections-and-Keywords#smart-collections).
- **Keywords inside keywords**, such as Places › France › Paris, written to sidecars the way Lightroom writes them. See [Keywords inside keywords](Collections-and-Keywords#keywords-inside-keywords).
- **Keywording a whole selection**, with suggestions as you type, and a **Keyword List** to filter, rename and delete keywords across the folder. See [Keywords](Collections-and-Keywords#keywords).
- **More smart collection rules**: is between for numbers and dates; title, caption, creator, copyright, folder, exposure time, aspect ratio, edit date, in a stack, virtual copy, kind and edit changes; keyword is empty, and file type is raw. See [Smart collections](Collections-and-Keywords#smart-collections).
- **Value menus in smart collections** list the cameras, lenses, keywords, folders and other values the folder's photos have. See [Smart collections](Collections-and-Keywords#smart-collections).
- **And, or and except between smart collection rules**, read from the top down. See [Smart collections](Collections-and-Keywords#smart-collections).
- **Recent collections** at the top of the Collections section reopen the last eight you looked at. See [Collections](Collections-and-Keywords#collections).
- **A keyword dictionary** for every folder: dictionary keywords in the Keyword List, New Keyword…, drag to rearrange, and plain-text keyword lists in and out. See [The keyword dictionary](Collections-and-Keywords#the-keyword-dictionary).
- **Keyword suggestions**: Recent and Often used with chips under the Add keywords field. See [Adding keywords](Collections-and-Keywords#adding-keywords).
- **Add Keywords…** (⌘K) jumps to the keywording field, and photos dragged onto the Keyword List get that keyword. See [Adding keywords](Collections-and-Keywords#adding-keywords).
- **Colour labels** with Lightroom's keys, 6 to 9, a label filter and a dot on each thumbnail. See [Colour labels](Library#colour-labels).
- **Title, caption, creator and copyright** for one photo or many, carried into every export. See [Title, caption, creator and copyright](Library#title-caption-creator-and-copyright).
- **Rename with Template** renames a whole selection from tokens such as `{date}` and `{seq}`, with every new name shown first. See [Moving, copying and renaming](Library#moving-copying-and-renaming).
- **Ratings and keywords from darktable, Lightroom and Capture One sidecars** come across when a photo is first catalogued, and File › Import Ratings and Keywords from Other Apps' Sidecars… fills in photos already there. See [Ratings and keywords from other apps](Library#ratings-and-keywords-from-other-apps).
- **Headline, location, contact details and instructions** under Title & Copyright's More, in sidecars and exports. See [Title, caption, creator and copyright](Library#title-caption-creator-and-copyright).
- **Metadata presets and existing-value menus** fill descriptive fields in one step. See [Title, caption, creator and copyright](Library#title-caption-creator-and-copyright).
- **Exposure bias, flash, metering, white balance and GPS** in the Metadata panel, with Various for mixed selections, Copy Coordinates and a choice of rows; smart collections can match exposure bias, flash fired and has GPS. See [Metadata panel](Library#metadata-panel).
- **A configurable info line** under the image in Loupe and Compare, above or below it. See [Loupe, Compare and Survey](Library#loupe-compare-and-survey).
- **Virtual copies** (⌘') give one photo several versions with their own edits, sharing the raw file; **Duplicate** makes a real second file. See [Virtual copies](Library#virtual-copies).
- **Versions** in Develop lists a photo's master and copies with thumbnails and names of their own, and **New Blank Copy** starts a copy from the default edit. See [Virtual copies](Library#virtual-copies).
- **Stacks**: Group into Stack (⌘G), Unstack (⇧⌘G), S to expand or collapse, Move to Top of Stack, and Auto-Stack by Capture Time, with the stack's count on its thumbnail. Exports can be added to the catalog and stacked with their originals. See [Stacks](Library#stacks).

## Culling and the grid

- **Auto Advance**, ⇧ with a star, flag or label key, **Select by Flag, Rating or Colour Label**, **Invert Selection**, **Deselect Unflagged** and **Refine Photos** speed up culling, as in Lightroom. See [Faster culling](Library#faster-culling).
- **Reset to Camera Orientation** takes back the quarter turns you gave the selection. See [The grid](Library#the-grid).
- **Flip Horizontal and Flip Vertical for a whole selection**, from the Photo menu or a right-click, and **Mirror Image Mode** to see the library mirrored without changing a thing. See [The grid](Library#the-grid).
- **Search all fields** looks through names, paths, titles, captions, creator, copyright, camera, lens and keywords, with every word required, "quoted phrases" and -excluded words. See [More filters](Library#the-grid).
- **Excluding colour labels**: Option-click a label in the Label menu to hide photos with it. See [More filters](Library#the-grid).
- **Rating range**: at least, exactly, at most or between, from a popover beside the stars. See [More filters](Library#the-grid).
- **Ranges** filter by ISO, focal length, aperture and exposure time, each over a histogram of the folder. See [More filters](Library#the-grid).
- **Date range** filter, with Today, Last 7 Days, This Month and This Year. See [More filters](Library#the-grid).
- **Kind** filters: Raw, Not Raw or RAW+JPEG Pair, and Masters, Virtual Copies or Has Virtual Copies. See [More filters](Library#the-grid).
- **Unedited** (Option-click Edited) and **Edit › Select Unedited**. See [More filters](Library#the-grid).
- **Filter presets** save the filter bar's settings under a name and apply them again. See [More filters](Library#the-grid).
- **No Keywords** in the keyword menu and the Keyword List. See [More filters](Library#the-grid).
- **View › Grid Marks**: Always, On Hover, Minimal and Extended thumbnails. See [The grid](Library#the-grid).
- **Keyword badge and tooltips**: a tag on thumbnails with keywords, listing them, and the edited pencil lists what the edit changes. See [The grid](Library#the-grid).
- **Fifteen more sort orders**, Lightroom's Added Order, Edit Time, Edit Count, Pick, Label Text and Colour, File Extension and Type, Aspect Ratio, Title and Caption, plus Camera, Lens, ISO and Focal Length, and View › Sort › Reverse Sort Order. See [The grid](Library#the-grid).

## Folders and files

- **Folder watching**: photos copied into, renamed in or deleted from the open folder appear and go by themselves; **Refresh Folder** (⌘R) checks at any time. See [Watching folders](Library#watching-folders).
- **Auto Import** moves (or copies) new photos in from a folder your card reader or tethering app saves into, optionally applying a develop preset. See [Watching folders](Library#watching-folders).
- **Recently Added** in the sidebar shows what the latest scan found. See [The sidebar](Library#the-sidebar).
- **Find folder**, **Add Parent Folder…** and **volume meters** in the sidebar help you get around and keep an eye on free space. See [The sidebar](Library#the-sidebar).
- **JPEG, HEIC, TIFF and PNG** (and WebP and AVIF where macOS reads them) are catalogued and open in Develop, looking exactly as they are. See [JPEG, TIFF and other pictures](Develop#jpeg-tiff-and-other-pictures).
- **Catalog backups**: each folder's catalog is copied into `_latent/backups/` once a day and before any format change, keeping five, and **Settings › Folders › Restore Catalog Backup…** puts one back. See [The catalog](Library#the-catalog).
- **More raw formats**: 22 rarer ones LibRaw reads, from Kodak KDC and DCR to GoPro GPR, Mamiya MEF and Panasonic RAW, are catalogued. See [Supported files](Library#supported-files).
- **JPEG XL pictures** open where macOS reads them. See [Supported files](Library#supported-files).
- **RAW+JPEG pairs** show as one photo, and the JPEG moves and renames with its raw. See [RAW+JPEG pairs](Library#rawjpeg-pairs).
- **Verify Files** reads every file again and finds ones that were silently damaged (same size and date, different content), with a mark on their thumbnails. See [Verifying files](Library#verifying-files).
- **Find Duplicates** groups photos whose files are identical, or taken at the same moment, and selects or rejects all but the one to keep. See [Finding duplicates](Library#finding-duplicates).
- **Pause and Resume** for thumbnails, exports, Remove Dust and Find Faces, and an **Activity** button in the status bar listing everything running in the background. See [Background activity](Library#background-activity).
- **Settings › Performance** sets thumbnail quality, how hard background thumbnail generation works and how much memory the grid keeps, and shows and tidies the folder's thumbnail cache; **File › Rebuild Thumbnails** remakes the selection's. Big folders also sort, search and keep their selection faster. See [Thumbnails and performance](Library#thumbnails-and-performance).

## Viewing

- **Before/After views**: side by side, split, top and bottom (⇧Y), with Copy After → Before, Copy Before → After and Swap. See [Before/After and Reference view](Develop#beforeafter-and-reference-view).
- **Reference view** (⇧R) edits one photo beside another, dragged in from the filmstrip, with Lock and Swap. See [Before/After and Reference view](Develop#beforeafter-and-reference-view).
- **Loupe overlay** (⌥⌘O): a grid, draggable guides and a layout image over the photo in Loupe and Develop. See [Loupe overlay](Develop#loupe-overlay).
- **Clipping overlay** (J), a colour readout under the pointer and a histogram you can drag. See [The viewport](Develop#the-viewport).
- **Clipping warning options**: Any channel, Luminance or Saturation (gamut), shadow and highlight lines, and red and blue, magenta and cyan or black and white. See [The viewport](Develop#the-viewport).
- **Raw clipping** (View › Show Raw Clipping) marks in magenta what the sensor clipped, apart from J's output clipping. See [The viewport](Develop#the-viewport).
- **Focus peaking** (View › Focus Peaking) draws the sharpest edges in colour in Develop, Loupe, Compare and Survey. See [The viewport](Develop#the-viewport).
- **Colour assessment** (View › Colour Assessment) frames the picture in 18% grey with a white border, as ISO 12646 asks. See [The viewport](Develop#the-viewport).
- **High quality preview** (View › High Quality Preview, opt-in) draws the fitted view from a full-resolution render. See [The viewport](Develop#the-viewport).
- **Navigator and zoom levels**: the whole picture with the view outlined at the top of Develop's panel, and a Fit, Fill, 25% to 400% menu in the status bar. See [The viewport](Develop#the-viewport).
- **RGB parade**, the waveform's three channels side by side. See [The viewport](Develop#the-viewport).
- **Two scopes at once**: Waveform + Vectorscope and Histogram + Vectorscope. See [The viewport](Develop#the-viewport).
- **Vectorscope guides**: a skin tone line and colour-harmony spokes you can turn by dragging. See [The viewport](Develop#the-viewport).
- **Colour picker sizes and spaces**: a 5, 15 or 31 px mean with its least and greatest values, in RGB, HSL, LCh or Lab, and Copy Value. See [The viewport](Develop#the-viewport).
- **Pinned colour samples**: Option-click to pin up to eight, with live values, markers on the photo and dots on the vectorscope. See [The viewport](Develop#the-viewport).

## Colour and tone

- **Profiles**: Latent Standard, Neutral and Flat, the creative looks Vivid, Portrait and Landscape, and four black and white looks, each a starting point before any slider. See [Develop](Develop#modules).
- **Camera profiles (DCP)** that you import yourself give your camera maker's colour. See [Develop](Develop#modules).
- **White balance presets and the White Balance Selector** (W): Daylight, Cloudy, Tungsten and the rest, or click something neutral; Temperature now takes a typed Kelvin value. See [Develop](Develop#modules).
- **Camera white balance presets**: the camera's own Daylight, Shade, Tungsten and Kelvin settings, when its raw records them. See [Develop](Develop#modules).
- **Saturation** moves every colour by the same amount, beside Vibrance. See [Develop](Develop#modules).
- **Black & White** treatment (V) with a B&W Mix that sets how light each colour turns, and an Auto mix. See [Develop](Develop#modules).
- **Colour Grading** with shadow, midtone, highlight and global wheels replaces Split Toning; older edits look exactly as they did. See [Develop](Develop#modules).
- **Calibration** shifts the camera's red, green and blue primaries and tints the shadows. See [Develop](Develop#modules).
- **Point Colour** changes one colour picked from the photo, such as evening out skin. See [Develop](Develop#modules).
- **Region tone curve** with Highlights, Lights, Darks and Shadows sliders, point curve presets and **Refine Saturation**. See [Develop](Develop#modules).
- **Targeted adjustment**: drag up or down on the photo itself to move the curve or the HSL sliders. See [Develop](Develop#modules).
- **Auto** now sets Highlights, Shadows, Whites, Blacks, Vibrance and Saturation as well, and **Shift-double-click** on one tone slider sets just that one. See [Develop](Develop#modules).
- **⌥-drag on an HSL slider** shows only the colours it changes, and the Colour Grading wheels take **⇧** (keep the hue) and **⌘** (fine moves). See [Develop](Develop#modules).
- **HDR Limit** sets how far above white each photo's highlights may go on an HDR screen and in an HDR export. See [HDR Limit](Develop#hdr-limit).
- **Visualise HDR Ranges** colours what lies above SDR white by stops, and the readout says how far above white a colour is. See [HDR Limit](Develop#hdr-limit).
- **Tone Equalizer** raises or lowers nine bands of brightness, −8 to 0 EV, through an edge-aware mask, so a sky or a shadowed face moves as a whole and keeps its local contrast; its Advanced tab draws the bands as a curve over the mask's histogram, Show Mask shows the mask in grey, and the on-image tool raises or lowers the band under the pointer by scrolling or dragging. See [Tone Equalizer](Develop#tone-equalizer).
- **Range compression presets**: Compress Shadows and Highlights (Soft and Strong) and Lift Shadows with the tone equalizer, and Compress Range with the Highlights, Shadows and Clarity sliders. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Highlight Reconstruction › Inpaint Opposed** rebuilds blown skies and skin from the colour around them instead of turning them white. See [Develop](Develop#modules).
- **Match Total Exposures** (⌥⇧⌘M) gives a selection one brightness from their shutter, aperture and ISO. See [Applying edits to many images](Library#applying-edits-to-many-images).
- **Exposure eyedropper**: click or drag over something that should be middle grey and Exposure is set from it; Option-click for another target. See [Develop](Develop#modules).
- **Black Offset**, under Exposure's Advanced, deepens or lifts the blacks in linear light. See [Develop](Develop#modules).
- **Match Exposures by Histogram** evens out a selection's brightness from the pictures themselves, by a percentile you choose. See [Applying edits to many images](Library#applying-edits-to-many-images).
- **Adaptation** in Calibration carries colours lit by a CIE standard light (tungsten, fluorescent, LED and more) to daylight, by CAT16, Bradford or XYZ scaling. See [Develop](Develop#modules).
- **Channel Mixer** builds each output channel from the red, green and blue sources, with Normalise and a Monochrome preset. See [Develop](Develop#modules).
- **Gamut Compression** eases out-of-gamut colours softly back inside. See [Develop](Develop#modules).
- **Highlight Purity** gives back the colour the tone curve bleaches out of the brightest tones. See [Develop](Develop#modules).
- **Colour Grading per-range saturation and Hue Shift**: a saturation slider for shadows, midtones and highlights, and one hue turn for the whole picture. See [Develop](Develop#modules).
- **Colour Grading range graph and preview**: a graph of where each range reaches, and ⌥-drag on a luminance slider to see that range on the photo. See [Develop](Develop#modules).

## Geometry

- **Upright** straightens converging lines automatically, or from guides you draw, and the **Transform** sliders correct keystone, rotation, aspect, scale and offset. See [Transform and Upright](Develop#transform-and-upright).
- **Flips** and **Constrain Crop**. See [Transform and Upright](Develop#transform-and-upright).
- **Copy Settings' Upright choices**: Upright Mode (analysed again on each photo), Upright Transforms, Transform Adjustments and Constrain Crop are separate groups, as in Lightroom. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Flat-field correction** takes a reference frame's vignetting and colour cast out of a whole selection. See [Flat-field correction](Develop#flat-field-correction).
- **Fine straightening**: ⌥[ and ⌥] turn the picture a tenth of a degree, with ⇧ a whole degree. See [Modules](Develop#modules).
- **Crop guides** (O) such as thirds, golden ratio and golden spiral, and a **Surround** that sets how dark the area outside the crop is. See [Crop guides and the surround](Develop#crop-guides-and-the-surround).

## Detail and effects

- **Sharpening Detail and Masking** control halos and keep sharpening off smooth areas; hold ⌥ on Masking to see where it works. See [Sharpening and noise reduction](Develop#sharpening-and-noise-reduction).
- **Noise reduction Detail, Contrast and Smoothness** for finer control of luminance and colour noise. See [Sharpening and noise reduction](Develop#sharpening-and-noise-reduction).
- **Choose the lens profile by hand**, and remember it for every photo from that lens. See [Lens corrections in detail](Develop#lens-corrections-in-detail).
- **Remove chromatic aberration (automatic)** measures colour fringes on the photo itself, without a profile. See [Lens corrections in detail](Develop#lens-corrections-in-detail).
- **Defringe** with adjustable hue ranges and a fringe colour picker. See [Lens corrections in detail](Develop#lens-corrections-in-detail).
- **Post-crop vignetting and grain**. See [Effects](Develop#effects).
- **LMMSE demosaic**, for clean detail from high-ISO files. See [Sharpening and noise reduction](Develop#sharpening-and-noise-reduction).
- **Embedded DNG corrections**: a DNG's own lens-shading map, vignetting and distortion, applied with one switch. See [Lens corrections in detail](Develop#lens-corrections-in-detail).
- **Hot pixel removal** replaces stuck and hot photosites on the sensor before demosaicing, with a threshold and an "N pixels fixed" count. See [Hot pixels](Develop#hot-pixels).
- **Manual chromatic aberration**: Red and Blue sliders line up the colours by hand, on top of the profile or the automatic correction. See [Lens corrections in detail](Develop#lens-corrections-in-detail).

## Masks and retouching

- **Mask components**: build a mask from up to seven parts that add, subtract or intersect, such as a subject minus a brush. See [Components](Masking#components-add-subtract-intersect).
- **More local sliders**: Amount, Highlights, Shadows, Whites, Blacks, Tint, Hue, Texture, Clarity, Dehaze, Sharpness, Noise and Defringe inside a mask. See [The sliders](Masking#the-sliders).
- **Colour Range** and **Luminance Range** masks, and a brush with **Density**. See [Making a mask](Masking#making-a-mask).
- **Curve, Point Colour and Grain inside masks**: a point curve with RGB channels, up to four Point Colour swatches and grain, each acting only inside the mask. See [The sliders](Masking#the-sliders).
- **Auto Mask** for the brush: strokes paint only where the photo is like the colour under the brush, so they stop at edges. See [Auto Mask](Masking#auto-mask).
- **Edge and Feather** refine the outline of subject, class and selection masks. See [Feather and Edge](Masking#feather-and-edge-for-model-masks).
- **Select Objects (Box)**, mask renaming, hiding, **Duplicate and Invert** and **Delete Empty Masks**. See [Masking](Masking#looking-after-masks).
- **Turn a radial** with the handle above it or the **Angle** slider, so an ellipse can lie at any angle. See [Editing gradients and radials](Masking#editing-gradients-and-radials).
- **Shape handles**: drag a gradient's ends or middle and a radial's edges and feather instead of drawing them again; the mouse wheel changes the feather (⇧ the Amount), and **Keep tool armed** places several shapes in a row. See [Editing gradients and radials](Masking#editing-gradients-and-radials).
- **Pick Range** for Luminance Range: click to centre the band on a spot or drag a rectangle to span it, with a live readout of the value under the pointer. See [Luminance and Channel Range](Masking#luminance-and-channel-range).
- **Channel Range** components select by red, green, blue, saturation, Lab lightness, a, b or chroma. See [Luminance and Channel Range](Masking#luminance-and-channel-range).
- **Separate fades** below and above a Luminance or Channel Range, set with a four-handle range control. See [Luminance and Channel Range](Masking#luminance-and-channel-range).
- **Show Channel** draws what a range component reads as a grey on the image. See [Luminance and Channel Range](Masking#luminance-and-channel-range).
- **Blend: Colour Only and Lightness Only** keep just a mask's change of colour or of lightness. See [Blend](Masking#blend).
- **Sum and Exclusion** join a mask component by adding its value or keeping only what isn't in both. See [Components](Masking#components-add-subtract-intersect).
- **Reorder masks and components** by dragging, or with Move Up and Move Down. See [Reordering](Masking#reordering).
- **Use Mask** adds another mask of the photo as a component, kept in step as that mask is edited. See [Using another mask](Masking#using-another-mask).
- **Edge refine** snaps brush and model masks to edges in the photo. See [Edge refine](Masking#edge-refine).
- **Smooth** inside a mask: an edge-preserving blur for skin or sky. See [The sliders](Masking#the-sliders).
- **Remove** takes a distraction out of the photo, filling it from its surroundings, and **Detect Objects** fills just the object you brushed over. See [Remove and Detect Objects](Develop#remove-and-detect-objects).
- **One Remove tool** with Remove, Heal and Clone modes, per-patch **Opacity**, a **Tool Overlay** setting, a pin list with Select All and Delete All, and Option-drag to delete the spots inside a marquee. See [Develop](Develop#modules).
- **Lens Blur** blurs the background (or foreground) from a depth map, with bokeh shapes and a focus range you pick on the photo. See [Lens Blur](Develop#lens-blur).
- **Fill and Blur** modes for the Remove tool paint a colour over a spot or soften it, as a spot or a brush stroke. See [Fill and Blur](Develop#fill-and-blur).
- **Gaussian and Motion blur types** for Lens Blur, a plain softening or a streak at any angle, which work with or without a depth map. See [Lens Blur](Develop#lens-blur).
- **Distraction Removal › Reflections** takes window and glass reflections off the scene behind them, with a reflection removal model you add. See [Reflections](Develop#reflections).
- **Pet Eye** fixes an animal's glowing green, yellow or white eyes with a dark pupil and an optional catchlight. See [Develop](Develop#modules).

## Export, print and proofing

- **More colour spaces**: Adobe RGB (1998), ProPhoto RGB, and any printer or paper profile installed on the Mac. See [The sheet](Export#the-sheet).
- **Image sizing** by long or short edge, width and height, megapixels or percentage, and a **Resolution** in ppi. See [The sheet](Export#the-sheet).
- **Output sharpening** for screen, matte or glossy paper. See [The sheet](Export#the-sheet).
- **Metadata levels** from All to Copyright only or None. See [The sheet](Export#the-sheet).
- **Graphic watermarks**, fonts and rotation, as well as text. See [The sheet](Export#the-sheet).
- **AVIF and JPEG XL** where macOS can write them, 8-bit and compressed TIFF, and **Limit file size**. See [The sheet](Export#the-sheet).
- **DNG export** writes a DNG with the corrections baked in and the look left open, the full look baked in, or the original raw as a linear DNG. See [DNG export](Export#dng-export-render-to-dng).
- **HDR Output** on export: a gain map in JPEG, HEIC and now AVIF, or with **Maximize compatibility** off a full 10-bit PQ HEIC or AVIF, up to each photo's HDR Limit. Formats this Mac can't write, such as JPEG XL on macOS 27.2, are shown greyed out with the reason. See [The sheet](Export#the-sheet).
- **Borders and enlarged canvas** on export: a border in any colour, a canvas grown to 1:1, 4:5, 3:2, 16:9 or a ratio of your own, and an inner line. See [The sheet](Export#the-sheet).
- **16-bit PNG** export. See [The sheet](Export#the-sheet).
- **10-bit HEIC** for SDR exports. See [The sheet](Export#the-sheet).
- **32-bit float TIFF** in linear light, and **greyscale TIFF** for black and white edits. See [The sheet](Export#the-sheet).
- **OpenEXR** export, scene-linear in half or full float, where macOS can write it. See [The sheet](Export#the-sheet).
- **PDF export**, one page per photo, fitted to the image or on A4, Letter or A3, with a margin and a caption from tokens. See [PDF export](Export#pdf-export).
- **Sizes in centimetres and inches** on the export sizing row, turned into pixels at the resolution. See [The sheet](Export#the-sheet).
- **Rendering intent on export** for Adobe RGB, ProPhoto and printer profiles. See [The sheet](Export#the-sheet).
- **Overwrite if edit changed** re-exports only photos edited since their file was written. See [The sheet](Export#the-sheet).
- **Keyword hierarchy and the Latent edit in exported files**, each with its own switch. See [The sheet](Export#the-sheet).
- **Original + XMP sidecar** copies the raw with a sidecar other applications read. See [Exporting originals](Export#exporting-originals).
- **Twenty-three more naming tokens** such as `{lens}`, `{iso}`, `{city}`, `{keywords}` and `{version}`, and **token modifiers** for fallbacks, letter case, character ranges and replacing. See [The sheet](Export#the-sheet).
- **Tokens in the watermark text**, filled in for each photo. See [The sheet](Export#the-sheet).
- **Add to this catalog copies the original's rating, label and keywords** onto the export. See [The sheet](Export#the-sheet).
- **Export with Previous** (⌥⇧⌘E), **several presets in one run**, and new destinations: beside the original, or chosen when the export starts. See [Export with Previous](Export#export-with-previous).
- **`latent-cli export`** renders a folder or files with their saved edits from Terminal, with a preset, format, size, colour space, naming and a dry run. See [From the command line](Export#from-the-command-line).
- **`latent-cli thumbs`** makes a folder's thumbnails ahead of time so it opens with them ready. See [From the command line](Export#from-the-command-line).
- **Soft proofing** with Perceptual and Relative Colorimetric intents, **Simulate Paper & Ink**, a monitor gamut warning and **proof copies**. See [Soft proofing](Develop#soft-proofing).
- **Rendering intent when printing**, taken from the soft proof. See [Print](Export#print).
- **Saturation and Absolute Colorimetric** intents in soft proofing and printing, beside Perceptual and Relative Colorimetric. See [Soft proofing](Develop#soft-proofing).
- **Apply a preset at export**, appended or replacing the edit at 0–200%, without changing the photos. See [Apply a preset at export](Export#apply-a-preset-at-export).
- **A print-only preset and print sharpening** for matte or glossy paper. See [Print](Export#print).
- **A printer profile of its own for printing**, chosen in the print panel, whatever Soft Proof shows. See [Print](Export#print).
- **Separate print margins** for each side, in points, millimetres or inches. See [Print](Export#print).
- **More soft-proof controls**: **S** turns proofing on and off, profiles from anywhere (your own ~/Library/ColorSync/Profiles included) stay in the menu, the Mac's installed printer profiles are listed, the target is remembered, **Black Point Compensation** can be turned off, the two gamut warnings take colours you choose, and Before compares the proof with the unproofed edit. See [Soft proofing](Develop#soft-proofing).

## Presets and keyboard

- **Preset Amount** applies a preset at 0–200% strength, and re-blends the last one live. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Import, export, rename, duplicate and update presets** from the Presets panel's ⋯ menu. See [Managing presets](Develop#managing-presets).
- **Preset folders and favourites**: "Film|Portra" files a preset in a Film submenu, and starred presets sit at the top of every Apply Preset menu. See [Managing presets](Develop#managing-presets).
- **Manage Presets**, a searchable list with descriptions and the groups each preset holds. See [Managing presets](Develop#managing-presets).
- **Keyboard shortcuts for presets** in Settings › Keyboard, and **Develop › Apply Preset**. See [Managing presets](Develop#managing-presets).
- **Panel presets** in the headers of the main Develop panels, with Save Panel as Preset…. See [Managing presets](Develop#managing-presets).
- **Apply (Overwrite)** with ⌥, and **Apply as New Virtual Copy**. See [Managing presets](Develop#managing-presets).
- **Previous** (⌥⌘V) pastes the settings of the photo selected before this one. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Paste Settings (Overwrite)** resets every group it doesn't paste. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Copy Settings… and Paste Settings…** take only the groups you tick, from a checklist that remembers your choice. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Load Settings from File…** applies the edit from a Latent sidecar or an image carrying Latent's edit. See [Presets and clipboard](Develop#presets-and-clipboard).
- **Reset Edits** puts a whole selection back to the default edit, keeping ratings, labels and keywords. See [Applying edits to many images](Library#applying-edits-to-many-images).
- **Sync Last Change to Selection** pastes only the groups the lead photo's last step changed onto the rest of the selection. See [Applying edits to many images](Library#applying-edits-to-many-images).
- **Compare as Before** shows a snapshot beside the current edit in a split. See [History and snapshots](Develop#history-and-snapshots).
- **A draggable split line** in Before/After's split layouts; double-click it for the middle. See [Before/After](Develop#beforeafter-and-reference-view).
- **Process versions**: each edit records which rendering it was made with, shown in Calibration, ready for an Update Process Version dialog when the rendering next changes. See [Process versions](Develop#process-versions).
- **Shortcuts overlay** (?, Help › Show Shortcuts Overlay) lists the keys of the mode you are in over the window. See [Keyboard Shortcuts](Keyboard-Shortcuts).
- **Focus Exposure** (Develop menu, no key until you give it one) puts the keyboard in the Exposure value. See [The viewport](Develop#the-viewport).
- **Customisable shortcuts**: Settings › Keyboard lists every command, searchable and grouped, with click-to-record keys, a warning (and an offer to reassign) when keys are taken, reset one or all, and keymap import and export as JSON. Menu commands without a key can be given one. See [Customising the keys](Keyboard-Shortcuts#customising-the-keys).

## Help

- **A welcome sheet** on first launch, with Open Folder… and links to Getting Started and Keyboard Shortcuts; Help › Show Welcome brings it back. See [Getting Started](Getting-Started#first-launch).
- These help pages gained a [Getting Started](Getting-Started) rewrite, three tutorials, [Coming from Lightroom](Coming-from-Lightroom), a [Glossary](Glossary) and an [FAQ](FAQ). The same pages are in the app under **Help › Latent Help** (⌘?).
