# Glossary

Words used in Latent and on these pages, in plain terms, with a link to where each is used.

## Files and catalog

**Raw file.** What a camera records before it makes a JPEG: the light each pixel of the sensor measured, with more range in the highlights and shadows than a JPEG keeps. Each maker has its own format (NEF, CR3, ARW and so on). A raw has to be *developed* before it looks like a photo, which is what Latent does. See [Supported files](Library#supported-files).

**DNG.** Adobe's open raw format. Latent reads DNGs, writes them for Photo Merge results, and can export a photo as a *linear* DNG: already demosaiced, with white balance, noise reduction and corrections baked in, but no look. See [DNG export](Export#dng-export-render-to-dng).

**RAW+JPEG pair.** The two files a camera writes when set to save both, with the same name. Latent shows them as one photo. See [RAW+JPEG pairs](Library#rawjpeg-pairs).

**Catalog.** Latent's record of a folder's photos: their ratings, keywords, collections and edits. Each folder has its own, in a `_latent` folder inside it. See [The catalog](Library#the-catalog).

**Sidecar, XMP.** A small text file beside the database that holds one photo's rating, label, keywords, title and edit. XMP is the standard format such files use, which other applications read too. Latent's sidecars are the source of truth: if the database is lost, it is rebuilt from them.

**Reconciliation.** Latent comparing a folder with its catalog, when the folder opens or changes, to pick up new, renamed and removed files.

**Non-destructive editing.** Your original file is never changed; the edit is a list of settings applied each time the photo is shown or exported.

## Organising

**Flag.** Pick (P), reject (X) or neither (U): the quickest way to sort keepers from misses.

**Colour label.** Red, yellow, green, blue or purple, for whatever meaning you give them. See [Colour labels](Library#colour-labels).

**Keyword, keyword hierarchy.** Words attached to a photo to find it later. A hierarchy puts keywords inside others, such as Places › France › Paris. See [Keywords](Collections-and-Keywords#keywords).

**Collection.** A hand-picked group of photos that doesn't move any file. A photo can be in many collections. See [Collections](Collections-and-Keywords#collections).

**Smart collection.** A collection that fills itself from rules, such as "rated 4 or more". See [Smart collections](Collections-and-Keywords#smart-collections).

**Collection set.** A container that holds collections, to keep a long list tidy.

**Quick Collection, target collection.** The collection B adds to. It starts as the Quick Collection; any collection can be made the target.

**Virtual copy.** A second version of a photo, with its own edit, rating and keywords, sharing the same raw file. The photo it was made from is its *master*. See [Virtual copies](Library#virtual-copies).

**Snapshot.** A named copy of a photo's whole edit, kept to return to later. **History** is the list of every change, newest first.

**Preset.** A saved set of develop settings to apply to other photos, or a saved set of export settings.

## Developing

**Demosaic.** A camera sensor sees only red, green or blue at each pixel, through a mosaic of colour filters (a *Bayer* pattern). Demosaicing works out the missing two colours at every pixel, and is the first step in turning a raw into a picture.

**White balance.** Correcting the colour of the light so that white looks white. **Temperature** (in Kelvin) runs from blue to yellow, **Tint** from green to magenta.

**Exposure, stops.** How bright the photo is. One stop doubles or halves the light.

**Clipping.** Where tones are pushed past the brightest white or the darkest black and lose all detail. Press J to see it.

**Histogram, waveform, vectorscope.** Graphs of the photo: how many pixels have each brightness, brightness across the frame, and how colourful and which hue the colours are.

**Tone curve.** A graph that remaps tones. The *point* curve is shaped by dragging points; the *region* curve by four sliders.

**Profile.** The starting point for a photo's colour and contrast, before any slider. Latent has its own profiles and reads imported camera profiles.

**DCP (DNG camera profile).** A `.dcp` file describing how one camera model sees colour, often used to match the camera maker's own look. Latent includes none; you import them. See [Develop](Develop#modules).

**Colour space.** The range of colours a file can describe, and how. **sRGB** is the standard for screens and the web; **Display P3** is wider, for modern Apple screens; **Adobe RGB (1998)** is often asked for by print labs; **ProPhoto RGB** is the widest, for files going on to another editor.

**Gamut.** The range of colours a screen, printer or colour space can show. A colour outside it is *out of gamut*.

**ICC profile.** A file describing the colours one device can produce, such as a printer with one paper. Soft proofing and printing use it.

**Mask.** A map of where a local adjustment applies. It can be a shape (gradient, radial, brush), a range of colours or tones, or made by a model (subject, sky, an object you click). See [Masking](Masking).

**Mask component.** One part of a mask, added to, subtracted from or intersected with the rest, such as "the subject, minus a brush over the eyes". See [Components](Masking#components-add-subtract-intersect).

**Model mask.** A mask made by a machine-learning model, such as Subject or Select by Class. It is made again from the photo when needed rather than stored.

**Feather.** How soft the edge of a mask, brush or vignette is.

**Upright, keystone.** Correcting the converging lines you get when the camera is tilted up at a building. See [Transform and Upright](Develop#transform-and-upright).

**Chromatic aberration, defringe.** Coloured fringes along high-contrast edges, caused by the lens. Latent removes them from a lens profile, by measuring them, or with Defringe.

**Vignetting.** Darker corners. Lens corrections remove the lens's own; post-crop vignetting adds one on purpose.

**Sharpening, output sharpening.** Sharpening in Develop brings out detail in the photo; output sharpening is a last touch at export, for the screen or paper the file is going to.

**Noise reduction.** Smoothing the grainy speckle (luminance noise) and coloured blotches (colour noise) of high-ISO photos. AI Noise Reduction uses a trained model.

**Grain.** Film-like texture added on purpose, as an effect.

**Remove (content-aware).** Filling an area from what surrounds it, to take something out of the photo, without a source to copy from. See [Remove and Detect Objects](Develop#remove-and-detect-objects).

**Depth map.** A picture of how far away each part of the scene is, made by a depth model (or, without one, from the subject mask). Lens Blur uses it. See [Lens Blur](Develop#lens-blur).

**Bokeh.** The look of out-of-focus areas, especially the discs that small lights become.

## Output

**Soft proof.** Showing on screen what a file or print will look like, before you make it. See [Soft proofing](Develop#soft-proofing).

**Rendering intent.** What happens to colours the paper or file can't reproduce. **Perceptual** squeezes all colours into range, keeping their relationships; **Relative Colorimetric** keeps the ones that fit exactly and clips the rest.

**Black point compensation.** Mapping the photo's deepest black to the paper's, so shadow detail isn't lost. Latent always uses it with Relative Colorimetric.

**Paper and ink simulation.** Showing the paper's real white and the ink's real black on screen, instead of the screen's own.

**HDR, headroom.** An HDR screen can show highlights brighter than paper white; *headroom* is how much brighter, in stops. **HDR Limit** sets how much of it a photo uses. See [HDR Limit](Develop#hdr-limit).

**Gain map.** An extra layer in a JPEG or HEIC that tells HDR screens how much to brighten each part of the picture. Other screens show the ordinary picture. See [The sheet](Export#the-sheet).

**ppi.** Pixels per inch: how large a file prints. It doesn't change the pixels.

**Watermark.** Text or a logo stamped into exported files, never into the photo itself.

## Mac and technical

**Model, Core ML.** A trained machine-learning network, such as the ones that find a subject or a sky. Core ML is Apple's system for running them on the Mac. See [Models](Models).

**GPU, Neural Engine.** The Mac's graphics processor, which Latent renders and runs models on, and Apple's separate processor for machine learning, which Latent uses only if you ask.

**Sandbox.** macOS's walls around an app: Latent can reach only the folders you give it.

**Ad-hoc signing, notarisation, Gatekeeper.** Apple checks (*notarises*) apps from registered developers. Latent is signed without a developer account and isn't notarised, so Gatekeeper, the part of macOS that checks new apps, asks you once before it first opens. See [Installation](Installation#the-gatekeeper-dialog).
